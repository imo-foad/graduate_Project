begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select, insert on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$
  select v from tests.ids where k = p_k
$f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_user_meta_data)
  values (
    v, 'authenticated', 'authenticated',
    p_key || '@tests.local', now(),
    jsonb_build_object('full_name', p_key)
  );
  insert into tests.ids values (p_key, v);
  return v;
end
$f$;
create function tests.mk_opp(p_key text, p_sample boolean default false) returns uuid
language plpgsql as $f$
declare v uuid;
begin
  insert into public.opportunities (
    seed_key, type, title, status, deadline, attendance_mode, is_sample
  ) values (
    't-scholar-' || p_key, 'SCHOLARSHIP', 'Scholarship ' || p_key,
    'ACTIVE', now() + interval '5 days', 'ONLINE', p_sample
  ) returning id into v;
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
  perform tests.mk_user('graduate1');
  perform tests.mk_user('graduate2');
  perform tests.mk_user('graduate3');
  perform tests.mk_user('graduate4');
  perform tests.mk_user('reviewer-a');
  perform tests.mk_user('reviewer-b');
  perform tests.mk_user('admin');
  insert into public.cv_documents(graduate_id,storage_path,file_type,size_bytes)
  values (tests.id('graduate2'),tests.id('graduate2')::text || '/scholarship-review-cv.pdf','pdf',128);
  insert into tests.ids(k,v)
  select 'cv2',id from public.cv_documents
   where graduate_id=tests.id('graduate2')
     and storage_path=tests.id('graduate2')::text || '/scholarship-review-cv.pdf';
  perform tests.mk_opp('scholar1', false);
  perform tests.mk_opp('scholar2', false);
  perform tests.mk_opp('scholar3', false);
  perform tests.mk_opp('scholar4', false);
  perform tests.mk_opp('scholar5', false);
  perform tests.mk_opp('sample-scholar', true);
  insert into private.platform_admins(user_id,is_active)
    values (tests.id('admin'),true);
end
$$;

select ok((select relrowsecurity from pg_class where oid='private.scholarship_provider_mappings'::regclass),
  'provider mapping table has RLS enabled');
select ok((select relrowsecurity from pg_class where oid='private.scholarship_delivery_outbox'::regclass),
  'delivery outbox has RLS enabled');
select ok((select relrowsecurity from pg_class where oid='private.scholarship_delivery_attempts'::regclass),
  'delivery attempt audit has RLS enabled');
select ok((select relrowsecurity from pg_class where oid='private.scholarship_provider_events'::regclass),
  'provider event ledger has RLS enabled');
select ok(not has_table_privilege('authenticated','private.scholarship_provider_mappings','SELECT'),
  'graduates cannot read provider mappings');
select ok(not has_table_privilege('authenticated','private.scholarship_delivery_outbox','SELECT'),
  'graduates cannot read delivery outbox');
select ok(not has_table_privilege('authenticated','private.scholarship_delivery_attempts','SELECT'),
  'graduates cannot read provider delivery attempts');
select ok(not has_table_privilege('authenticated','private.scholarship_provider_events','SELECT'),
  'graduates cannot read provider callback ledger');
select ok(not has_function_privilege('authenticated','public.claim_scholarship_delivery(uuid,integer)','EXECUTE'),
  'authenticated clients cannot claim delivery work');
select ok(not has_function_privilege('authenticated','public.complete_scholarship_delivery(uuid,text,integer,text)','EXECUTE'),
  'authenticated clients cannot mark a delivery as externally submitted');
select ok(not has_function_privilege('authenticated','public.process_scholarship_provider_event(text,text,text,text,text,text)','EXECUTE'),
  'authenticated clients cannot forge provider status updates');
select ok(not has_function_privilege('authenticated','private.is_active_scholarship_reviewer(uuid,text)','EXECUTE'),
  'authenticated clients cannot call the private reviewer authorization helper');

-- A non-sample Scholarship without explicit provider mapping remains in the internal workflow.
select tests.login('graduate1');
select is((public.apply_for_scholarship(tests.id('scholar1'))).status,
  'SUBMITTED','unmapped Scholarship enters the internal admin review queue');
