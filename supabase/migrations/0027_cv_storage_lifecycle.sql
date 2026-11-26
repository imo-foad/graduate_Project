-- 0027: CV Storage lifecycle (issue #18).
--
-- Supabase Storage bytes live outside Postgres, so deleting a cv_documents row can never delete the
-- object in the same transaction. This migration makes that gap explicit and recoverable:
--   * clients stop deleting metadata directly; the owner-scoped RPC delete_cv_document is the only path;
--   * deleting metadata (including a profile/account cascade) enqueues a durable cleanup row;
--   * a service-role worker function claims rows, removes the private object through the Storage API,
--     and marks the row DONE/FAILED with bounded attempts and the last error;
--   * failure never deletes metadata silently: the row and its queue entry stay for reconciliation.
-- Nothing here writes to storage.objects directly (Supabase blocks that), and no secret is stored.

-- ---------------------------------------------------------------------------------------------------
-- 1. Durable cleanup queue (private schema: never exposed through PostgREST).
-- ---------------------------------------------------------------------------------------------------
create table if not exists private.cv_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  storage_path text not null check (length(storage_path) between 1 and 1024),
  graduate_id uuid,
  reason text not null default 'METADATA_DELETE'
    check (reason in ('METADATA_DELETE','STORAGE_PATH_REPLACED','ACCOUNT_DELETE')),
  status text not null default 'PENDING'
    check (status in ('PENDING','PROCESSING','DONE','FAILED')),
  attempts integer not null default 0 check (attempts between 0 and 100),
  last_error text,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists cv_cleanup_queue_pending_idx
  on private.cv_cleanup_queue (created_at) where status in ('PENDING','FAILED');
alter table private.cv_cleanup_queue enable row level security;
revoke all on private.cv_cleanup_queue from public, anon, authenticated;
grant select, insert, update on private.cv_cleanup_queue to service_role;

create or replace function private.enqueue_cv_cleanup() returns trigger
language plpgsql security definer set search_path = '' as $enqueue_cv_cleanup$
begin
  if tg_op = 'DELETE' then
    insert into private.cv_cleanup_queue (storage_path, graduate_id, reason)
    values (old.storage_path, old.graduate_id, 'METADATA_DELETE');
    return old;
  end if;
  -- A replaced storage_path leaves the previous object behind; delete that one, not the new path.
  if new.storage_path is distinct from old.storage_path then
    insert into private.cv_cleanup_queue (storage_path, graduate_id, reason)
    values (old.storage_path, old.graduate_id, 'STORAGE_PATH_REPLACED');
  end if;
  return new;
end $enqueue_cv_cleanup$;
revoke all on function private.enqueue_cv_cleanup() from public, anon, authenticated;

drop trigger if exists cv_documents_cleanup_queue on public.cv_documents;
create trigger cv_documents_cleanup_queue
  after delete or update of storage_path on public.cv_documents
  for each row execute function private.enqueue_cv_cleanup();

-- ---------------------------------------------------------------------------------------------------
-- 2. The only client write path: owner-scoped metadata deletion, which enqueues object cleanup.
--    A direct DELETE grant is removed so a failure cannot be hidden from the cleanup ledger.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.delete_cv_document(p_cv_document_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $delete_cv_document$
declare v_uid uuid := public._require_uid(); d public.cv_documents;
begin
  if p_cv_document_id is null then raise exception 'INVALID_INPUT' using errcode = 'PT422'; end if;
  select * into d from public.cv_documents
   where id = p_cv_document_id and graduate_id = v_uid for update;
  if not found then raise exception 'CV_NOT_FOUND' using errcode = 'PT404'; end if;
  delete from public.cv_documents where id = d.id;
  return jsonb_build_object('deleted', true, 'cv_document_id', d.id, 'cleanup_queued', true);
end $delete_cv_document$;
revoke all on function public.delete_cv_document(uuid) from public, anon, authenticated;
grant execute on function public.delete_cv_document(uuid) to authenticated;
comment on function public.delete_cv_document(uuid) is
  'Owner-only CV metadata deletion. The private Storage object is cleaned by the service-role worker via private.cv_cleanup_queue.';

revoke delete on public.cv_documents from authenticated;
-- service_role keeps delete for retention tooling and account deletion.

-- ---------------------------------------------------------------------------------------------------
-- 3. Worker operations: claim -> remove object through Storage -> complete/fail. Idempotent and bounded.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.claim_cv_cleanup(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $claim_cv_cleanup$
declare v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100)); v_items jsonb;
begin
  -- Recover worker claims that were abandoned after the worker process terminated.
  update private.cv_cleanup_queue
     set status = 'FAILED',
         last_error = coalesce(last_error, 'WORKER_LEASE_EXPIRED'),
         updated_at = now()
   where status = 'PROCESSING'
     and claimed_at < now() - interval '15 minutes';

  with picked as (
    select id from private.cv_cleanup_queue
     where status in ('PENDING','FAILED') and attempts < 10
     order by created_at
     for update skip locked
     limit v_limit
  ), updated as (
    update private.cv_cleanup_queue q
       set status = 'PROCESSING', attempts = q.attempts + 1, claimed_at = now(), updated_at = now()
      from picked p
     where q.id = p.id
    returning q.id, q.storage_path, q.graduate_id, q.attempts, q.reason
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id, 'storage_path', u.storage_path, 'graduate_id', u.graduate_id,
    'attempts', u.attempts, 'reason', u.reason) order by u.id), '[]'::jsonb)
  into v_items from updated u;
  return v_items;
