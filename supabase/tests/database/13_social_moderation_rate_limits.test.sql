begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k=p_k $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users(id,aud,role,email,raw_user_meta_data)
  values(v,'authenticated','authenticated',p_key||'@tests.local',jsonb_build_object('full_name',p_key));
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
  perform tests.mk_user('author');
  perform tests.mk_user('reporter');
  perform tests.mk_user('admin');
  perform tests.mk_user('limited');
  insert into private.platform_admins(user_id,is_active) values (tests.id('admin'),true);
end
$$;

-- Private schemas and rate limit RPCs are not directly exposed to app clients.
select ok(not has_table_privilege('authenticated','private.social_content_reports','SELECT'),
  'authenticated cannot read private content reports');
select ok(not has_table_privilege('authenticated','private.social_moderation_events','SELECT'),
  'authenticated cannot read moderation audit');
select ok(not has_table_privilege('authenticated','private.user_rate_limits','SELECT'),
  'authenticated cannot read rate-limit buckets');
select ok(not has_table_privilege('authenticated','private.rate_limit_policies','UPDATE'),
  'authenticated cannot change rate-limit policy');
select ok((select relrowsecurity from pg_class where oid='private.rate_limit_policies'::regclass),
  'rate-limit policy table has RLS enabled');
select ok((select relrowsecurity from pg_class where oid='private.user_rate_limits'::regclass),
  'per-user rate-limit bucket table has RLS enabled');
select ok(not has_function_privilege('authenticated','private.consume_user_rate_limit(uuid,text)','EXECUTE'),
  'authenticated cannot call internal rate limiter');
select ok(not has_function_privilege('authenticated','public.consume_edge_rate_limit(uuid,text)','EXECUTE'),
  'authenticated cannot call Edge Function rate limiter');
select ok(has_function_privilege('service_role','public.consume_edge_rate_limit(uuid,text)','EXECUTE'),
  'service role can consume Edge Function rate limit');
select ok(not has_function_privilege('anon','public.create_social_content_report(text,uuid,text,text)','EXECUTE'),
  'anon cannot report content');
select ok(not has_function_privilege('anon','public.get_social_moderation_queue(text,integer)','EXECUTE'),
  'anon cannot read moderation queue');
