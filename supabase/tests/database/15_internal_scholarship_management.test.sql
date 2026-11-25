begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select, insert on tests.ids to authenticated, service_role;
grant select on tests.ids to anon;

create function tests.id(p_k text) returns uuid language sql stable as $f$
  select v from tests.ids where k = p_k
$f$;

create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local',
          jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end
$f$;

create function tests.mk_opp(p_key text, p_type text, p_props jsonb default '{}') returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.opportunities (seed_key, type, title, status, deadline, end_at, attendance_mode, is_sample)
  values ('t-' || p_key, p_type, 'Test ' || p_key, coalesce(p_props ->> 'status', 'ACTIVE'),
    case when p_props ? 'deadline_days' then now() + make_interval(days => (p_props ->> 'deadline_days')::int) end,
    case when p_props ? 'end_days' then now() + make_interval(days => (p_props ->> 'end_days')::int) end,
    'ONLINE', coalesce((p_props ->> 'is_sample')::boolean, false))
  returning id into v;
  insert into tests.ids values (p_key, v);
  return v;
end
$f$;

create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end
$f$;

do $$
begin
  perform tests.mk_user('admin');
  perform tests.mk_user('a1');
  perform tests.mk_user('a2');
  insert into private.platform_admins(user_id, is_active)
  values (tests.id('admin'), true);
  update public.graduate_profiles set degree = 'Bachelor', graduation_year = 2025
   where profile_id in (tests.id('a1'), tests.id('a2'));
  perform tests.mk_opp('sample_sch', 'SCHOLARSHIP', '{"deadline_days":10,"is_sample":true}');
  insert into public.cv_documents(id,graduate_id,storage_path,file_type,size_bytes)
  values
    ('00000000-0000-0000-0000-0000000000d1',tests.id('a1'),tests.id('a1')::text || '/scholarship.pdf','pdf',100),
    ('00000000-0000-0000-0000-0000000000d2',tests.id('a2'),tests.id('a2')::text || '/unattached.pdf','pdf',100);
  insert into tests.ids(k,v) values
    ('cv_a','00000000-0000-0000-0000-0000000000d1'),
    ('cv_unattached','00000000-0000-0000-0000-0000000000d2');
end
$$;

select ok(has_function_privilege('authenticated',
  'public.create_admin_scholarship(text,text,text,text,text,timestamp with time zone,text[],integer,integer,text[],text[])',
  'EXECUTE'), 'platform admin Scholarship creation RPC is callable by authenticated users');
select ok(not has_function_privilege('anon',
  'public.create_admin_scholarship(text,text,text,text,text,timestamp with time zone,text[],integer,integer,text[],text[])',
  'EXECUTE'), 'anonymous users cannot create Scholarships');
select ok(not has_table_privilege('authenticated','public.scholarship_applications','INSERT'),
  'clients cannot insert Scholarship applications directly');
select ok(not has_table_privilege('authenticated','public.scholarship_applications','UPDATE'),
  'clients cannot update Scholarship applications directly');
select ok(exists(select 1 from pg_policies
  where schemaname='storage' and tablename='objects' and policyname='cv_objects_scholarship_admin_select'),
  'a dedicated admin policy exists for Scholarship-attached CV objects');

-- An ordinary graduate cannot use any organizer or review RPC.
select tests.login('a1');
select throws_ok($q$select public.create_admin_scholarship('Test Award','Alumni Connect','A complete scholarship description')$q$,
  'PT403','ADMIN_REQUIRED','ordinary graduate cannot create Scholarships');
select throws_ok($q$select * from public.list_admin_scholarship_applications()$q$,
  'PT403','ADMIN_REQUIRED','ordinary graduate cannot list all applicants');
reset role;

-- The central platform admin creates and configures a real, internal Scholarship.
select tests.login('admin');
select is(public.assert_platform_admin(),true,'central admin is authenticated by the existing platform-admin guard');
insert into tests.ids(k,v)
select 'internal_sch', (public.create_admin_scholarship(
  'Graduate Research Award',
  'Alumni Connect',
  'Internal scholarship administered and reviewed by Alumni Connect.',
  'Online',
  'ONLINE',
  now() + interval '10 days',
  array['Computer Science'],
  2020,
  2035,
  array['Bachelor'],
  array['Research Methods']
)).id;
select is((select type from public.opportunities where id=tests.id('internal_sch')),
  'SCHOLARSHIP','admin creates an opportunity of type SCHOLARSHIP');
select is((select status from public.opportunities where id=tests.id('internal_sch')),
  'DRAFT','new Scholarship starts as DRAFT');
select is((select is_sample from public.opportunities where id=tests.id('internal_sch')),
  false,'admin-created Scholarship is not sample data');
select is((select created_by from public.opportunities where id=tests.id('internal_sch')),
  tests.id('admin'),'creator identity is recorded');
select is((select allowed_degrees from public.opportunity_eligibility where opportunity_id=tests.id('internal_sch')),
  array['Bachelor']::text[],'Scholarship eligibility requirements are persisted');

