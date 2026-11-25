-- 0023: distinguish a second active invitation from an unrelated registered Auth identity.
-- Auth creates the invited user as soon as the first email is sent, while the invitation stays PENDING
-- until that user confirms. Check the invitation ledger before auth.users so retries return the
-- stable INVITATION_ALREADY_ACTIVE response instead of the misleading EMAIL_ALREADY_REGISTERED.
create or replace function public.create_graduate_invitation(
  p_actor_id uuid,
  p_email text,
  p_full_name text,
  p_verification_note text
)
returns table (invitation_id uuid, status text)
language plpgsql security definer set search_path = ''
as $create_graduate_invitation$
declare
  v_actor uuid := p_actor_id;
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_name text := btrim(coalesce(p_full_name,''));
  v_note text := btrim(coalesce(p_verification_note,''));
  v_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if not private.is_active_platform_admin(v_actor) then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if length(v_name) not between 2 and 200
     or length(v_note) not between 10 and 2000
     or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}$'
     or length(v_email) > 254 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_email, 0));
  if exists (
    select 1 from private.graduate_invitations i
     where i.email = v_email and i.status in ('INVITING','PENDING')
  ) then
    raise exception 'INVITATION_ALREADY_ACTIVE' using errcode = 'PT409';
  end if;
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception 'EMAIL_ALREADY_REGISTERED' using errcode = 'PT409';
  end if;

  insert into private.graduate_invitations(email, full_name, verification_note, invited_by)
  values (v_email, v_name, v_note, v_actor)
  returning id into v_id;

  insert into private.platform_admin_audit(actor_user_id, action, reference_id, details)
  values (v_actor, 'GRADUATE_INVITATION_CREATED', v_id,
          jsonb_build_object('email', v_email, 'verification_note_recorded', true));
  return query select v_id, 'INVITING'::text;
exception
  when unique_violation then
    raise exception 'INVITATION_ALREADY_ACTIVE' using errcode = 'PT409';
end
$create_graduate_invitation$;

notify pgrst, 'reload schema';
