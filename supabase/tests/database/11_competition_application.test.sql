begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$
  select v from tests.ids where k = p_k
$f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users(id,aud,role,email,raw_user_meta_data)
  values(v,'authenticated','authenticated',p_key||'@tests.local',jsonb_build_object('full_name',p_key));
  insert into tests.ids values(p_key,v);
  return v;
end
$f$;
create function tests.mk_opp(p_key text,p_type text,p_props jsonb default '{}') returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.opportunities(seed_key,type,title,status,deadline,end_at,registration_opens_at,attendance_mode)
  values('t-'||p_key,p_type,'Test '||p_key,coalesce(p_props->>'status','ACTIVE'),
    case when p_props ? 'deadline_days' then now()+make_interval(days=>(p_props->>'deadline_days')::int) end,
    case when p_props ? 'end_days' then now()+make_interval(days=>(p_props->>'end_days')::int) end,
    case when p_props ? 'opens_days' then now()+make_interval(days=>(p_props->>'opens_days')::int) end,'ONLINE')
  returning id into v;
  insert into tests.ids values(p_key,v);
  return v;
end
$f$;
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',tests.id(p_key),'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
end
$f$;

do $$
begin
  perform tests.mk_user('a1'); perform tests.mk_user('a2');
  perform tests.mk_opp('c_ok','COMPETITION','{"deadline_days":5}');
  perform tests.mk_opp('c_expired','COMPETITION','{"deadline_days":-1}');
  perform tests.mk_opp('c_closed','COMPETITION','{"deadline_days":5,"status":"CLOSED"}');
  perform tests.mk_opp('c_ended','COMPETITION','{"end_days":-1}');
  perform tests.mk_opp('c_early','COMPETITION','{"deadline_days":5,"opens_days":1}');
  perform tests.mk_opp('c_elig','COMPETITION','{"deadline_days":5}');
  perform tests.mk_opp('c_validation','COMPETITION','{"deadline_days":5}');
  perform tests.mk_opp('s_scholarship','SCHOLARSHIP','{"deadline_days":5}');
  perform tests.mk_opp('j_job','JOB','{"deadline_days":5}');
  perform tests.mk_opp('e_event','EVENT','{"deadline_days":5}');
  insert into public.opportunity_eligibility(opportunity_id,allowed_degrees)
    values(tests.id('c_elig'),array['Master']);
  update public.graduate_profiles set degree='Bachelor' where profile_id=tests.id('a1');
  insert into public.cv_documents(id,graduate_id,storage_path,file_type,size_bytes)
    values('00000000-0000-0000-0000-0000000000d1',tests.id('a1'),tests.id('a1')::text||'/a.pdf','pdf',100),
          ('00000000-0000-0000-0000-0000000000d2',tests.id('a2'),tests.id('a2')::text||'/b.pdf','pdf',100);
  insert into tests.ids values('cv_a','00000000-0000-0000-0000-0000000000d1'),('cv_b','00000000-0000-0000-0000-0000000000d2');
end
$$;

select ok(has_table_privilege('authenticated','public.competition_applications','SELECT'),'authenticated can select own entries');
select ok(not has_table_privilege('authenticated','public.competition_applications','INSERT'),'direct insert denied');
select ok(not has_table_privilege('authenticated','public.competition_applications','UPDATE'),'direct update denied');
select ok(not has_table_privilege('authenticated','public.competition_applications','DELETE'),'direct delete denied');

select tests.login('a1');
select is((public.apply_for_competition(tests.id('c_ok'),tests.id('cv_a'),'I will build an accessible student-services solution.',
  '{"project_title":"Campus Assist","project_url":"https://example.test/project","team_size":3}'::jsonb)).status,
  'SUBMITTED','eligible graduate submits a competition entry');
reset role;
select is((select count(*)::int from public.competition_applications where graduate_id=tests.id('a1') and opportunity_id=tests.id('c_ok')),1,'one entry persisted');
select is((select cv_document_id from public.competition_applications where opportunity_id=tests.id('c_ok')),tests.id('cv_a'),'owned CV attached');
select is((select submission_data from public.competition_applications where opportunity_id=tests.id('c_ok')),
  '{"project_title":"Campus Assist","project_url":"https://example.test/project","team_size":3}'::jsonb,'competition payload persisted');
select is((select count(*)::int from public.competition_application_status_history h join public.competition_applications a on a.id=h.competition_application_id where a.opportunity_id=tests.id('c_ok') and h.new_status='SUBMITTED'),1,'submission audited');
select is((select count(*)::int from public.notifications where profile_id=tests.id('a1') and type='COMPETITION_APPLICATION_SUBMITTED'),1,'submission notification created');
select is((select count(*)::int from public.recommendation_interactions where graduate_id=tests.id('a1') and opportunity_id=tests.id('c_ok') and interaction_type='APPLY'),1,'APPLY recommendation interaction created');