select is((public.update_admin_scholarship(
  tests.id('internal_sch'),
  'Graduate Research Award Updated',
  'Alumni Connect',
  'Updated internal Scholarship description for graduate applicants.',
  'Hybrid',
  'HYBRID',
  now() + interval '12 days',
  array['Computer Science','AI'],
  2021,
  2036,
  array['Bachelor','Master'],
  '{}'::text[]
)).title,'Graduate Research Award Updated','admin can update a Scholarship DRAFT and its criteria');
select is((public.publish_admin_scholarship(tests.id('internal_sch'))).status,
  'ACTIVE','admin publishes Scholarship DRAFT');
select throws_ok($q$select public.update_admin_scholarship(
  tests.id('internal_sch'),'Changed','Alumni Connect','This description is long enough.',
  null,'ONLINE',now()+interval '5 days','{}'::text[],null,null,'{}'::text[],'{}'::text[])$q$,
  'PT422','OPPORTUNITY_NOT_EDITABLE','published Scholarship cannot be edited by the DRAFT-only update RPC');
select throws_ok($q$select public.publish_admin_scholarship(tests.id('internal_sch'))$q$,
  'PT422','OPPORTUNITY_NOT_DRAFT','already-published Scholarship cannot be published twice');
reset role;

-- Graduate submission keeps the existing CV + statement + flexible JSON form.
select tests.login('a1');
select is((public.apply_for_scholarship(
  tests.id('internal_sch'), tests.id('cv_a'),
  'I want to continue research in applied computing.',
  '{"study_area":"Computer Science","motivation":"Research"}'::jsonb
)).status,'SUBMITTED','graduate submits to an admin-created internal Scholarship with an owned CV');
insert into tests.ids(k,v)
select 'app_a1', id from public.scholarship_applications
 where graduate_id=tests.id('a1') and opportunity_id=tests.id('internal_sch');
select tests.login('a2');
select is((public.apply_for_scholarship(
  tests.id('internal_sch'), null,
  'I am applying for the internal research award.',
  '{"study_area":"AI","motivation":"Research"}'::jsonb
)).status,'SUBMITTED','second eligible graduate can submit an independent application');
insert into tests.ids(k,v)
select 'app_a2', id from public.scholarship_applications
 where graduate_id=tests.id('a2') and opportunity_id=tests.id('internal_sch');
select tests.login('a1');
select is((select count(*)::int from public.scholarship_applications
  where id=tests.id('app_a2')),0,'ordinary graduate cannot directly read another applicant application');
select throws_ok($q$select public.withdraw_scholarship_application(tests.id('app_a2'))$q$,
  'PT404','SCHOLARSHIP_APPLICATION_NOT_FOUND','ordinary graduate cannot withdraw another applicant application');
select throws_ok($q$select * from public.get_admin_scholarship_application(tests.id('app_a1'))$q$,
  'PT403','ADMIN_REQUIRED','ordinary graduate cannot use admin application details');
reset role;

-- Admin queue, detail and status-transition enforcement.
select tests.login('admin');
select is((select count(*)::int from public.list_admin_scholarship_applications(
  tests.id('internal_sch'),'SUBMITTED',25,null,null)),2,
  'admin sees all submitted applications for a selected Scholarship');
select is((select applicant_name from public.get_admin_scholarship_application(tests.id('app_a1'))),
  'a1','admin can view applicant identity with the application');
select is((select application_data from public.get_admin_scholarship_application(tests.id('app_a1'))),
  '{"study_area":"Computer Science","motivation":"Research"}'::jsonb,
  'admin application details include the original flexible JSON answers');
select is((select cv_storage_path from public.get_admin_scholarship_application(tests.id('app_a1'))),
  tests.id('a1')::text || '/scholarship.pdf',
  'admin application details return the attached Scholarship CV storage path');
select is((select storage_path from public.cv_documents where id=tests.id('cv_a')),
  tests.id('a1')::text || '/scholarship.pdf',
  'admin can read metadata for a CV attached to a Scholarship application');
select is((select count(*)::int from public.cv_documents where id=tests.id('cv_unattached')),
  0,'admin cannot read an unrelated CV metadata row');
select ok(private.can_admin_read_scholarship_cv(tests.id('a1')::text || '/scholarship.pdf'),
  'admin CV helper allows a Scholarship-attached CV');
select ok(not private.can_admin_read_scholarship_cv(tests.id('a2')::text || '/unattached.pdf'),
  'admin CV helper refuses an unrelated graduate CV');
select throws_ok($q$select * from public.list_admin_scholarship_applications(
  null,'ALL',0,null,null)$q$,'PT422','INVALID_INPUT','invalid admin queue limit is rejected');
select throws_ok($q$select * from public.list_admin_scholarship_applications(
  null,'ALL',25,now(),null)$q$,'PT422','INVALID_INPUT','cursor timestamp and id must be supplied together');
select throws_ok($q$select public.review_scholarship_application(
  tests.id('app_a1'),'ACCEPTED','Direct decision')$q$,
  'PT422','INVALID_STATUS_TRANSITION','admin cannot skip UNDER_REVIEW');
