-- 0027: CV metadata deletion must never orphan a private Storage object silently.
-- Clients use delete_cv_document, which enqueues a durable cleanup row. A service-role worker claims,
-- removes the object through the Storage API, and completes or fails the row. Failures stay retryable.
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
create function tests.add_cv(p_key text, p_user uuid, p_path text) returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes)
  values (p_user, p_path, 'pdf', 1000) returning id into v;
  insert into tests.ids values (p_key, v);
  return v;
end $f$;

select tests.mk_user('cv_owner');
select tests.mk_user('cv_other');
select tests.add_cv('cv1', tests.id('cv_owner'), tests.id('cv_owner')::text || '/cv1.pdf');
select tests.add_cv('cv2', tests.id('cv_owner'), tests.id('cv_owner')::text || '/cv2.pdf');
select tests.add_cv('cv3', tests.id('cv_owner'), tests.id('cv_owner')::text || '/cv3.pdf');
select tests.add_cv('cv_doc_other', tests.id('cv_other'), tests.id('cv_other')::text || '/other.pdf');

-- ---- Direct DELETE is closed; the RPC is the single client path --------------------------------------
select is(has_table_privilege('authenticated', 'public.cv_documents', 'delete'), false,
  'authenticated can no longer delete CV metadata directly through PostgREST');
select is(has_function_privilege('authenticated', 'public.delete_cv_document(uuid)', 'execute'), true,
  'the owner-scoped delete RPC is callable by authenticated');
select is(has_table_privilege('service_role', 'public.cv_documents', 'delete'), true,
  'service_role retains delete for retention/account tooling');

-- Another graduate cannot delete this document.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('cv_other'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select throws_ok(
  format('select public.delete_cv_document(%L)', tests.id('cv1')),
  'PT404', 'CV_NOT_FOUND',
  'a graduate cannot delete another graduate''s CV metadata'
);
reset role;

-- ---- Owner deletion removes metadata and enqueues cleanup --------------------------------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('cv_owner'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is(public.delete_cv_document(tests.id('cv1')) ->> 'deleted', 'true',
  'the owner deletes their CV metadata through the RPC');
reset role;
select is((select count(*)::int from public.cv_documents where id = tests.id('cv1')), 0,
  'the metadata row is deleted');
select is((select count(*)::int from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv1.pdf'), 1,
  'deleting metadata enqueues exactly one Storage cleanup row');
select is((select status from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv1.pdf'),
  'PENDING', 'the cleanup row starts PENDING');

-- ---- Worker claim -> complete is idempotent ---------------------------------------------------------
create table tests.claimed as select public.claim_cv_cleanup(10) as body;
select is(jsonb_array_length((select body from tests.claimed)), 1,
  'the worker claims the pending cleanup row');
select is((select status from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv1.pdf'),
  'PROCESSING', 'claimed rows move to PROCESSING');
select is((select attempts from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv1.pdf'),
  1, 'claiming increments the attempt counter');
select is((select id from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv1.pdf')::text,
  (select body -> 0 ->> 'id' from tests.claimed),
  'the claimed payload identifies the queue row');
select is(public.complete_cv_cleanup((select id from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv1.pdf')), true,
  'the worker marks the row DONE');
select is(public.complete_cv_cleanup((select id from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv1.pdf')), false,
  'completing a non-PROCESSING row is a no-op (idempotent)');
select is(jsonb_array_length(public.claim_cv_cleanup(10)), 0,
  'DONE rows are never claimed again');

-- ---- Failure is recorded and retryable --------------------------------------------------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('cv_owner'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select public.delete_cv_document(tests.id('cv2'));
reset role;
create table tests.claim2 as select public.claim_cv_cleanup(10) as body;
select is(public.fail_cv_cleanup((select body -> 0 ->> 'id' from tests.claim2)::uuid, 'STORAGE_DELETE_FAILED:timeout'), true,
  'the worker records a Storage deletion failure');
select is((select status from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv2.pdf'),
  'FAILED', 'failed cleanup stays visible as FAILED');
select is((select last_error from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv2.pdf'),
  'STORAGE_DELETE_FAILED:timeout', 'the last error is retained for reconciliation');
select is(jsonb_array_length(public.claim_cv_cleanup(10)), 1,
  'FAILED rows are retried by the next worker run');
select is(((public.get_cv_cleanup_report()) ->> 'failed')::int, 1,
  'the reconciliation report exposes the failed backlog');

-- ---- Account deletion cascades metadata into the queue ----------------------------------------------
delete from auth.users where id = tests.id('cv_owner');
select is((select count(*)::int from public.cv_documents where graduate_id = tests.id('cv_owner')), 0,
  'deleting the account cascades CV metadata');
select is((select count(*)::int from private.cv_cleanup_queue where storage_path = tests.id('cv_owner')::text || '/cv3.pdf'), 1,
  'account deletion enqueues cleanup for the cascaded CV object');

-- ---- Only service_role may drive the worker ----------------------------------------------------------
select is(has_function_privilege('authenticated', 'public.claim_cv_cleanup(integer)', 'execute'), false,
  'authenticated cannot claim cleanup work');
select is(has_function_privilege('authenticated', 'public.complete_cv_cleanup(uuid)', 'execute'), false,
  'authenticated cannot mark cleanup complete');
select is(has_function_privilege('authenticated', 'public.fail_cv_cleanup(uuid,text)', 'execute'), false,
  'authenticated cannot mark cleanup failed');
select is(has_function_privilege('service_role', 'public.claim_cv_cleanup(integer)', 'execute'), true,
  'service_role drives the cleanup worker');

select * from finish();
rollback;
