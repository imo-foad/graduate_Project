-- 0044: Profile & Career Management ownership, validation and identity-scope regression tests.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select, insert on tests.ids to anon, authenticated, service_role;
create function tests.id(p_key text) returns uuid
language sql stable
as $f$ select v from tests.ids where k = p_key $f$;

create function tests.mk_user(p_key text, p_identity_type text)
returns uuid
language plpgsql
as $f$
declare
  v_id uuid := gen_random_uuid();
  v_metadata jsonb := jsonb_build_object('full_name', p_key);
begin
  if p_identity_type in ('STUDENT','FACULTY') then
    v_metadata := v_metadata || jsonb_build_object(
      'registration_flow', 'EMAIL_IDENTITY_VERIFICATION'
    );
  end if;

  insert into auth.users (
    id, aud, role, email, email_confirmed_at, raw_user_meta_data
  )
  values (
    v_id,
    'authenticated',
    'authenticated',
    p_key || '@profile-tests.local',
    now(),
    v_metadata
  );

  insert into tests.ids(k, v) values (p_key, v_id);

  if p_identity_type in ('STUDENT','FACULTY') then
    insert into public.human_identities (
      profile_id, identity_type, institution_ref, status, verification_source, verified_at
    )
    values (
      v_id,
      p_identity_type,
      'SYNTH-' || p_identity_type || '-' || upper(p_key),
      'VERIFIED',
      'SYNTHETIC_SEED',
      now()
    );
    -- These fixtures represent a verified local synthetic identity. Keep the account ACTIVE while
    -- deliberately leaving graduate_profiles absent for STUDENT/FACULTY.
    update public.profiles set account_status = 'ACTIVE' where id = v_id;
  elsif p_identity_type <> 'GRADUATE' then
    raise exception 'INVALID_TEST_IDENTITY';
  end if;

  return v_id;
end
$f$;

-- pgTAP throws_ok needs the claims and role setup inside the same subtransaction.
create function tests.as_user(p_uid uuid, p_sql text)
returns text
language sql immutable
as $f$
  select format(
    'select set_config(%L, %L, true); select set_config(%L, %L, true); ',
    'request.jwt.claims',
    jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text,
    'role',
    'authenticated'
  ) || p_sql
$f$;

select tests.mk_user('student_a', 'STUDENT');
select tests.mk_user('student_b', 'STUDENT');
select tests.mk_user('faculty_a', 'FACULTY');
select tests.mk_user('graduate_a', 'GRADUATE');

-- ---- Profile column privileges are least-privilege -------------------------------------------------
select is(has_column_privilege('authenticated', 'public.profiles', 'full_name', 'UPDATE'), true,
  'authenticated can update the supported full_name field');
select is(has_column_privilege('authenticated', 'public.profiles', 'avatar_url', 'UPDATE'), false,
  'authenticated cannot inject an arbitrary avatar_url without an approved upload flow');
select is(has_column_privilege('authenticated', 'public.profiles', 'email', 'UPDATE'), false,
  'authenticated cannot mass-assign the account email');
select is(has_column_privilege('authenticated', 'public.profiles', 'account_status', 'UPDATE'), false,
  'authenticated cannot mass-assign account status');
select is(has_column_privilege('authenticated', 'public.profiles', 'id', 'UPDATE'), false,
  'authenticated cannot change profile ownership');

select is(has_column_privilege('authenticated', 'public.graduate_profiles', 'major', 'UPDATE'), true,
  'authenticated may update supported professional profile fields');
select is(has_column_privilege('authenticated', 'public.graduate_profiles', 'hidden_fields', 'UPDATE'), true,
  'authenticated may update the supported profile privacy settings');
select is(has_column_privilege('authenticated', 'public.graduate_profiles', 'profile_id', 'UPDATE'), false,
  'authenticated cannot change graduate profile ownership');
select is(has_column_privilege('authenticated', 'public.graduate_profiles', 'recommendations_dirty', 'UPDATE'), false,
  'authenticated cannot mass-assign internal recommendation state');