select is((public.review_scholarship_application(
  tests.id('app_a1'),'UNDER_REVIEW','Initial eligibility and documents check')).status,
  'UNDER_REVIEW','admin starts review from SUBMITTED');
select is((select count(*)::int from public.scholarship_application_status_history
  where scholarship_application_id=tests.id('app_a1')
    and source_type='ADMIN_ACTION' and actor_user_id=tests.id('admin')
    and new_status='UNDER_REVIEW' and note='Initial eligibility and documents check'),
  1,'admin review action records actor, new status and note');
select is((select count(*)::int from public.notifications
  where profile_id=tests.id('a1') and related_entity_id=tests.id('app_a1')
    and type='SCHOLARSHIP_APPLICATION_STATUS_UPDATED'),
  1,'student is notified when review begins');
select is((public.review_scholarship_application(
  tests.id('app_a1'),'ACCEPTED','Approved by central reviewer')).status,
  'ACCEPTED','admin accepts an application after review');
select throws_ok($q$select public.review_scholarship_application(
  tests.id('app_a1'),'REJECTED','Conflicting final decision')$q$,
  'PT422','INVALID_STATUS_TRANSITION','final accepted decision cannot be reversed');
select throws_ok($q$select public.withdraw_scholarship_application(tests.id('app_a1'))$q$,
  'PT422','CANNOT_WITHDRAW_SCHOLARSHIP_APPLICATION','applicant cannot withdraw after review begins');
select is((select count(*)::int from public.notifications
  where profile_id=tests.id('a1') and related_entity_id=tests.id('app_a1')
    and type='SCHOLARSHIP_APPLICATION_STATUS_UPDATED'),2,
  'student receives a second notification when final decision is recorded');

select is((public.review_scholarship_application(
  tests.id('app_a2'),'UNDER_REVIEW',null)).status,
  'UNDER_REVIEW','admin can independently begin review of a second application');
select is((public.review_scholarship_application(
  tests.id('app_a2'),'REJECTED','Does not meet final award criteria')).status,
  'REJECTED','admin rejects a reviewed application');
select is((select count(*)::int from public.scholarship_application_status_history
  where scholarship_application_id=tests.id('app_a2') and source_type='ADMIN_ACTION'),
  2,'both admin transitions are preserved in history');
select is((select count(*)::int from public.notifications
  where profile_id=tests.id('a2') and related_entity_id=tests.id('app_a2')
    and type='SCHOLARSHIP_APPLICATION_STATUS_UPDATED'),2,
  'rejected applicant receives both review notifications');

-- Sample/demo opportunities remain clearly non-reviewable.
select tests.login('a1');
select is((public.apply_for_scholarship(tests.id('sample_sch'))).status,
  'SUBMITTED','student can use an existing sample Scholarship to exercise the demo form');
insert into tests.ids(k,v)
select 'sample_app', id from public.scholarship_applications
 where graduate_id=tests.id('a1') and opportunity_id=tests.id('sample_sch');
select tests.login('admin');
select is((select count(*)::int from public.list_admin_scholarship_applications(
  tests.id('sample_sch'),'ALL',25,null,null)),1,
  'admin queue labels and includes sample application rows');
select is((select is_sample from public.get_admin_scholarship_application(tests.id('sample_app'))),
  true,'admin detail explicitly identifies sample opportunity data');
select throws_ok($q$select public.review_scholarship_application(
  tests.id('sample_app'),'UNDER_REVIEW','Should not review sample data')$q$,
  'PT422','SAMPLE_DATA_NOT_REVIEWABLE','admin cannot review sample Scholarship applications');
select is((public.close_admin_scholarship(tests.id('internal_sch'))).status,
  'CLOSED','admin can close a published Scholarship');
select throws_ok($q$select public.close_admin_scholarship(tests.id('internal_sch'))$q$,
  'PT422','OPPORTUNITY_NOT_OPEN','closed Scholarship cannot be closed twice');
reset role;

-- Applicant history remains private and includes the reviewer's actions.
select tests.login('a1');
select is((select count(*)::int from public.scholarship_application_status_history
  where scholarship_application_id=tests.id('app_a1')),3,
  'applicant can read own submission and review history');
select is((select count(*)::int from public.scholarship_application_status_history
  where scholarship_application_id=tests.id('app_a2')),0,
  'applicant cannot read another applicant review history');
select is((select status from public.scholarship_applications where id=tests.id('app_a1')),
  'ACCEPTED','applicant can track final admin decision');
select ok(exists(select 1 from public.notifications
  where profile_id=tests.id('a1') and related_entity_id=tests.id('app_a1')
    and type='SCHOLARSHIP_APPLICATION_STATUS_UPDATED'),
  'applicant has review-status notifications');

select set_config('request.jwt.claims','',true);
select throws_ok($q$select * from public.list_admin_scholarship_applications()$q$,
  'PT401','UNAUTHENTICATED','admin queue rejects missing JWT');
reset role;
select set_config('role','anon',true);
select throws_ok($q$select * from public.list_admin_scholarship_applications()$q$,
  '42501',null,'anonymous role cannot execute admin queue RPC');
reset role;

select * from finish();
rollback;