reset role;
select is((select delivery_status from public.scholarship_applications where graduate_id=tests.id('graduate1')),
  'NOT_REQUIRED','internal Scholarship does not require provider delivery');
select is((select count(*)::int from private.scholarship_delivery_outbox
  where application_id=(select id from public.scholarship_applications where graduate_id=tests.id('graduate1'))),
  0,'unmapped internal Scholarship creates no external outbox row');
select ok(not exists(select 1 from public.scholarship_application_status_history h
  join public.scholarship_applications a on a.id=h.scholarship_application_id
  where a.graduate_id=tests.id('graduate1') and h.new_status='SUBMITTED_EXTERNALLY'),
  'saving locally never creates an external-submission history event');

-- A platform admin can configure an external destination; an ordinary graduate cannot.
select tests.login('graduate2');
select throws_ok($q$select public.configure_scholarship_provider_mapping(
 tests.id('scholar2'),'PROVIDER_A','remote-scholarship-2',true)$q$,
 'PT403','ADMIN_REQUIRED','graduate cannot configure provider delivery');
select throws_ok($q$select public.set_scholarship_reviewer(
 tests.id('reviewer-a'),'PROVIDER_A',true)$q$,
 'PT403','ADMIN_REQUIRED','graduate cannot assign reviewers');
reset role;
select tests.login('admin');
select lives_ok($q$select public.configure_scholarship_provider_mapping(
 tests.id('scholar1'),'PROVIDER_A','remote-scholarship-1',true)$q$,
 'active platform admin configures provider mapping');
reset role;
select is((select status from private.scholarship_delivery_outbox
  where application_id=(select id from public.scholarship_applications where graduate_id=tests.id('graduate1'))),
  'PENDING','configuring provider moves blocked application into queue');
select tests.login('admin');
select is((select delivery_status from public.scholarship_applications where graduate_id=tests.id('graduate1')),
  'PENDING','configuring provider updates delivery state without claiming external submission');
select lives_ok($q$select public.configure_scholarship_provider_mapping(
 tests.id('scholar2'),'PROVIDER_A','remote-scholarship-2',true)$q$,
 'admin can configure a second listing under the same provider');
select lives_ok($q$select public.configure_scholarship_provider_mapping(
 tests.id('scholar3'),'PROVIDER_A','remote-scholarship-3',true)$q$,
 'admin can configure a third listing under the same provider');
select lives_ok($q$select public.configure_scholarship_provider_mapping(
 tests.id('scholar4'),'PROVIDER_B','remote-scholarship-4',false)$q$,
 'admin can configure another provider');
select lives_ok($q$select public.configure_scholarship_provider_mapping(
 tests.id('scholar5'),'PROVIDER_B','remote-scholarship-5',true)$q$,
 'admin configures an enabled Provider B listing for its reviewer');
select is(public.set_scholarship_reviewer(tests.id('reviewer-a'),'PROVIDER_A',true),
  true,'admin can assign provider-A reviewer');
select is(public.set_scholarship_reviewer(tests.id('reviewer-b'),'PROVIDER_B',true),
  true,'admin can assign provider-B reviewer');
reset role;
update auth.users set email_confirmed_at=null where id=tests.id('admin');
select tests.login('admin');
select throws_ok($q$select public.assert_scholarship_admin()$q$,
  'PT403','ADMIN_REQUIRED','unconfirmed platform-admin account loses scholarship admin privileges');
reset role;
update auth.users set email_confirmed_at=now() where id=tests.id('admin');

-- Sample listings are clearly internal and never create external delivery work.
select tests.login('graduate4');
select is((public.apply_for_scholarship(tests.id('sample-scholar'))).status,
  'SUBMITTED','sample scholarship remains an internal submission');
reset role;
select is((select delivery_status from public.scholarship_applications
  where opportunity_id=tests.id('sample-scholar')),
  'NOT_REQUIRED','sample scholarship needs no external delivery');
select is((select count(*)::int from private.scholarship_delivery_outbox
  where application_id=(select id from public.scholarship_applications
    where opportunity_id=tests.id('sample-scholar'))),
  0,'sample scholarship has no outbox row');