select is(has_table_privilege('authenticated', 'public.graduate_profiles', 'INSERT'), false,
  'clients cannot manufacture a graduate profile for a Student/Faculty identity');

-- Career-history ownership and provenance columns cannot be forged.
select is(has_column_privilege('authenticated', 'public.career_history', 'company_name', 'INSERT'), true,
  'authenticated may insert supported self-reported career records');
select is(has_column_privilege('authenticated', 'public.career_history', 'graduate_id', 'UPDATE'), false,
  'authenticated cannot transfer a career-history row to another owner');
select is(has_column_privilege('authenticated', 'public.career_history', 'source', 'UPDATE'), false,
  'authenticated cannot rewrite career-history provenance');
select is(has_column_privilege('authenticated', 'public.career_history', 'is_current', 'UPDATE'), false,
  'authenticated cannot bypass the current-employment RPC');
select is(has_table_privilege('authenticated', 'public.career_history', 'DELETE'), false,
  'career history is intentionally preserved; clients have no hard-delete privilege');
select is(has_table_privilege('anon', 'public.profiles', 'SELECT'), false,
  'anonymous viewers cannot read private profile rows');
select is(has_table_privilege('anon', 'public.graduate_profiles', 'SELECT'), false,
  'anonymous viewers cannot read private graduate profiles');
select is(has_table_privilege('anon', 'public.career_history', 'SELECT'), false,
  'anonymous viewers cannot read private career history');