select tests.login('a1');
select throws_ok($q$select public.apply_for_competition(tests.id('c_ok'))$q$,'PT409','ALREADY_APPLIED','duplicate competition entry rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_expired'))$q$,'PT422','OPPORTUNITY_CLOSED','expired deadline rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_closed'))$q$,'PT422','OPPORTUNITY_CLOSED','closed competition rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_ended'))$q$,'PT422','OPPORTUNITY_CLOSED','ended competition rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_early'))$q$,'PT422','OPPORTUNITY_NOT_OPEN','not-yet-open registration window rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('s_scholarship'))$q$,'PT422','NOT_A_COMPETITION','scholarship rejected by competition RPC');
select throws_ok($q$select public.apply_for_competition(tests.id('j_job'))$q$,'PT422','NOT_A_COMPETITION','job rejected by competition RPC');
select throws_ok($q$select public.apply_for_competition(tests.id('e_event'))$q$,'PT422','NOT_A_COMPETITION','ordinary event rejected by competition RPC');
select throws_ok($q$select public.register_for_event(tests.id('c_validation'))$q$,'PT422','NOT_REGISTRABLE','competition is not accidentally treated as event registration');
select throws_ok($q$select public.apply_for_competition(gen_random_uuid())$q$,'PT404','OPPORTUNITY_NOT_FOUND','unknown opportunity rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_elig'))$q$,'PT422','NOT_ELIGIBLE','degree eligibility is checked');
select is(public.get_opportunity_eligibility(tests.id('c_elig')),array['DEGREE_NOT_ALLOWED'],'degree failure is reported');
select is((select count(*)::int from public.competition_applications where graduate_id=tests.id('a1') and opportunity_id<>tests.id('c_ok')),0,'rejected attempts create no rows');
select throws_ok($q$select public.apply_for_competition(tests.id('c_validation'),tests.id('cv_b'))$q$,'PT404','CV_NOT_FOUND','foreign CV rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_validation'),null,null,'[]'::jsonb)$q$,'PT422','INVALID_INPUT','submission data must be JSON object');
select throws_ok($q$select public.apply_for_competition(tests.id('c_validation'),null,null,jsonb_build_object('answer',repeat('x',33000)))$q$,'PT422','INVALID_INPUT','oversized submission data rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_validation'),null,repeat('x',10001))$q$,'PT422','INVALID_INPUT','oversized statement rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_validation'),null,null,null)$q$,'PT422','INVALID_INPUT','null submission data rejected');

select is((public.withdraw_competition_application((select id from public.competition_applications where opportunity_id=tests.id('c_ok')))).status,'WITHDRAWN','owner withdraws entry');
select throws_ok($q$select public.withdraw_competition_application((select id from public.competition_applications where opportunity_id=tests.id('c_ok')))$q$,'PT422','CANNOT_WITHDRAW_COMPETITION_APPLICATION','repeated withdrawal rejected');
select throws_ok($q$select public.apply_for_competition(tests.id('c_ok'))$q$,'PT409','ALREADY_APPLIED','withdrawal cannot bypass duplicate prevention');
reset role;
select is((select count(*)::int from public.competition_application_status_history h join public.competition_applications a on a.id=h.competition_application_id where a.opportunity_id=tests.id('c_ok')),2,'withdrawal status history persisted');
select is((select count(*)::int from public.notifications where profile_id=tests.id('a1') and type='COMPETITION_APPLICATION_WITHDRAWN'),1,'withdrawal notification created');

update public.opportunities set status='CLOSED' where id=tests.id('c_ok');
select tests.login('a1');
select is((select count(*)::int from public.competition_applications where opportunity_id=tests.id('c_ok')),1,'owner can read own entry');
select is((select count(*)::int from public.competition_application_status_history h join public.competition_applications a on a.id=h.competition_application_id where a.opportunity_id=tests.id('c_ok')),2,'owner can read own history');
select ok(exists(select 1 from public.opportunities where id=tests.id('c_ok')),'applicant can still view closed competition');
select throws_ok($q$insert into public.competition_applications(opportunity_id,graduate_id) values(tests.id('c_validation'),tests.id('a1'))$q$,'42501',null,'direct insert denied');
select throws_ok($q$update public.competition_applications set status='WITHDRAWN' where opportunity_id=tests.id('c_ok')$q$,'42501',null,'direct update denied');
select throws_ok($q$delete from public.competition_applications where opportunity_id=tests.id('c_ok')$q$,'42501',null,'direct delete denied');
select tests.login('a2');
select is((select count(*)::int from public.competition_applications where opportunity_id=tests.id('c_ok')),0,'peer cannot read entry');
select is((select count(*)::int from public.competition_application_status_history h join public.competition_applications a on a.id=h.competition_application_id where a.opportunity_id=tests.id('c_ok')),0,'peer cannot read history');
select throws_ok($q$select public.withdraw_competition_application((select id from public.competition_applications where opportunity_id=tests.id('c_ok')))$q$,'PT404','COMPETITION_APPLICATION_NOT_FOUND','peer cannot withdraw entry');
select set_config('request.jwt.claims','',true);
select throws_ok($q$select public.apply_for_competition(tests.id('c_validation'))$q$,'PT401','UNAUTHENTICATED','missing JWT rejected');
reset role;
select set_config('role','anon',true);
select throws_ok($q$select count(*) from public.competition_applications$q$,'42501',null,'anon cannot read competition entries');
select throws_ok($q$select public.apply_for_competition(tests.id('c_validation'))$q$,'42501',null,'anon cannot call competition RPC');
reset role;
select * from finish();
rollback;
