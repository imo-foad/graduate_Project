-- 0030: recoverable registration OTP retries and paced CV cleanup recovery.
--
-- Forward-only product hardening:
--   * a caller may repeat the same registration request only when phone + keyed National-ID digest
--     resolve to the exact same pending account; this supports OTP resend after a delivery/network failure.
--   * CV cleanup failures use durable exponential backoff, expired leases are recovered, and exhausted
--     rows can be explicitly re-queued by the service-role operator.
-- No raw National ID, OTP, Storage bytes or production state is introduced here.

-- ---------------------------------------------------------------------------------------------------
-- 1. Resolve an existing pending registration for an exact phone + National-ID digest pair.
--    This function deliberately reveals only the profile UUID, and only to service_role.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.find_pending_registration_retry(
  p_phone text,
  p_national_id_digest text
) returns uuid
language plpgsql security definer set search_path = ''
as $find_pending_registration_retry$
declare
  v_profile_id uuid;
begin
  if p_phone is null or p_phone !~ '^\\+[1-9][0-9]{7,14}$'
     or p_national_id_digest is null or p_national_id_digest !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select p.id
    into v_profile_id
    from public.profiles p
    join private.identity_verifications v
      on v.profile_id = p.id
     and v.status = 'VERIFIED'
   where p.phone = p_phone
     and p.account_status = 'PENDING_VERIFICATION'
     and v.national_id_digest = p_national_id_digest
   order by v.verified_at desc, v.created_at desc
   limit 1
   for update of p;

  return v_profile_id;
end
$find_pending_registration_retry$;

revoke all on function public.find_pending_registration_retry(text,text)
  from public, anon, authenticated;
grant execute on function public.find_pending_registration_retry(text,text)
  to service_role;

comment on function public.find_pending_registration_retry(text,text) is
  'Service-role-only idempotency lookup for resending signup OTP to the same pending phone/National-ID pair. Returns no data for active or mismatched accounts.';

-- ---------------------------------------------------------------------------------------------------
-- 2. Persist retry scheduling in the CV cleanup ledger. Failures must not be retried in a tight loop.
-- ---------------------------------------------------------------------------------------------------
alter table private.cv_cleanup_queue
  add column if not exists next_attempt_at timestamptz;

update private.cv_cleanup_queue
   set next_attempt_at = created_at
 where next_attempt_at is null
   and status in ('PENDING','FAILED');

create index if not exists cv_cleanup_queue_retry_idx
  on private.cv_cleanup_queue (next_attempt_at, created_at)
  where status in ('PENDING','FAILED');

create or replace function public.claim_cv_cleanup(p_limit integer default 20)
returns jsonb
language plpgsql security definer set search_path = ''
as $claim_cv_cleanup_v2$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
  v_items jsonb;
begin
  -- A crashed worker's lease is converted to a delayed retry. A null lease is also recoverable.
  update private.cv_cleanup_queue
     set status = 'FAILED',
         last_error = coalesce(last_error, 'WORKER_LEASE_EXPIRED'),
         claimed_at = null,
         next_attempt_at = now() + least(
           interval '6 hours',
           interval '30 seconds' * power(2::double precision, greatest(attempts - 1, 0))
         ),
         updated_at = now()
   where status = 'PROCESSING'
     and (claimed_at is null or claimed_at < now() - interval '15 minutes');

  with picked as (
    select id
      from private.cv_cleanup_queue
     where status in ('PENDING','FAILED')
       and attempts < 10
       and coalesce(next_attempt_at, created_at) <= now()
     order by coalesce(next_attempt_at, created_at), created_at, id
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
    returning q.id, q.storage_path, q.graduate_id, q.attempts, q.reason
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id,
    'storage_path', u.storage_path,
    'graduate_id', u.graduate_id,
    'attempts', u.attempts,
    'reason', u.reason
  ) order by u.created_at, u.id), '[]'::jsonb)
    into v_items
    from (
      select q.*, q.created_at
        from updated q
    ) u;

  return v_items;
end
$claim_cv_cleanup_v2$;

create or replace function public.complete_cv_cleanup(p_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $complete_cv_cleanup_v2$
declare
  v_rows integer;
begin
  update private.cv_cleanup_queue
     set status = 'DONE',
         last_error = null,
         claimed_at = null,
         next_attempt_at = null,
         updated_at = now()
   where id = p_id
     and status = 'PROCESSING';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end
$complete_cv_cleanup_v2$;

create or replace function public.fail_cv_cleanup(p_id uuid, p_error text)
returns boolean
language plpgsql security definer set search_path = ''
as $fail_cv_cleanup_v2$
declare
  v_rows integer;
begin
  update private.cv_cleanup_queue
     set status = 'FAILED',
         last_error = left(coalesce(nullif(btrim(p_error), ''), 'UNKNOWN_CLEANUP_ERROR'), 500),
         claimed_at = null,
         next_attempt_at = now() + least(
           interval '6 hours',
           interval '30 seconds' * power(2::double precision, greatest(attempts - 1, 0))
         ),
         updated_at = now()
   where id = p_id
     and status = 'PROCESSING';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end
$fail_cv_cleanup_v2$;

create or replace function public.retry_cv_cleanup(p_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $retry_cv_cleanup$
declare
  v_rows integer;
begin
  update private.cv_cleanup_queue
     set status = 'PENDING',
         attempts = 0,
         last_error = null,
         claimed_at = null,
         next_attempt_at = now(),
         updated_at = now()
   where id = p_id
     and status = 'FAILED';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end
$retry_cv_cleanup$;

create or replace function public.get_cv_cleanup_report()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $get_cv_cleanup_report_v2$
begin
  return jsonb_build_object(
    'pending', (select count(*) from private.cv_cleanup_queue where status = 'PENDING'),
    'processing', (select count(*) from private.cv_cleanup_queue where status = 'PROCESSING'),
    'failed', (select count(*) from private.cv_cleanup_queue where status = 'FAILED'),
    'retry_ready', (select count(*) from private.cv_cleanup_queue
                     where status in ('PENDING','FAILED') and attempts < 10
                       and coalesce(next_attempt_at, created_at) <= now()),
    'retry_scheduled', (select count(*) from private.cv_cleanup_queue
                         where status = 'FAILED' and attempts < 10
                           and next_attempt_at > now()),
    'done', (select count(*) from private.cv_cleanup_queue where status = 'DONE'),
    'exhausted', (select count(*) from private.cv_cleanup_queue
                   where status = 'FAILED' and attempts >= 10),
    'oldest_pending_at', (select min(created_at) from private.cv_cleanup_queue
                           where status in ('PENDING','FAILED'))
  );
end
$get_cv_cleanup_report_v2$;

revoke all on function public.claim_cv_cleanup(integer),
              public.complete_cv_cleanup(uuid),
              public.fail_cv_cleanup(uuid,text),
              public.retry_cv_cleanup(uuid),
              public.get_cv_cleanup_report()
  from public, anon, authenticated;
grant execute on function public.claim_cv_cleanup(integer),
  public.complete_cv_cleanup(uuid),
  public.fail_cv_cleanup(uuid,text),
  public.retry_cv_cleanup(uuid),
  public.get_cv_cleanup_report()
  to service_role;

comment on function public.retry_cv_cleanup(uuid) is
  'Service-role operator action to re-queue a failed CV Storage cleanup item; safe to repeat only after a FAILED result.';