-- ---- Basic profiles are independent of graduate_profiles --------------------------------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('student_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.profiles set full_name = 'Student A Updated' where id = auth.uid();
reset role;
select is(
  (select full_name from public.profiles where id = tests.id('student_a')),
  'Student A Updated',
  'a Student can update the supported basic full_name field without a graduate profile'
);
select is(
  (select count(*)::int from public.graduate_profiles where profile_id = tests.id('student_a')),
  0,
  'a Student identity does not receive a graduate profile implicitly'
);
select is(
  (select count(*)::int from public.graduate_profiles where profile_id = tests.id('faculty_a')),
  0,
  'a Faculty identity does not receive a graduate profile implicitly'
);
select is(
  (select count(*)::int from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  1,
  'the verified Graduate-compatible account has its graduate profile'
);

-- A forged target id does not change another account's basic profile.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('student_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.profiles set full_name = 'Forged Cross Account Name' where id = tests.id('student_b');
reset role;
select is(
  (select full_name from public.profiles where id = tests.id('student_b')),
  'student_b',
  'RLS prevents a Student from modifying another basic profile'
);

-- ---- Professional profile PATCH semantics and privacy settings -------------------------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.graduate_profiles
   set major = 'Software Engineering',
       location = 'Synthetic Test City',
       career_interests = array['BACKEND'],
       work_preferences = '{"remote":true}'::jsonb
 where profile_id = auth.uid();
reset role;
select is(
  (select major from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  'Software Engineering',
  'graduate owner can update a supported professional field'
);
select is(
  (select location from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  'Synthetic Test City',
  'graduate owner can update location'
);

-- An omitted field is unchanged by PATCH; only the explicitly supplied field changes.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.graduate_profiles set department = 'Computer Science' where profile_id = auth.uid();
reset role;
select is(
  (select location from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  'Synthetic Test City',
  'omitted PATCH fields retain their previously saved value'
);
select is(
  (select department from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  'Computer Science',
  'the explicitly patched field is persisted'
);

-- Null clears a nullable text field; empty string is a distinct, persisted value in this schema.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.graduate_profiles set location = null where profile_id = auth.uid();
reset role;
select is(
  (select location from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  null,
  'explicit null clears a nullable professional field'
);
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.graduate_profiles set location = '' where profile_id = auth.uid();
reset role;
select is(
  (select location from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  '',
  'an empty string is preserved distinctly from null'
);

select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    format(
      'update public.graduate_profiles set graduation_year = 2101 where profile_id = %L',
      tests.id('graduate_a')
    )
  ),
  '23514', null,
  'graduation year outside the existing database range is rejected'
);
select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    format(
      'update public.graduate_profiles set hidden_fields = array[%L] where profile_id = %L',
      'email',
      tests.id('graduate_a')
    )
  ),
  '23514', null,
  'unsupported hidden fields are rejected by the existing constraint'
);
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.graduate_profiles
   set hidden_fields = array['location','career_interests','work_preferences','avatar_url']
 where profile_id = auth.uid();
reset role;
select is(
  (select hidden_fields from public.graduate_profiles where profile_id = tests.id('graduate_a')),
  array['location','career_interests','work_preferences','avatar_url']::text[],
  'the owner can configure only the supported hidden fields'
);

select throws_ok(
  tests.as_user(
    tests.id('student_a'),
    format(
      'insert into public.graduate_profiles(profile_id) values (%L)',
      tests.id('student_a')
    )
  ),
  '42501', null,
  'Student cannot self-create a graduate professional profile'
);
select throws_ok(
  tests.as_user(
    tests.id('faculty_a'),
    format(
      'insert into public.graduate_profiles(profile_id) values (%L)',
      tests.id('faculty_a')
    )
  ),
  '42501', null,
  'Faculty cannot self-create a graduate professional profile'
);

-- ---- Career history lifecycle, date semantics, ownership and preservation -----------------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into public.career_history(graduate_id,company_name,job_title,start_date,end_date)
values (auth.uid(),'Synthetic Employer','Junior Engineer','2020-01-01','2020-01-01');
reset role;
select is(
  (select count(*)::int from public.career_history
    where graduate_id = tests.id('graduate_a')
      and company_name = 'Synthetic Employer'
      and start_date = date '2020-01-01'
      and end_date = date '2020-01-01'
      and source = 'SELF_REPORTED'
      and is_current = false),
  1,
  'a past career record allows equal start/end dates and receives SELF_REPORTED source'
);

select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
update public.career_history
   set job_title = 'Software Engineer'
 where graduate_id = auth.uid() and company_name = 'Synthetic Employer';
reset role;
select is(
  (select job_title from public.career_history
    where graduate_id = tests.id('graduate_a') and company_name = 'Synthetic Employer'),
  'Software Engineer',
  'owner can correct an existing self-reported career-history record'
);

select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    format(
      'insert into public.career_history(graduate_id,company_name,job_title,start_date,end_date) values (%L,%L,%L,%L,%L)',
      tests.id('graduate_a'),
      'Invalid Date Employer',
      'Engineer',
      '2022-02-02',
      '2022-02-01'
    )
  ),
  '23514', null,
  'end date before start date is rejected by the existing date constraint'
);

select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    format(
      'insert into public.career_history(graduate_id,company_name,job_title,start_date,end_date) values (%L,%L,%L,%L,%L)',
      tests.id('graduate_a'),
      null,
      'Engineer',
      '2022-01-01',
      '2022-01-02'
    )
  ),
  '23502', null,
  'a missing required company name is rejected'
);

select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    format(
      'insert into public.career_history(graduate_id,company_name,job_title,start_date,end_date) values (%L,%L,%L,%L,%L)',
      tests.id('graduate_a'),
      'Missing Title Employer',
      null,
      '2022-01-01',
      '2022-01-02'
    )
  ),
  '23502', null,
  'a missing required job title is rejected'
);

-- Owner changes a career record but cannot rewrite its owner/provenance or delete it.
select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    format(
      'update public.career_history set source = %L where graduate_id = %L and company_name = %L',
      'CV_CONFIRMED',
      tests.id('graduate_a'),
      'Synthetic Employer'
    )
  ),
  '42501', null,
  'a client cannot rewrite career-history provenance'
);
select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    format(
      'delete from public.career_history where graduate_id = %L and company_name = %L',
      tests.id('graduate_a'),
      'Synthetic Employer'
    )
  ),
  '42501', null,
  'career history cannot be hard-deleted by the owner'
);
select is(
  (select count(*)::int from public.career_history
    where graduate_id = tests.id('graduate_a') and company_name = 'Synthetic Employer'),
  1,
  'career history remains auditable after a rejected delete'
);