select ok((select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','private') and p.prosecdef
 and not exists(select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%'))=0,
 'all new SECURITY DEFINER functions pin search_path');

-- A user can publish, but cannot report their own content.
select tests.login('author');
select is((public.create_social_post('A post that will be reported')).content,
 'A post that will be reported','author can create content');
select throws_ok($q$select * from public.create_social_content_report(
 'POST',(select id from public.get_social_feed(null,null,20) where content='A post that will be reported'),
 'SPAM','self report')$q$,
 'PT422','CANNOT_REPORT_OWN_CONTENT','users cannot report their own content');
reset role;

-- Reporter may file one categorized report. Duplicate reports are rejected and report visibility is scoped.
select tests.login('reporter');
select is((select status from public.create_social_content_report(
 'POST',(select id from public.get_social_feed(null,null,20) where content='A post that will be reported'),
 'SPAM','Repeated unsolicited advertising')),
 'OPEN','report is recorded as open');
select throws_ok($q$select * from public.create_social_content_report(
 'POST',(select id from public.get_social_feed(null,null,20) where content='A post that will be reported'),
 'SPAM','duplicate')$q$,
 'PT409','ALREADY_REPORTED','same reporter cannot duplicate a report');
select is((select count(*)::int from public.get_my_social_reports(20)),1,
 'reporter can see their own report status');
select throws_ok($q$select * from public.get_social_moderation_queue('OPEN',20)$q$,
 'PT403','ADMIN_REQUIRED','non-admin cannot see moderation queue');
select throws_ok($q$select * from public.moderate_social_report(
 (select report_id from public.get_my_social_reports(20)),'HIDE','Not an administrator')$q$,
 'PT403','ADMIN_REQUIRED','non-admin cannot moderate reports');
reset role;

-- A platform administrator can review the report and hide the target; the public feed suppresses it.
select tests.login('admin');
select is((select count(*)::int from public.get_social_moderation_queue('OPEN',20)),1,
 'platform admin can read open moderation queue');
select is((select content_moderation_status from public.moderate_social_report(
 (select report_id from public.get_social_moderation_queue('OPEN',20)),
 'HIDE','Confirmed spam after manual review')),
 'HIDDEN','admin can hide reported content');
reset role;
insert into tests.ids(k,v)
select 'hidden_target', target_id from private.social_content_reports where category='SPAM';
select tests.login('author');
select throws_ok($q$select public.update_social_post(tests.id('hidden_target'),'replace hidden content')$q$,
 'PT404','SOCIAL_POST_NOT_FOUND','author cannot edit content while it is under moderation');
reset role;
select tests.login('admin');
select is((select count(*)::int from public.get_social_moderation_history(
 'POST',(select target_id from public.get_social_moderation_queue('ALL',20)),20)),1,
 'moderation action is recorded in audit history');
select ok(not exists(select 1 from public.get_social_feed(null,null,50)
 where content='A post that will be reported'),
 'hidden post is excluded from feed');
select throws_ok($q$select * from public.get_social_post_comments(
 (select target_id from public.get_social_moderation_queue('ALL',20)),null,null,20)$q$,
 'PT404','SOCIAL_POST_NOT_FOUND','comments on hidden post are inaccessible');
select is(public.restore_social_content(
 'POST',(select target_id from public.get_social_moderation_queue('ALL',20)),
 'Appeal reviewed; content complies'),
 true,'admin can restore content');
select ok(exists(select 1 from public.get_social_feed(null,null,50)
 where content='A post that will be reported'),
 'restored content returns to the feed');
select is((select count(*)::int from public.get_social_moderation_history(
 'POST',(select target_id from public.get_social_moderation_queue('ALL',20)),20)),2,
 'restoration is separately audited');
reset role;

-- The immutable audit trigger rejects tampering even when an operator attempts direct SQL.
select throws_ok($q$update private.social_moderation_events set reason='tampered' where true$q$,
 'PT403','MODERATION_AUDIT_IMMUTABLE','moderation audit cannot be edited');
select throws_ok($q$delete from private.social_moderation_events$q$,
 'PT403','MODERATION_AUDIT_IMMUTABLE','moderation audit cannot be deleted');

-- Dismissal is audited and leaves the original content visible.
select tests.login('reporter');
select is((public.create_social_post('A second post for dismissal test')).content,
 'A second post for dismissal test','reporter can create a separate post');
reset role;
select tests.login('author');
select is((select status from public.create_social_content_report(
 'POST',(select id from public.get_social_feed(null,null,50) where content='A second post for dismissal test'),
 'OTHER','Needs administrator context')),
 'OPEN','second report is accepted');
reset role;
select tests.login('admin');
select is((select status from public.moderate_social_report(
 (select report_id from public.get_social_moderation_queue('OPEN',20)
  where target_id=(select id from public.get_social_feed(null,null,50) where content='A second post for dismissal test')),
 'DISMISS','Review found no policy violation')),
 'DISMISSED','admin can dismiss a report');
select ok(exists(select 1 from public.get_social_feed(null,null,50)
 where content='A second post for dismissal test'),
 'dismissed report does not hide its target');
reset role;
select tests.login('author');
select is((select status from public.create_social_content_report(
 'POST',(select id from public.get_social_feed(null,null,50) where content='A second post for dismissal test'),
 'SPAM','A new report after the earlier report was dismissed')),
 'OPEN','a previously dismissed report does not block a new report');
reset role;

-- Database triggers enforce per-user post limits even if a client bypasses Edge Functions.
select tests.login('limited');
select lives_ok($q$select public.create_social_post('limited post ' || n)
 from generate_series(1,5) n$q$,'five posts fit within the initial token bucket');
select throws_ok($q$select public.create_social_post('sixth post')$q$,
 'PT429','RATE_LIMIT_EXCEEDED','sixth post is rate limited by the database trigger');
reset role;

-- A separate action bucket proves exact retry behaviour and isolation between users/actions.
insert into private.rate_limit_policies(action,capacity,refill_per_second)
values('PGTAP_BUCKET_TEST',2,0.0001);
select is(private.consume_user_rate_limit(tests.id('limited'),'PGTAP_BUCKET_TEST'),0,
 'first token is available');
select is(private.consume_user_rate_limit(tests.id('limited'),'PGTAP_BUCKET_TEST'),0,
 'second token is available');
select ok(private.consume_user_rate_limit(tests.id('limited'),'PGTAP_BUCKET_TEST') > 0,
 'empty bucket returns a retry-after interval');
select is(private.consume_user_rate_limit(tests.id('reporter'),'PGTAP_BUCKET_TEST'),0,
 'rate-limit buckets are isolated per user');

-- A suspended Auth account or disabled admin membership immediately loses moderator authority.
reset role;
update public.profiles set account_status='SUSPENDED' where id=tests.id('admin');
select tests.login('admin');
select throws_ok($q$select * from public.get_social_moderation_queue('OPEN',20)$q$,
 'PT403','ADMIN_REQUIRED','suspended platform admin cannot moderate');
reset role;
update public.profiles set account_status='ACTIVE' where id=tests.id('admin');
update private.platform_admins set is_active=false where user_id=tests.id('admin');
select tests.login('admin');
select throws_ok($q$select * from public.get_social_moderation_queue('OPEN',20)$q$,
 'PT403','ADMIN_REQUIRED','disabled platform-admin membership cannot moderate');
reset role;
update private.platform_admins set is_active=true where user_id=tests.id('admin');

-- Edge-function limiter accepts a service-role context, and refuses authenticated callers.
select tests.login('reporter');
select throws_ok($q$select public.consume_edge_rate_limit(tests.id('reporter'),'CV_PARSE')$q$,
 'PT403','SERVICE_ROLE_REQUIRED','authenticated clients cannot consume arbitrary Edge quotas');
reset role;
select set_config('request.jwt.claims',
  jsonb_build_object('sub',tests.id('admin'),'role','service_role')::text,true);
set local role service_role;
select is(public.consume_edge_rate_limit(tests.id('admin'),'CV_PARSE'),0,
 'service role can consume a graduate-scoped Edge Function quota');
reset role;

-- All reports are auditable, while a normal graduate cannot see the moderation event log.
select tests.login('reporter');
select ok((select count(*) from public.get_my_social_reports(100))>=1,
 'graduate report history remains available to its owner');
select throws_ok($q$select * from public.get_social_moderation_history('POST',gen_random_uuid(),20)$q$,
 'PT403','ADMIN_REQUIRED','non-admin cannot inspect moderation audit');
reset role;

select * from finish();
rollback;
