-- 0040: immutable CV Storage object paths (issue #18).
--
-- A storage path becomes permanently retired as soon as it is inserted into the durable cleanup
-- ledger. The path is never re-registered, irrespective of PENDING/PROCESSING/FAILED/DONE status.
-- Transaction-scoped advisory locks serialize CV metadata writes/deletes with queue insertion.
-- Storage bytes remain exclusively managed by the Storage API worker; this migration never writes
-- to storage.objects and does not expose the private queue or worker functions to clients.

-- Fail closed if an earlier deployment already contains a live metadata/retired-path overlap.
-- Such data must be reconciled explicitly; silently deleting a tombstone would make the race possible.
do $cv_storage_path_preflight$
begin
  if exists (
    select 1
      from public.cv_documents d
      join private.cv_cleanup_queue q on q.storage_path = d.storage_path
  ) then
    raise exception using
      errcode = '23514',
      message = 'CV_STORAGE_PATH_RETIRED_EXISTING_METADATA_CONFLICT';
  end if;
end
$cv_storage_path_preflight$;

-- Use one stable 64-bit advisory-lock key per exact path. Hash collisions only serialize unrelated
-- paths; they cannot bypass the subsequent equality check against the cleanup queue.
create or replace function private.lock_cv_storage_paths(p_paths text[])
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $lock_cv_storage_paths$
declare
  v_lock_key bigint;
begin
  for v_lock_key in
    select distinct pg_catalog.hashtextextended(path_value, 18082026::bigint)
      from pg_catalog.unnest(coalesce(p_paths, array[]::text[])) as paths(path_value)
     where path_value is not null
     order by 1
  loop
    perform pg_catalog.pg_advisory_xact_lock(v_lock_key);
  end loop;
end
$lock_cv_storage_paths$;

revoke all on function private.lock_cv_storage_paths(text[])
  from public, anon, authenticated;

-- Registration is checked AFTER acquiring the same transaction lock used by the queue trigger.
-- The queue lookup intentionally has no status predicate: DONE is a permanent tombstone.
create or replace function private.guard_cv_document_storage_path()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $guard_cv_document_storage_path$
begin
  if tg_op = 'INSERT' then
    perform private.lock_cv_storage_paths(array[new.storage_path]);

    if exists (
      select 1
        from private.cv_cleanup_queue q
       where q.storage_path = new.storage_path
    ) then
      raise exception using
        errcode = '23514',
        message = 'CV_STORAGE_PATH_RETIRED';
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.storage_path is distinct from new.storage_path then
      -- Lock both keys in deterministic advisory-key order to avoid deadlocks when paths are swapped.
      perform private.lock_cv_storage_paths(array[old.storage_path, new.storage_path]);

      if exists (
        select 1
          from private.cv_cleanup_queue q
         where q.storage_path = new.storage_path
      ) then
        raise exception using
          errcode = '23514',
          message = 'CV_STORAGE_PATH_RETIRED';
      end if;
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    perform private.lock_cv_storage_paths(array[old.storage_path]);
    return old;
  end if;

  raise exception using errcode = '0A000', message = 'UNSUPPORTED_CV_STORAGE_PATH_TRIGGER_OPERATION';
end
$guard_cv_document_storage_path$;

revoke all on function private.guard_cv_document_storage_path()
  from public, anon, authenticated;

drop trigger if exists cv_documents_cancel_stale_cleanup on public.cv_documents;
drop function if exists private.cancel_cv_cleanup_for_live_path();

drop trigger if exists cv_documents_storage_path_guard_insert on public.cv_documents;
create trigger cv_documents_storage_path_guard_insert
  before insert on public.cv_documents
  for each row execute function private.guard_cv_document_storage_path();

drop trigger if exists cv_documents_storage_path_guard_update on public.cv_documents;
create trigger cv_documents_storage_path_guard_update
  before update of storage_path on public.cv_documents
  for each row execute function private.guard_cv_document_storage_path();

drop trigger if exists cv_documents_storage_path_guard_delete on public.cv_documents;
create trigger cv_documents_storage_path_guard_delete
  before delete on public.cv_documents
  for each row execute function private.guard_cv_document_storage_path();

-- All cleanup-queue insertion paths participate in the same lock protocol. This includes the existing
-- AFTER DELETE/UPDATE trigger from 0027, which runs before the metadata transaction releases its lock.
-- An attempted queue insertion while live metadata still points at the path is rejected.
-- Duplicate queue insertion is a no-op: one path has one permanent ledger entry.
create or replace function private.guard_cv_cleanup_queue_insert()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $guard_cv_cleanup_queue_insert$
begin
  perform private.lock_cv_storage_paths(array[new.storage_path]);

  if exists (
    select 1
      from public.cv_documents d
     where d.storage_path = new.storage_path
  ) then
    raise exception using
      errcode = '23514',
      message = 'CV_STORAGE_PATH_LIVE';
  end if;

  if exists (
    select 1
      from private.cv_cleanup_queue q
     where q.storage_path = new.storage_path
  ) then
    return null;
  end if;

  return new;
end
$guard_cv_cleanup_queue_insert$;

revoke all on function private.guard_cv_cleanup_queue_insert()
  from public, anon, authenticated;

drop trigger if exists cv_cleanup_queue_storage_path_guard_insert on private.cv_cleanup_queue;
create trigger cv_cleanup_queue_storage_path_guard_insert
  before insert on private.cv_cleanup_queue
  for each row execute function private.guard_cv_cleanup_queue_insert();

-- The queue's storage_path is the permanent tombstone key. Status, lease and retry fields may change;
-- changing the path would erase the original tombstone and is therefore forbidden.
create or replace function private.guard_cv_cleanup_queue_path_immutable()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $guard_cv_cleanup_queue_path_immutable$
begin
  if new.storage_path is distinct from old.storage_path then
    raise exception using
      errcode = '23514',
      message = 'CV_CLEANUP_STORAGE_PATH_IMMUTABLE';
  end if;
  return new;
end
$guard_cv_cleanup_queue_path_immutable$;

revoke all on function private.guard_cv_cleanup_queue_path_immutable()
  from public, anon, authenticated;

drop trigger if exists cv_cleanup_queue_storage_path_immutable on private.cv_cleanup_queue;
create trigger cv_cleanup_queue_storage_path_immutable
  before update of storage_path on private.cv_cleanup_queue
  for each row execute function private.guard_cv_cleanup_queue_path_immutable();

comment on function private.lock_cv_storage_paths(text[]) is
  'Transaction-scoped advisory lock protocol shared by CV metadata registration/deletion/replacement and cleanup-queue insertion.';
comment on function private.guard_cv_document_storage_path() is
  'Rejects any CV storage_path that already has a cleanup-queue tombstone, regardless of queue status.';
comment on function private.guard_cv_cleanup_queue_insert() is
  'Serializes cleanup-queue insertion against metadata writes and refuses to enqueue a currently live storage path.';
comment on function private.guard_cv_cleanup_queue_path_immutable() is
  'Prevents changing the path of a cleanup record; its storage_path is a permanent tombstone.';

comment on trigger cv_documents_storage_path_guard_insert on public.cv_documents is
  'A CV path that ever entered private.cv_cleanup_queue can never be registered again.';
comment on trigger cv_documents_storage_path_guard_update on public.cv_documents is
  'Path replacement locks old/new paths in deterministic order and rejects a retired new path.';
comment on trigger cv_documents_storage_path_guard_delete on public.cv_documents is
  'Metadata deletion locks the old Storage path through the subsequent cleanup-queue insert and commit.';