-- Another account cannot read or mutate the graduate's private career history.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('student_b'), 'role', 'authenticated')::text, true);
set local role authenticated;
select is(
  (select count(*)::int from public.career_history
    where graduate_id = tests.id('graduate_a')),
  0,
  'after switching to an unrelated caller, RLS returns no foreign career-history rows'
);

select is(
  (with changed as (
    update public.career_history
       set job_title = 'Forged Cross Account Title'
     where graduate_id = tests.id('graduate_a')
    returning id
  )
  select count(*)::int from changed),
  0,
  'RLS prevents another user from modifying graduate career-history rows'
);
reset role;

-- ---- Current employment is managed atomically and only for graduate identities -----------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.set_current_job(
  'Synthetic Current Employer',
  'Senior Engineer',
  date '2023-01-01',
  'Software',
  'Synthetic current employment'
);
reset role;
select is(
  (select count(*)::int from public.career_history
    where graduate_id = tests.id('graduate_a') and is_current and end_date is null),
  1,
  'set_current_job creates a current record without an end date'
);
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('graduate_a'), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.set_current_job(
  'Synthetic Next Employer',
  'Staff Engineer',
  date '2024-01-01'
);
reset role;
select is(
  (select end_date from public.career_history
    where graduate_id = tests.id('graduate_a') and company_name = 'Synthetic Current Employer'),
  date '2024-01-01',
  'starting a new job closes the previous current row at the new start date'
);
select is(
  (select count(*)::int from public.career_history
    where graduate_id = tests.id('graduate_a') and is_current and end_date is null),
  1,
  'exactly one current employment record remains after replacement'
);
select throws_ok(
  tests.as_user(
    tests.id('graduate_a'),
    $q$select public.set_current_job(
         'Earlier Employer',
         'Engineer',
         date '2022-01-01'
       )$q$
  ),
  'PT422', 'START_BEFORE_PREVIOUS',
  'an earlier current-job start date is rejected without replacing the current row'
);

select throws_ok(
  tests.as_user(
    tests.id('student_a'),
    $q$select public.set_current_job(
         'Not a Graduate Employer',
         'Engineer',
         date '2023-01-01'
       )$q$
  ),
  'PT403', 'GRADUATE_PROFILE_REQUIRED',
  'Student receives a stable error instead of a low-level graduate-profile foreign-key failure'
);
select throws_ok(
  tests.as_user(
    tests.id('faculty_a'),
    $q$select public.set_current_job(
         'Not a Graduate Employer',
         'Lecturer',
         date '2023-01-01'
       )$q$
  ),
  'PT403', 'GRADUATE_PROFILE_REQUIRED',
  'Faculty receives a stable error instead of a low-level graduate-profile foreign-key failure'
);
select throws_ok(
  tests.as_user(
    tests.id('student_a'),
    format(
      'insert into public.career_history(graduate_id,company_name,job_title,start_date,end_date) values (%L,%L,%L,%L,%L)',
      tests.id('student_a'),
      'Student Career',
      'Student',
      '2022-01-01',
      '2022-01-02'
    )
  ),
  '42501', null,
  'Student cannot insert career history without a graduate-profile row'
);
select throws_ok(
  tests.as_user(
    tests.id('faculty_a'),
    format(
      'insert into public.career_history(graduate_id,company_name,job_title,start_date,end_date) values (%L,%L,%L,%L,%L)',
      tests.id('faculty_a'),
      'Faculty Career',
      'Lecturer',
      '2022-01-01',
      '2022-01-02'
    )
  ),
  '42501', null,
  'Faculty cannot insert career history without a graduate-profile row'
);

reset role;
select * from finish();
rollback;
