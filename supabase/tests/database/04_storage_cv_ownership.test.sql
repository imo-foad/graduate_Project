begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k = p_k $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
create function tests.mk_opp(p_key text, p_type text, p_props jsonb default '{}') returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.opportunities (seed_key, type, title, status, deadline, start_at, end_at, capacity, waitlist_enabled, attendance_mode)
  values ('t-' || p_key, p_type, 'Test ' || p_key, coalesce(p_props ->> 'status', 'ACTIVE'),
    case when p_props ? 'deadline_days' then now() + make_interval(days => (p_props ->> 'deadline_days')::int) end,
    case when p_props ? 'start_days' then now() + make_interval(days => (p_props ->> 'start_days')::int) end,
    case when p_props ? 'end_days' then now() + make_interval(days => (p_props ->> 'end_days')::int) end,
    (p_props ->> 'capacity')::int, coalesce((p_props ->> 'waitlist')::boolean, false), 'ONLINE')
  returning id into v;
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
-- Impersonate a user exactly as PostgREST does: JWT claims + role. Use `reset role;` to go back to postgres.
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $f$;

do $$ begin
  perform tests.mk_user('s1'); perform tests.mk_user('s2');
  insert into storage.objects (bucket_id, name) values ('cv-documents', tests.id('s2')::text || '/theirs.pdf');
end $$;

select is((select public from storage.buckets where id = 'cv-documents'), false, 'CV bucket is private');
select is((select file_size_limit from storage.buckets where id = 'cv-documents'), 5242880::bigint, 'CV bucket limit is 5 MB');
select is((select allowed_mime_types from storage.buckets where id = 'cv-documents'),
          array['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document'], 'CV bucket allows only pdf/docx');

select tests.login('s1');
select lives_ok($q$insert into storage.objects (bucket_id, name) values ('cv-documents', tests.id('s1')::text || '/mine.pdf')$q$, 'upload into own folder');
select throws_ok($q$insert into storage.objects (bucket_id, name) values ('cv-documents', tests.id('s2')::text || '/evil.pdf')$q$, '42501', null, 'upload into another graduate folder denied');
select throws_ok($q$insert into storage.objects (bucket_id, name) values ('cv-documents', 'loose.pdf')$q$, '42501', null, 'upload outside any user folder denied');
select is((select count(*)::int from storage.objects where bucket_id = 'cv-documents'), 1, 'sees only own objects');
select is((select count(*)::int from storage.objects where name like tests.id('s2')::text || '/%'), 0, 'cannot list another graduate objects');
select lives_ok($q$delete from storage.objects where name like tests.id('s2')::text || '/%'$q$, 'deleting another graduate objects is a silent no-op');
select lives_ok($q$update storage.objects set name = tests.id('s1')::text || '/renamed.pdf' where name like tests.id('s1')::text || '/%'$q$, 'no update policy: statement matches nothing');

reset role;
select is((select count(*)::int from storage.objects where name = tests.id('s2')::text || '/theirs.pdf'), 1, 'other graduate object survived');
select is((select count(*)::int from storage.objects where name = tests.id('s1')::text || '/mine.pdf'), 1, 'own object not renamed (no UPDATE policy)');
select set_config('role', 'anon', true);
select is((select count(*)::int from storage.objects where bucket_id = 'cv-documents'), 0, 'anon sees no CV objects');

reset role;
select * from finish();
rollback;
