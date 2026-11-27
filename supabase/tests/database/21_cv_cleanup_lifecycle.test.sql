-- 0039: CV cleanup retry policy and live-path guard (issue #18).
-- Proves bounded exponential backoff, exhausted-attempt handling, expired-lease recovery, the
-- "metadata still references this path" guard and service-role-only worker privileges.
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
create function tests.clear_queue() returns void language sql as $f$
  delete from private.cv_cleanup_queue;
$f$;
create function tests.login_owner(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $f$;

select tests.mk_user('owner');
select tests.mk_user('other');
select tests.add_cv('stale', tests.id('owner'), tests.id('owner')::text || '/stale.pdf');

-- ---- Bounded exponential backoff schedule ---------------------------------------------------------
select is(private.cv_cleanup_backoff_seconds(0), 60, 'attempt 0/1 waits 60 seconds');
select is(private.cv_cleanup_backoff_seconds(1), 60, 'first failed attempt waits 60 seconds');
select is(private.cv_cleanup_backoff_seconds(2), 120, 'second failed attempt waits 120 seconds');
select is(private.cv_cleanup_backoff_seconds(3), 240, 'third failed attempt waits 240 seconds');
select is(private.cv_cleanup_backoff_seconds(10), 1800, 'attempt ten is capped at 30 minutes');
select is(private.cv_cleanup_backoff_seconds(99), 1800, 'attempts above the cap stay capped');
select is(has_function_privilege('authenticated', 'private.cv_cleanup_backoff_seconds(integer)', 'execute'), false,
  'clients cannot read the internal retry schedule helper');

-- ---- A failure is scheduled, not immediately retried ---------------------------------------------
select tests.login_owner('owner');
select public.delete_cv_document(tests.id('stale'));
reset role;
create table tests.claim1 as select public.claim_cv_cleanup(10) as body;
select is(jsonb_array_length((select body from tests.claim1)), 1, 'the worker claims the due row');
select is(public.fail_cv_cleanup((select body -> 0 ->> 'id' from tests.claim1)::uuid, 'STORAGE_DELETE_FAILED'), true,
  'the worker records a failed Storage deletion');
select is((select status from private.cv_cleanup_queue where storage_path = tests.id('owner')::text || '/stale.pdf'),
  'FAILED', 'the row remains FAILED for reconciliation');
select ok((select next_attempt_at between now() + interval '45 seconds' and now() + interval '75 seconds'
             from private.cv_cleanup_queue where storage_path = tests.id('owner')::text || '/stale.pdf'),
  'the first failure is scheduled roughly 60 seconds later, not immediately retried');
select is(jsonb_array_length(public.claim_cv_cleanup(10)), 0,
  'a scheduled row is not claimed before its next_attempt_at');
select is(((public.get_cv_cleanup_report()) ->> 'retry_scheduled')::int, 1,
  'the reconciliation report exposes the scheduled retry');
select is(((public.get_cv_cleanup_report()) ->> 'retry_ready')::int, 0,
  'a scheduled row is not reported as immediately retry-ready');
select is((select attempts from private.cv_cleanup_queue where storage_path = tests.id('owner')::text || '/stale.pdf'),
  1, 'a failed attempt is counted exactly once');

-- Advance the controlled test clock and retry: the delay doubles with the attempt count.
update private.cv_cleanup_queue set next_attempt_at = now() - interval '1 second'
 where storage_path = tests.id('owner')::text || '/stale.pdf';
create table tests.claim2 as select public.claim_cv_cleanup(10) as body;
select is(jsonb_array_length((select body from tests.claim2)), 1, 'a due retry is claimed');
select is((select attempts from private.cv_cleanup_queue where storage_path = tests.id('owner')::text || '/stale.pdf'),
  2, 'the retry increments the attempt counter');
select is(public.fail_cv_cleanup((select body -> 0 ->> 'id' from tests.claim2)::uuid, 'STORAGE_DELETE_FAILED'), true,
  'the second failure is recorded');
select ok((select next_attempt_at between now() + interval '105 seconds' and now() + interval '135 seconds'
             from private.cv_cleanup_queue where storage_path = tests.id('owner')::text || '/stale.pdf'),
  'the second failure schedules a 120 second retry');

-- ---- Exhausted attempts require the explicit operator retry ---------------------------------------
update private.cv_cleanup_queue set attempts = 10 where storage_path = tests.id('owner')::text || '/stale.pdf';
select is(jsonb_array_length(public.claim_cv_cleanup(10)), 0, 'an exhausted row is never claimed automatically');
select is(((public.get_cv_cleanup_report()) ->> 'exhausted')::int, 1,
  'the reconciliation report exposes the exhausted row');
select is(has_function_privilege('authenticated', 'public.retry_cv_cleanup(uuid)', 'execute'), false,
  'an authenticated client cannot requeue exhausted cleanup work');
select is(has_function_privilege('service_role', 'public.retry_cv_cleanup(uuid)', 'execute'), true,
  'only the service-role operator path can requeue exhausted work');
select is(public.retry_cv_cleanup((select id from private.cv_cleanup_queue
  where storage_path = tests.id('owner')::text || '/stale.pdf')), true,
  'the operator requeues the exhausted row');
select is((select attempts from private.cv_cleanup_queue where storage_path = tests.id('owner')::text || '/stale.pdf'),
  0, 'the operator retry resets the attempt budget');
select is(jsonb_array_length(public.claim_cv_cleanup(10)), 1, 'the requeued row is claimable again');
update private.cv_cleanup_queue set status = 'PROCESSING', claimed_at = now()
 where storage_path = tests.id('owner')::text || '/stale.pdf';
select is(public.complete_cv_cleanup((select id from private.cv_cleanup_queue
  where storage_path = tests.id('owner')::text || '/stale.pdf')), true,
  'a recovered retry reaches DONE');
select is(public.complete_cv_cleanup((select id from private.cv_cleanup_queue
  where storage_path = tests.id('owner')::text || '/stale.pdf')), false,
  'duplicate completion of a DONE row is a no-op');
select is(public.fail_cv_cleanup((select id from private.cv_cleanup_queue
  where storage_path = tests.id('owner')::text || '/stale.pdf'), 'late failure'), false,
  'a duplicate failure after completion cannot regress a DONE row');

-- ---- Expired lease recovery keeps the attempt counter truthful -------------------------------------
select tests.clear_queue();
select tests.add_cv('lease', tests.id('owner'), tests.id('owner')::text || '/lease.pdf');
select tests.login_owner('owner');
select public.delete_cv_document(tests.id('lease'));
reset role;
create table tests.lease_claim as select public.claim_cv_cleanup(10) as body;
select is(jsonb_array_length((select body from tests.lease_claim)), 1, 'the worker claims the lease fixture');
update private.cv_cleanup_queue set claimed_at = now() - interval '16 minutes'
 where storage_path = tests.id('owner')::text || '/lease.pdf';
create table tests.lease_reclaim as select public.claim_cv_cleanup(10) as body;
select is(jsonb_array_length((select body from tests.lease_reclaim)), 1,
  'an abandoned 15 minute worker lease becomes claimable again');
select is((select body -> 0 ->> 'attempts' from tests.lease_reclaim)::int, 2,
  'lease recovery counts the crashed attempt and the new one');
select ok((select claimed_at > now() - interval '1 minute' from private.cv_cleanup_queue
  where storage_path = tests.id('owner')::text || '/lease.pdf'),
  'the reclaimed row carries a fresh lease timestamp');
select is(jsonb_array_length(public.claim_cv_cleanup(10)), 0,
  'another worker cannot claim a row that is currently leased');

-- ---- Storage paths become immutable retired tombstones in every queue state -----------------------
select tests.clear_queue();
select tests.add_cv('retired_pending', tests.id('owner'), tests.id('owner')::text || '/retired-pending.pdf');
select tests.login_owner('owner');
select public.delete_cv_document(tests.id('retired_pending'));
reset role;
select is((select status from private.cv_cleanup_queue
            where storage_path = tests.id('owner')::text || '/retired-pending.pdf'),
  'PENDING', 'deleting metadata creates a PENDING tombstone');
select throws_ok(
  format('select tests.add_cv(%L, %L::uuid, %L)',
    'retired_pending_again', tests.id('owner'), tests.id('owner')::text || '/retired-pending.pdf'),
  '23514', 'CV_STORAGE_PATH_RETIRED',
  'a PENDING path cannot be registered again');

update private.cv_cleanup_queue
   set status = 'PROCESSING', attempts = 1, claimed_at = now()
 where storage_path = tests.id('owner')::text || '/retired-pending.pdf';
select throws_ok(
  format('select tests.add_cv(%L, %L::uuid, %L)',
    'retired_processing_again', tests.id('owner'), tests.id('owner')::text || '/retired-pending.pdf'),
  '23514', 'CV_STORAGE_PATH_RETIRED',
  'a PROCESSING path cannot be registered again');

update private.cv_cleanup_queue
   set status = 'FAILED', claimed_at = null, next_attempt_at = now() + interval '60 seconds'
 where storage_path = tests.id('owner')::text || '/retired-pending.pdf';
select throws_ok(
  format('select tests.add_cv(%L, %L::uuid, %L)',
    'retired_failed_again', tests.id('owner'), tests.id('owner')::text || '/retired-pending.pdf'),
  '23514', 'CV_STORAGE_PATH_RETIRED',
  'a FAILED path cannot be registered again');

update private.cv_cleanup_queue
   set status = 'DONE', claimed_at = null, next_attempt_at = null
 where storage_path = tests.id('owner')::text || '/retired-pending.pdf';
select throws_ok(
  format('select tests.add_cv(%L, %L::uuid, %L)',
    'retired_done_again', tests.id('owner'), tests.id('owner')::text || '/retired-pending.pdf'),
  '23514', 'CV_STORAGE_PATH_RETIRED',
  'a DONE path remains a permanent tombstone');

select is((select count(*)::int from public.cv_documents
            where storage_path = tests.id('owner')::text || '/retired-pending.pdf'), 0,
  'no active metadata row references the retired path');
select is((select count(*)::int from private.cv_cleanup_queue
            where storage_path = tests.id('owner')::text || '/retired-pending.pdf'), 1,
  'the retired Storage path has exactly one permanent queue record');

-- An expired lease is recovered and re-claimed without removing its tombstone.
update private.cv_cleanup_queue
   set status = 'PROCESSING', attempts = 1, claimed_at = now() - interval '16 minutes'
 where storage_path = tests.id('owner')::text || '/retired-pending.pdf';
create table tests.retired_lease_claim as select public.claim_cv_cleanup(10) as body;
select is(jsonb_array_length((select body from tests.retired_lease_claim)), 1,
  'an expired lease is recovered and the retired item is re-claimed');
select is((select body -> 0 ->> 'attempts' from tests.retired_lease_claim)::int, 2,
  'expired-lease recovery preserves the attempt count');
select throws_ok(
  format('select tests.add_cv(%L, %L::uuid, %L)',
    'retired_after_lease', tests.id('owner'), tests.id('owner')::text || '/retired-pending.pdf'),
  '23514', 'CV_STORAGE_PATH_RETIRED',
  'an expired/reclaimed worker lease cannot make a path reusable');
select is((select status from private.cv_cleanup_queue
            where storage_path = tests.id('owner')::text || '/retired-pending.pdf'),
  'PROCESSING', 'lease recovery does not remove the path tombstone');

-- A never-used key is accepted and a path replacement queues only the superseded key.
select tests.add_cv('fresh_path', tests.id('owner'), tests.id('owner')::text || '/fresh-after-retirement.pdf');
select is((select count(*)::int from public.cv_documents
            where storage_path = tests.id('owner')::text || '/fresh-after-retirement.pdf'), 1,
  'a fresh never-used Storage path registers normally');

select tests.add_cv('replace_path', tests.id('owner'), tests.id('owner')::text || '/replace-old.pdf');
update public.cv_documents
   set storage_path = tests.id('owner')::text || '/replace-new.pdf'
 where id = tests.id('replace_path');
select is((select count(*)::int from private.cv_cleanup_queue
            where storage_path = tests.id('owner')::text || '/replace-old.pdf'), 1,
  'replacing a CV queues the old Storage path exactly once');
select is((select count(*)::int from private.cv_cleanup_queue
            where storage_path = tests.id('owner')::text || '/replace-new.pdf'), 0,
  'replacing a CV does not queue the new Storage path');
select is((select count(*)::int from public.cv_documents
            where id = tests.id('replace_path')
              and storage_path = tests.id('owner')::text || '/replace-new.pdf'), 1,
  'the new CV metadata remains active on its fresh path');
select throws_ok(
  format('select tests.add_cv(%L, %L::uuid, %L)',
    'replace_old_reuse', tests.id('owner'), tests.id('owner')::text || '/replace-old.pdf'),
  '23514', 'CV_STORAGE_PATH_RETIRED',
  'a superseded path cannot be registered again');

-- Every queue insert is serialized with metadata writes and must never overlap active metadata.
select throws_ok(
  format('insert into private.cv_cleanup_queue (storage_path, graduate_id, reason) values (%L, %L::uuid, %L)',
    tests.id('owner')::text || '/fresh-after-retirement.pdf', tests.id('owner'), 'METADATA_DELETE'),
  '23514', 'CV_STORAGE_PATH_LIVE',
  'the queue cannot retire a path that still has live metadata');
select is((select count(*)::int
            from public.cv_documents d
            join private.cv_cleanup_queue q on q.storage_path = d.storage_path), 0,
  'no active metadata row references any cleanup-queue path');

select throws_ok(
  format('update private.cv_cleanup_queue set storage_path = %L where storage_path = %L',
    tests.id('owner')::text || '/mutated-tombstone.pdf',
    tests.id('owner')::text || '/retired-pending.pdf'),
  '23514', 'CV_CLEANUP_STORAGE_PATH_IMMUTABLE',
  'a queue tombstone path itself cannot be changed');
select is(has_table_privilege('authenticated', 'private.cv_cleanup_queue', 'insert'), false,
  'authenticated cannot insert or inspect private cleanup queue rows');
select is(has_function_privilege('authenticated', 'private.lock_cv_storage_paths(text[])', 'execute'), false,
  'authenticated cannot execute the advisory-lock helper');

-- ---- Worker RPC privileges remain service-role only -----------------------------------------------
select is(has_function_privilege('authenticated', 'public.claim_cv_cleanup(integer)', 'execute'), false,
  'authenticated cannot claim cleanup work');
select is(has_function_privilege('authenticated', 'public.complete_cv_cleanup(uuid)', 'execute'), false,
  'authenticated cannot complete cleanup work');
select is(has_function_privilege('authenticated', 'public.fail_cv_cleanup(uuid,text)', 'execute'), false,
  'authenticated cannot fail cleanup work');
select is(has_function_privilege('authenticated', 'public.get_cv_cleanup_report()', 'execute'), false,
  'authenticated cannot read the cleanup reconciliation report');
select is(has_table_privilege('authenticated', 'private.cv_cleanup_queue', 'select'), false,
  'authenticated cannot read the private cleanup queue');

select * from finish();
rollback;
