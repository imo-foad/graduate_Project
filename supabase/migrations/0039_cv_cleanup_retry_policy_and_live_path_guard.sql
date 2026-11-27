-- 0039: CV Storage cleanup retry policy and live-path guard (issue #18).
--
-- 0027/0030 made cleanup durable and crash-recoverable, but two gaps remained:
--   * every failed attempt was immediately eligible again, so a persistent Storage error was retried
--     on every worker invocation with no operational spacing (ten quick claims could exhaust a row);
--   * a metadata row that re-used a Storage path (re-upload after deletion, or a replacement written by
--     retention tooling) could be deleted by a cleanup row that was queued earlier, removing live bytes.
--
-- This migration is additive. It does not edit 0027 or 0030, does not write to storage.objects, and keeps
-- the service-role-only worker contract. The retry delay is bounded exponential backoff:
-- attempt 1 -> 60s, 2 -> 120s, 3 -> 240s ... capped at 1800s. Ten attempts remain the hard limit, and an
-- exhausted row requires the explicit service-role retry_cv_cleanup operator action.

-- ---------------------------------------------------------------------------------------------------
-- 1. Bounded exponential backoff used when a worker records a failure.
-- ---------------------------------------------------------------------------------------------------
create or replace function private.cv_cleanup_backoff_seconds(p_attempts integer)
returns integer
language sql
immutable
set search_path = ''
as $cv_cleanup_backoff_seconds$
  select least(
    1800,
    (60 * power(2, greatest(0, least(coalesce(p_attempts, 1), 10) - 1)))::integer
  );
$cv_cleanup_backoff_seconds$;

revoke all on function private.cv_cleanup_backoff_seconds(integer) from public, anon, authenticated;
comment on function private.cv_cleanup_backoff_seconds(integer) is
  'Bounded exponential retry delay (60s doubling, cap 1800s) for CV Storage cleanup attempts.';

-- A newly inserted or replaced metadata row makes its Storage path live again. Any queued-but-not-claimed
-- cleanup for that exact path is cancelled, so a re-upload of the same object key is never deleted.
create or replace function private.cancel_cv_cleanup_for_live_path()
returns trigger
language plpgsql
security definer
set search_path = ''
as $cancel_cv_cleanup_for_live_path$
begin
  update private.cv_cleanup_queue
     set status = 'DONE',
         last_error = 'PATH_REUSED_CLEANUP_CANCELLED',
         claimed_at = null,
         next_attempt_at = null,
         updated_at = now()
   where storage_path = new.storage_path
     and status in ('PENDING', 'FAILED');
  return new;
end
$cancel_cv_cleanup_for_live_path$;
revoke all on function private.cancel_cv_cleanup_for_live_path() from public, anon, authenticated;

drop trigger if exists cv_documents_cancel_stale_cleanup on public.cv_documents;
create trigger cv_documents_cancel_stale_cleanup
  after insert or update of storage_path on public.cv_documents
  for each row execute function private.cancel_cv_cleanup_for_live_path();

-- ---------------------------------------------------------------------------------------------------
-- 2. Failure schedules the next attempt instead of re-queueing immediately.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.fail_cv_cleanup(p_id uuid, p_error text)
returns boolean
language plpgsql security definer set search_path = ''
as $fail_cv_cleanup_v3$
declare
  v_rows integer;
begin
  update private.cv_cleanup_queue
     set status = 'FAILED',
         last_error = left(coalesce(nullif(btrim(p_error), ''), 'UNKNOWN_CLEANUP_ERROR'), 500),
         claimed_at = null,
         -- The delay lives in next_attempt_at and is recomputed from the current attempt count.
         next_attempt_at = now() + make_interval(
           secs => private.cv_cleanup_backoff_seconds(attempts)
         ),
         updated_at = now()
   where id = p_id
     and status = 'PROCESSING';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end
$fail_cv_cleanup_v3$;

-- ---------------------------------------------------------------------------------------------------
-- 3. Claiming refuses to hand a worker a path that metadata currently references, and finishes
--    queued work whose path became live again between failures.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.claim_cv_cleanup(p_limit integer default 20)
returns jsonb
language plpgsql security definer set search_path = ''
as $claim_cv_cleanup_v3$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
  v_items jsonb;
begin
  -- A queued path that is referenced again must never be deleted. Mark it resolved without attempting
  -- a Storage call. (A row already claimed by another worker is protected by its lease and by the
  -- insert trigger above; this covers PENDING/FAILED rows.)
  update private.cv_cleanup_queue q
     set status = 'DONE',
         last_error = 'PATH_STILL_REFERENCED',
         claimed_at = null,
         next_attempt_at = null,
         updated_at = now()
   where q.status in ('PENDING', 'FAILED')
     and exists (
       select 1 from public.cv_documents d where d.storage_path = q.storage_path
     );

  -- A crashed worker's lease becomes retryable immediately. Its attempt was already counted when it
  -- was claimed, so the counter keeps reflecting real work performed.
  update private.cv_cleanup_queue
     set status = 'FAILED',
         last_error = coalesce(last_error, 'WORKER_LEASE_EXPIRED'),
         claimed_at = null,
         next_attempt_at = now(),
         updated_at = now()
   where status = 'PROCESSING'
     and (claimed_at is null or claimed_at < now() - interval '15 minutes');

  with picked as (
    select q2.id
      from private.cv_cleanup_queue q2
     where q2.status in ('PENDING', 'FAILED')
       and q2.attempts < 10
       and coalesce(q2.next_attempt_at, q2.created_at) <= now()
       and not exists (
         select 1 from public.cv_documents d where d.storage_path = q2.storage_path
       )
     order by coalesce(q2.next_attempt_at, q2.created_at), q2.created_at, q2.id
     for update skip locked
     limit v_limit
  ), updated as (
    update private.cv_cleanup_queue q
       set status = 'PROCESSING',
           attempts = q.attempts + 1,
           claimed_at = now(),
           next_attempt_at = null,
           updated_at = now()
      from picked p
     where q.id = p.id
    returning q.id, q.storage_path, q.graduate_id, q.attempts, q.reason, q.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id,
    'storage_path', u.storage_path,
    'graduate_id', u.graduate_id,
    'attempts', u.attempts,
    'reason', u.reason
  ) order by u.created_at, u.id), '[]'::jsonb)
    into v_items
    from updated u;

  return v_items;