select ok(exists(select 1 from public.notifications
  where profile_id=tests.id('graduate4') and type='SCHOLARSHIP_APPLICATION_SUBMITTED'),
  'sample submission notification confirms it remains in Alumni Connect');

-- A configured application is queued with a stable idempotency key.
select tests.login('graduate2');
select is((public.apply_for_scholarship(tests.id('scholar2'),tests.id('cv2'))).status,
  'PENDING_DELIVERY','configured scholarship is queued, not falsely marked delivered');
reset role;
insert into tests.ids(k,v)
select 'application2', id from public.scholarship_applications
 where graduate_id=tests.id('graduate2') and opportunity_id=tests.id('scholar2');
select is((select provider_key from public.scholarship_applications where id=tests.id('application2')),
  'PROVIDER_A','application stores its configured provider key');
select is((select external_opportunity_id from private.scholarship_delivery_outbox
  where application_id=tests.id('application2')),
  'remote-scholarship-2','outbox stores remote opportunity reference privately');

-- Only service_role can claim, and duplicate/parallel claims cannot both own one application.
select tests.login('graduate2');
select throws_ok($q$select * from public.claim_scholarship_delivery(tests.id('application2'),1)$q$,
  'PT403','SERVICE_ROLE_REQUIRED','graduate cannot claim a delivery');
reset role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
insert into tests.ids(k,v)
select 'outbox2', outbox_id from public.claim_scholarship_delivery(tests.id('application2'),1);
select is((select status from private.scholarship_delivery_outbox where id=tests.id('outbox2')),
  'PROCESSING','trusted worker atomically claims the delivery');
select is((select delivery_status from public.scholarship_applications where id=tests.id('application2')),
  'PROCESSING','application reflects in-progress delivery');
select is((select count(*)::int from public.claim_scholarship_delivery(tests.id('application2'),1)),
  0,'second worker cannot claim the same unexpired lease');
select is((select idempotency_key from (
  select outbox_id::text as idempotency_key from private.scholarship_delivery_outbox
   where id=tests.id('outbox2')
) q),tests.id('outbox2')::text,'delivery idempotency key is the stable outbox id');
select is((public.complete_scholarship_delivery(
 tests.id('outbox2'),'provider-ref-2',202,'provider-request-2')).status,
 'SUBMITTED_EXTERNALLY','provider acknowledgement moves application to externally submitted');
select is((public.complete_scholarship_delivery(
 tests.id('outbox2'),'provider-ref-2',202,'provider-request-2')).status,
 'SUBMITTED_EXTERNALLY','same provider acknowledgement is idempotent');
select throws_ok($q$select public.complete_scholarship_delivery(
 tests.id('outbox2'),'different-provider-ref',202,'provider-request-2')$q$,
 'PT409','SCHOLARSHIP_PROVIDER_REFERENCE_CONFLICT','conflicting provider acknowledgement cannot overwrite the reference');
reset role;

select is((select delivery_status from public.scholarship_applications where id=tests.id('application2')),
  'DELIVERED','acknowledged application delivery state is delivered');
select is((select provider_application_reference from public.scholarship_applications where id=tests.id('application2')),
  'provider-ref-2','provider application reference is persisted');
select is((select count(*)::int from private.scholarship_delivery_attempts
  where outbox_id=tests.id('outbox2') and outcome='DELIVERED' and provider_request_id='provider-request-2'),
  1,'successful delivery is audit logged with provider request id');
select ok(exists(select 1 from public.notifications
  where profile_id=tests.id('graduate2') and type='SCHOLARSHIP_APPLICATION_SUBMITTED_EXTERNALLY'),
  'graduate is notified only after provider acknowledgement');
select tests.login('graduate2');
select throws_ok($q$select public.withdraw_scholarship_application(tests.id('application2'))$q$,
  'PT422','CANNOT_WITHDRAW_SCHOLARSHIP_APPLICATION','cannot locally withdraw after external submission');

-- Reviewer authorization is provider-scoped. Review transitions are ordered and audited.
select tests.login('graduate2');
select throws_ok($q$select public.get_scholarship_review_cv_path(tests.id('application2'))$q$,
  'PT403','SCHOLARSHIP_REVIEWER_REQUIRED','graduate who is not a reviewer cannot use reviewer CV endpoint');
