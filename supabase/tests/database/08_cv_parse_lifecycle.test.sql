begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select, insert on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k = p_k $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $f$;

do $$ begin
  perform tests.mk_user('graduate');
  perform tests.mk_user('other');
end $$;

reset role;
insert into tests.ids values ('cv', gen_random_uuid());
insert into public.cv_documents (id, graduate_id, storage_path, file_type, size_bytes, parse_status)
values (tests.id('cv'), tests.id('graduate'), tests.id('graduate')::text || '/cv.pdf', 'pdf', 100, 'PROCESSING');

select ok(not has_function_privilege('authenticated',
  'public.complete_cv_parse(uuid,uuid,jsonb)', 'EXECUTE'),
  'authenticated clients cannot call the service-only finalization RPC');

reset role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select set_config('role', 'service_role', true);
-- Edge contract: send each suggestion as {kind, payload}; SQL stores the inner payload object.
select is(public.complete_cv_parse(
  tests.id('cv'), tests.id('graduate'),
  '[
    {"kind":"SKILL","payload":{"skill_id":"KOTLIN","matched_term":"Kotlin"}},
    {"kind":"SKILL","payload":{"skill_id":"DOCKER","matched_term":"Docker"}}
  ]'::jsonb
), 2, 'service finalization accepts the structured kind/payload contract atomically');
select is((select parse_status from public.cv_documents where id = tests.id('cv')),
  'DONE', 'successful finalization marks the document DONE');
select is((select count(*)::int from public.cv_suggestions
  where cv_document_id = tests.id('cv') and status = 'PENDING' and kind = 'SKILL'), 2,
  'structured skill suggestions remain pending for the graduate');
select is((select count(*)::int from public.graduate_skills
  where graduate_id = tests.id('graduate') and source = 'CV_CONFIRMED'), 0,
  'parsing never writes graduate skills before confirmation');

insert into tests.ids values ('suggestion',
  (select id from public.cv_suggestions
   where cv_document_id = tests.id('cv') and kind = 'SKILL' and payload ->> 'skill_id' = 'KOTLIN'));

reset role;
select tests.login('other');
select is((select count(*)::int from public.cv_suggestions where cv_document_id = tests.id('cv')),
  0, 'another graduate cannot read this CV suggestions');
select is(public.confirm_cv_suggestions(array[tests.id('suggestion')], '{}'),
  '{"confirmed":0,"rejected":0}'::jsonb, 'another graduate cannot confirm another graduate suggestion');

reset role;
select tests.login('graduate');
select is(public.confirm_cv_suggestions(array[tests.id('suggestion')], '{}'),
  '{"confirmed":1,"rejected":0}'::jsonb, 'graduate can confirm their own pending skill suggestion');
select is((select source from public.graduate_skills
  where graduate_id = tests.id('graduate') and skill_id = 'KOTLIN'),
  'CV_CONFIRMED', 'confirmed suggestion becomes a CV_CONFIRMED graduate skill');
select is((select status from public.cv_suggestions where id = tests.id('suggestion')),
  'CONFIRMED', 'confirmed suggestion is marked CONFIRMED');

reset role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select set_config('role', 'service_role', true);
select throws_ok($q$select public.complete_cv_parse(
  tests.id('cv'), tests.id('graduate'), '[]'::jsonb
)$q$, 'PT422', 'CV_NOT_PROCESSING', 'a completed CV cannot be finalized again');

reset role;
select * from finish();
rollback;
