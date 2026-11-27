-- 0035: normalize Supabase Auth's stored phone representation at the profile boundary.
-- GoTrue accepts E.164 input but stores auth.users.phone without the leading '+'. The application
-- and profiles table retain E.164, so restore the prefix here instead of weakening validation.

create or replace function private.normalize_auth_phone(p_phone text)
returns text
language sql immutable
set search_path = ''
as $normalize_auth_phone$
  select case
    when p_phone is null or btrim(p_phone) = '' then null
    when btrim(p_phone) ~ '^\+[1-9][0-9]{7,14}$' then btrim(p_phone)
    when btrim(p_phone) ~ '^[1-9][0-9]{7,14}$' then '+' || btrim(p_phone)
    else btrim(p_phone)
  end
$normalize_auth_phone$;
revoke all on function private.normalize_auth_phone(text) from public, anon, authenticated, service_role;

-- The Auth trigger sees GoTrue's stored representation, not the original API request.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $handle_new_user_v3$
begin
  insert into public.profiles (id, full_name, email, phone, account_status)
  values (new.id,
          coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), 'مستخدم جديد'),
          new.email,
          private.normalize_auth_phone(new.phone),
          case when new.email is null then 'PENDING_VERIFICATION' else 'ACTIVE' end);
  if new.email is not null then
    insert into public.graduate_profiles (profile_id) values (new.id);
  end if;
  return new;
end $handle_new_user_v3$;

-- Keep the fallback path consistent for accounts whose profile predates the normalized trigger.
create or replace function public.finalize_registration()
returns jsonb language plpgsql security definer set search_path = '' as $finalize_registration_v2$
declare
  v_uid uuid := auth.uid();
  v_phone timestamptz;
  v_identity_count integer;
  v_phone_number text;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED' using errcode = 'PT401'; end if;
  select u.phone_confirmed_at, u.phone into v_phone, v_phone_number
    from auth.users u where u.id = v_uid;
  if not found then raise exception 'USER_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_phone is null then raise exception 'PHONE_NOT_VERIFIED' using errcode = 'PT409'; end if;
  select count(*)::int into v_identity_count
    from public.human_identities
   where profile_id = v_uid and status = 'VERIFIED';
  if v_identity_count = 0 then raise exception 'IDENTITY_NOT_VERIFIED' using errcode = 'PT409'; end if;
  update public.profiles
     set phone_verified_at = v_phone,
         phone = coalesce(phone, private.normalize_auth_phone(v_phone_number)),
         account_status = 'ACTIVE'
   where id = v_uid;
  insert into private.identity_audit(profile_id, action, details)
  values (v_uid, 'REGISTRATION_COMPLETED',
          jsonb_build_object('verified_identities', v_identity_count));
  return jsonb_build_object('account_status', 'ACTIVE', 'verified_identities', v_identity_count);
end $finalize_registration_v2$;
revoke all on function public.finalize_registration() from public, anon;
grant execute on function public.finalize_registration() to authenticated;
comment on function public.finalize_registration() is
  'Completes phone-first registration after Supabase Auth phone confirmation and an institutional identity verification.';