reset role;
select tests.login('reviewer-a');
select is((select count(*)::int from public.get_scholarship_review_queue('PROVIDER_A','SUBMITTED_EXTERNALLY',50)),
  1,'provider-A reviewer sees only provider-A submitted applications');
select throws_ok($q$select * from public.get_scholarship_review_queue('PROVIDER_B',null,50)$q$,
  'PT403','SCHOLARSHIP_REVIEWER_REQUIRED','provider-A reviewer cannot inspect provider-B queue');
select is(public.get_scholarship_review_cv_path(tests.id('application2')),
  tests.id('graduate2')::text || '/scholarship-review-cv.pdf',
  'provider-A reviewer can access the attached CV path for provider-A application');
reset role;
select tests.login('reviewer-b');
select throws_ok($q$select public.get_scholarship_review_cv_path(tests.id('application2'))$q$,
  'PT403','SCHOLARSHIP_REVIEWER_REQUIRED','provider-B reviewer cannot access provider-A CV');
reset role;
select tests.login('reviewer-a');
select is((public.review_scholarship_application(
 tests.id('application2'),'IN_REVIEW','Eligibility and documents are under review')).status,
 'IN_REVIEW','authorized reviewer can move submitted application into review');
select is((public.review_scholarship_application(
 tests.id('application2'),'ACCEPTED','All criteria satisfied by the applicant')).status,
 'ACCEPTED','reviewer can accept after review starts');
select throws_ok($q$select public.review_scholarship_application(
 tests.id('application2'),'REJECTED','Try to change a final decision')$q$,
 'PT409','INVALID_SCHOLARSHIP_STATUS_TRANSITION','final review decision cannot be overwritten');
reset role;
select is((select count(*)::int from public.scholarship_application_status_history
  where scholarship_application_id=tests.id('application2') and source_type='REVIEWER'),
  2,'both reviewer transitions are audited');
select ok(exists(select 1 from public.notifications
  where profile_id=tests.id('graduate2') and type='SCHOLARSHIP_APPLICATION_ACCEPTED'),
  'graduate is notified of final reviewer decision');

-- Provider callbacks are service-role-only, reference-bound, idempotent and transition-checked.
select tests.login('graduate3');
select is((public.apply_for_scholarship(tests.id('scholar3'))).status,
  'PENDING_DELIVERY','second configured application enters pending state');
reset role;
insert into tests.ids(k,v)
select 'application3',id from public.scholarship_applications
 where graduate_id=tests.id('graduate3') and opportunity_id=tests.id('scholar3');
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
insert into tests.ids(k,v)
select 'outbox3',outbox_id from public.claim_scholarship_delivery(tests.id('application3'),1);
select is((public.complete_scholarship_delivery(
 tests.id('outbox3'),'provider-ref-3',200,null)).status,
 'SUBMITTED_EXTERNALLY','third application acknowledged externally');
select is(public.process_scholarship_provider_event(
 'PROVIDER_A','event-001','provider-ref-3','IN_REVIEW','Review started',repeat('a',64)),
 'IN_REVIEW','provider can move a delivered application into review');
select is(public.process_scholarship_provider_event(
 'PROVIDER_A','event-001','provider-ref-3','IN_REVIEW','Review started',repeat('a',64)),
 'DUPLICATE','provider callback retries are idempotent');
select throws_ok($q$select public.process_scholarship_provider_event(
 'PROVIDER_A','event-001','provider-ref-3','REJECTED','Tampered reuse',repeat('b',64))$q$,
 'PT409','PROVIDER_EVENT_ID_CONFLICT','provider event id cannot be reused with a different payload');
select is(public.process_scholarship_provider_event(
 'PROVIDER_A','event-002','provider-ref-3','REJECTED','Does not meet current criteria',repeat('c',64)),
 'REJECTED','provider can submit a final rejection');
reset role;
select is((select status from public.scholarship_applications where id=tests.id('application3')),
  'REJECTED','provider callback updates application state');