end $claim_cv_cleanup$;

create or replace function public.complete_cv_cleanup(p_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $complete_cv_cleanup$
declare v_rows integer;
begin
  update private.cv_cleanup_queue
     set status = 'DONE', last_error = null, updated_at = now()
   where id = p_id and status = 'PROCESSING';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end $complete_cv_cleanup$;

create or replace function public.fail_cv_cleanup(p_id uuid, p_error text)
returns boolean language plpgsql security definer set search_path = '' as $fail_cv_cleanup$
declare v_rows integer;
begin
  update private.cv_cleanup_queue
     set status = 'FAILED',
         last_error = left(coalesce(nullif(btrim(p_error), ''), 'UNKNOWN_CLEANUP_ERROR'), 500),
         updated_at = now()
   where id = p_id and status = 'PROCESSING';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end $fail_cv_cleanup$;

create or replace function public.get_cv_cleanup_report()
returns jsonb language plpgsql stable security definer set search_path = '' as $get_cv_cleanup_report$
begin
  return jsonb_build_object(
    'pending', (select count(*) from private.cv_cleanup_queue where status = 'PENDING'),
    'processing', (select count(*) from private.cv_cleanup_queue where status = 'PROCESSING'),
    'failed', (select count(*) from private.cv_cleanup_queue where status = 'FAILED'),
    'done', (select count(*) from private.cv_cleanup_queue where status = 'DONE'),
    'exhausted', (select count(*) from private.cv_cleanup_queue where status = 'FAILED' and attempts >= 10),
    'oldest_pending_at', (select min(created_at) from private.cv_cleanup_queue where status in ('PENDING','FAILED'))
  );
end $get_cv_cleanup_report$;

revoke all on function public.claim_cv_cleanup(integer),
              public.complete_cv_cleanup(uuid),
              public.fail_cv_cleanup(uuid, text),
              public.get_cv_cleanup_report()
  from public, anon, authenticated;
grant execute on function public.claim_cv_cleanup(integer),
  public.complete_cv_cleanup(uuid),
  public.fail_cv_cleanup(uuid, text),
  public.get_cv_cleanup_report()
  to service_role;

comment on table private.cv_cleanup_queue is
  'Durable, retryable cleanup ledger for private CV Storage objects (issue #18). Service-role worker only.';
comment on function public.get_cv_cleanup_report() is
  'Orphan/reconciliation report: bulk cleanup backlog and exhausted attempts.';