end
$claim_cv_cleanup_v3$;

-- ---------------------------------------------------------------------------------------------------
-- 4. Reconciliation report: distinguish never-attempted work, retry-ready, scheduled and exhausted.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.get_cv_cleanup_report()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $get_cv_cleanup_report_v3$
begin
  return jsonb_build_object(
    'pending', (select count(*) from private.cv_cleanup_queue
                 where status = 'PENDING' and attempts = 0),
    'processing', (select count(*) from private.cv_cleanup_queue where status = 'PROCESSING'),
    'failed', (select count(*) from private.cv_cleanup_queue where status = 'FAILED'),
    'retry_ready', (select count(*) from private.cv_cleanup_queue
                     where status in ('PENDING', 'FAILED') and attempts < 10
                       and coalesce(next_attempt_at, created_at) <= now()),
    'retry_scheduled', (select count(*) from private.cv_cleanup_queue
                         where status = 'FAILED' and attempts < 10
                           and next_attempt_at > now()),
    'done', (select count(*) from private.cv_cleanup_queue where status = 'DONE'),
    'exhausted', (select count(*) from private.cv_cleanup_queue
                   where status = 'FAILED' and attempts >= 10),
    'oldest_pending_at', (select min(created_at) from private.cv_cleanup_queue
                           where status in ('PENDING', 'FAILED'))
  );
end
$get_cv_cleanup_report_v3$;

revoke all on function public.claim_cv_cleanup(integer),
              public.fail_cv_cleanup(uuid, text),
              public.get_cv_cleanup_report()
  from public, anon, authenticated;
grant execute on function public.claim_cv_cleanup(integer),
  public.fail_cv_cleanup(uuid, text),
  public.get_cv_cleanup_report()
  to service_role;

comment on function public.fail_cv_cleanup(uuid, text) is
  'Service-role worker: records a failed Storage deletion and schedules a bounded exponential retry (60s doubling, cap 1800s, ten attempts total).';
comment on function public.claim_cv_cleanup(integer) is
  'Service-role worker: transactionally claims due cleanup rows, recovers expired leases, and resolves queued paths that metadata now references again.';