select is((select count(*)::int from private.scholarship_provider_events
  where provider_key='PROVIDER_A' and event_id in ('event-001','event-002')),
  2,'provider event ledger stores each unique accepted event once');

-- Retryable HTTP failure remains pending; max attempts become a terminal delivery failure.
select tests.login('graduate1');
select is((public.apply_for_scholarship(tests.id('scholar2'))).status,
  'PENDING_DELIVERY','a separate graduate may apply to the same scholarship');
reset role;
insert into tests.ids(k,v)
select 'application_retry',id from public.scholarship_applications
 where graduate_id=tests.id('graduate1') and opportunity_id=tests.id('scholar2');
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
update private.scholarship_delivery_outbox set max_attempts=1
 where application_id=tests.id('application_retry');
insert into tests.ids(k,v)
select 'outbox_retry',outbox_id from public.claim_scholarship_delivery(tests.id('application_retry'),1);
select is(public.fail_scholarship_delivery(
 tests.id('outbox_retry'),'PROVIDER_HTTP_ERROR',503,true,15),
 'FAILED','last exhausted attempt becomes terminal delivery failure');
reset role;
select is((select status from public.scholarship_applications where id=tests.id('application_retry')),
  'DELIVERY_FAILED','application clearly records terminal delivery failure');
select tests.login('admin');
select is(public.retry_scholarship_delivery(tests.id('application_retry')),
  true,'active platform admin can queue an explicit retry');
reset role;
select is((select status from public.scholarship_applications where id=tests.id('application_retry')),
  'PENDING_DELIVERY','administrator retry returns application to pending, not externally submitted');
select is((select delivery_generation from private.scholarship_delivery_outbox
  where id=tests.id('outbox_retry')),2,'manual retry starts a new delivery generation');
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
select is((select count(*)::int from public.claim_scholarship_delivery(tests.id('application_retry'),1)),
  1,'worker can claim the new delivery generation');
select is(public.fail_scholarship_delivery(
 tests.id('outbox_retry'),'PROVIDER_REJECTED',400,false,null),
 'FAILED','permanent failure is recorded in the new generation');
reset role;
select is((select count(*)::int from private.scholarship_delivery_attempts
  where outbox_id=tests.id('outbox_retry') and delivery_generation=1 and attempt_number=1),
  1,'the first delivery generation audit remains immutable');
select is((select count(*)::int from private.scholarship_delivery_attempts
  where outbox_id=tests.id('outbox_retry') and delivery_generation=2 and attempt_number=1),
  1,'a retry may reuse attempt number one in a separate generation');

-- A disabled provider mapping blocks external delivery; re-enable it before withdrawal.
select tests.login('graduate4');
select is((public.apply_for_scholarship(tests.id('scholar4'))).status,
  'PENDING_DELIVERY','disabled provider mapping records a pending application');
reset role;
insert into tests.ids(k,v)
select 'application4',id from public.scholarship_applications
 where graduate_id=tests.id('graduate4') and opportunity_id=tests.id('scholar4');
select is((select delivery_status from public.scholarship_applications where id=tests.id('application4')),
  'BLOCKED','disabled provider mapping keeps delivery blocked');
select is((select status from private.scholarship_delivery_outbox where application_id=tests.id('application4')),
  'BLOCKED','disabled provider mapping creates blocked outbox row');
select tests.login('admin');
select lives_ok($q$select public.configure_scholarship_provider_mapping(
 tests.id('scholar4'),'PROVIDER_B','remote-scholarship-4',true)$q$,
 'admin re-enables external provider delivery');
reset role;
select is((select delivery_status from public.scholarship_applications where id=tests.id('application4')),
  'PENDING','re-enabled provider mapping unblocks the application');
select is((select status from private.scholarship_delivery_outbox where application_id=tests.id('application4')),
  'PENDING','re-enabled provider mapping queues the outbox item');
select tests.login('graduate4');
select is((public.withdraw_scholarship_application(tests.id('application4'))).status,
  'WITHDRAWN','graduate can withdraw before external delivery starts');
reset role;
select is((select status from private.scholarship_delivery_outbox
  where application_id=tests.id('application4')),
  'CANCELLED','withdrawal cancels the pending outbox item');

select * from finish();
rollback;
