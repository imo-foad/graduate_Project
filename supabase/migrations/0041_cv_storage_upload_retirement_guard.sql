-- 0041: CV Storage upload retirement guard (issue #18).
--
-- Prevent authenticated uploads to retired CV Storage paths.
-- Any cleanup-queue row is a permanent tombstone, regardless of its status.
-- Use the same transaction-scoped advisory-lock protocol as migration 0040.

create or replace function private.check_cv_upload_allowed(p_path text)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $check_cv_upload_allowed$
declare
  v_uid uuid := auth.uid();
  v_folder text;
begin
  -- Reject requests without an authenticated user.
  if v_uid is null then return false; end if;

  -- Extract the first path segment (the user's folder).
  v_folder := split_part(p_path, '/', 1);

  -- Only allow uploads under the authenticated user's own folder.
  if v_folder is null or v_folder = '' or v_folder != v_uid::text then return false; end if;

  -- Acquire the same path lock used by metadata and cleanup-queue mutations.
  perform private.lock_cv_storage_paths(array[p_path]);

  -- A cleanup-queue row in any state is a permanent tombstone.
  if exists (
    select 1
      from private.cv_cleanup_queue q
     where q.storage_path = p_path
  ) then
    return false;
  end if;

  return true;
end
$check_cv_upload_allowed$;

revoke all on function private.check_cv_upload_allowed(text)
  from public, anon, authenticated;

-- RLS evaluates this predicate as the invoking role; authenticated must be able
-- to execute the SECURITY DEFINER helper used by its Storage INSERT policy.
grant execute on function private.check_cv_upload_allowed(text) to authenticated;

comment on function private.check_cv_upload_allowed(text) is
  'Checks that a CV upload path belongs to the authenticated user and has no retired cleanup tombstone.';

-- Replace the existing CV Storage INSERT policy with the retirement-aware predicate.
drop policy if exists cv_objects_insert on storage.objects;

create policy cv_objects_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'cv-documents'
    and private.check_cv_upload_allowed(name)
  );

comment on policy cv_objects_insert on storage.objects is
  'Allows authenticated users to upload CVs only under their own folder and only to paths that are not retired tombstones.';
