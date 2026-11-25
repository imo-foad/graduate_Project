-- 0021: real scholarship delivery outbox, provider callbacks and scoped reviewer lifecycle.
-- Applications are never represented as externally submitted until a provider acknowledges them.

alter table public.scholarship_applications
  add column delivery_status text not null default 'NOT_REQUIRED'
    check (delivery_status in ('NOT_REQUIRED','BLOCKED','PENDING','PROCESSING','DELIVERED','FAILED','CANCELLED')),
  add column provider_key text,
  add column provider_application_reference text,
  add column externally_submitted_at timestamptz,
  add column reviewed_at timestamptz,
  add column reviewed_by uuid references auth.users(id) on delete set null,
  add column review_note text;

alter table public.scholarship_applications
  drop constraint if exists scholarship_applications_status_check;
alter table public.scholarship_applications
  add constraint scholarship_applications_status_check
  check (status in (
    'SUBMITTED','UNDER_REVIEW','PENDING_DELIVERY','SUBMITTED_EXTERNALLY','IN_REVIEW',
    'ACCEPTED','REJECTED','DELIVERY_FAILED','INTERNAL_ONLY','WITHDRAWN'
  )) not valid;

alter table public.scholarship_application_status_history
  drop constraint if exists scholarship_application_status_history_new_status_check;
alter table public.scholarship_application_status_history
  add constraint scholarship_application_status_history_new_status_check
  check (new_status in (
    'SUBMITTED','UNDER_REVIEW','PENDING_DELIVERY','SUBMITTED_EXTERNALLY','IN_REVIEW',
    'ACCEPTED','REJECTED','DELIVERY_FAILED','INTERNAL_ONLY','WITHDRAWN'
  ));
alter table public.scholarship_application_status_history
  drop constraint if exists scholarship_application_status_history_source_type_check;
alter table public.scholarship_application_status_history
  add constraint scholarship_application_status_history_source_type_check
  check (source_type in ('GRADUATE_ACTION','ADMIN_ACTION','SYSTEM','PROVIDER','REVIEWER','ADMIN'));

create unique index scholarship_application_provider_reference_uidx
  on public.scholarship_applications(provider_key, provider_application_reference)
  where provider_key is not null and provider_application_reference is not null;

-- Provider endpoints and credentials are NOT stored in the database. The provider key maps
-- to secrets held only in the Edge Function environment (SCHOLARSHIP_PROVIDERS_JSON).
create table private.scholarship_provider_mappings (
  opportunity_id uuid primary key references public.opportunities(id) on delete restrict,
  provider_key text not null check (provider_key ~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'),
  external_opportunity_id text not null check (
    length(btrim(external_opportunity_id)) between 1 and 200
  ),
  is_enabled boolean not null default true,
  configured_by uuid references auth.users(id) on delete set null,
  configured_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index scholarship_provider_mapping_key_idx
  on private.scholarship_provider_mappings(provider_key, is_enabled);

create table private.scholarship_reviewers (
  user_id uuid not null references auth.users(id) on delete cascade,
  provider_key text not null check (provider_key ~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'),
  is_active boolean not null default true,
  granted_by uuid references auth.users(id) on delete set null,
  granted_at timestamptz not null default now(),
  primary key (user_id, provider_key)
);
create index scholarship_reviewers_active_idx
  on private.scholarship_reviewers(provider_key, is_active, user_id);

create table private.scholarship_delivery_outbox (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null unique references public.scholarship_applications(id) on delete cascade,
  provider_key text,
  external_opportunity_id text,
  status text not null check (status in ('BLOCKED','PENDING','PROCESSING','DELIVERED','FAILED','CANCELLED')),
  attempts integer not null default 0 check (attempts between 0 and 100),
  delivery_generation integer not null default 1 check (delivery_generation between 1 and 1000),
  max_attempts integer not null default 5 check (max_attempts between 1 and 10),
  next_attempt_at timestamptz not null default now(),
  last_attempt_started_at timestamptz,
  lease_expires_at timestamptz,
  last_error_code text check (last_error_code is null or last_error_code ~ '^[A-Z0-9_]{1,64}$'),
  provider_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  delivered_at timestamptz,
  check (
    (status = 'PROCESSING' and lease_expires_at is not null)
    or (status <> 'PROCESSING' and lease_expires_at is null)
  )
);
create index scholarship_delivery_due_idx
  on private.scholarship_delivery_outbox(status, next_attempt_at, created_at);
create index scholarship_delivery_provider_idx
  on private.scholarship_delivery_outbox(provider_key, status, created_at);

create table private.scholarship_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid not null references private.scholarship_delivery_outbox(id) on delete cascade,
  attempt_number integer not null check (attempt_number between 1 and 100),
  delivery_generation integer not null default 1 check (delivery_generation between 1 and 1000),
  started_at timestamptz not null,
  finished_at timestamptz not null default now(),
  outcome text not null check (outcome in ('DELIVERED','RETRY_SCHEDULED','FAILED','BLOCKED')),
  http_status integer check (http_status is null or http_status between 100 and 599),
  error_code text check (error_code is null or error_code ~ '^[A-Z0-9_]{1,64}$'),
  provider_reference text,
  unique (outbox_id, delivery_generation, attempt_number)
);
create index scholarship_delivery_attempts_recent_idx
  on private.scholarship_delivery_attempts(outbox_id, delivery_generation desc, attempt_number desc);

create table private.scholarship_provider_events (
  id uuid primary key default gen_random_uuid(),
  provider_key text not null check (provider_key ~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'),
  event_id text not null check (length(btrim(event_id)) between 1 and 200),
  application_id uuid not null references public.scholarship_applications(id) on delete cascade,
  received_status text not null check (received_status in ('IN_REVIEW','ACCEPTED','REJECTED')),
  payload_digest text not null check (payload_digest ~ '^[a-f0-9]{64}$'),
  received_at timestamptz not null default now(),
  unique (provider_key, event_id)
);
create index scholarship_provider_events_app_idx
  on private.scholarship_provider_events(application_id, received_at desc);

alter table private.scholarship_provider_mappings enable row level security;
alter table private.scholarship_reviewers enable row level security;
alter table private.scholarship_delivery_outbox enable row level security;
alter table private.scholarship_delivery_attempts enable row level security;
alter table private.scholarship_provider_events enable row level security;
revoke all on private.scholarship_provider_mappings, private.scholarship_reviewers,
  private.scholarship_delivery_outbox, private.scholarship_delivery_attempts,
  private.scholarship_provider_events from public, anon, authenticated;
grant select, insert, update, delete on private.scholarship_provider_mappings,
  private.scholarship_reviewers, private.scholarship_delivery_outbox,
  private.scholarship_delivery_attempts, private.scholarship_provider_events to service_role;

-- Preserve the original Alumni Connect review flow unless a provider mapping is explicit.
update public.scholarship_applications a
   set status = case when m.opportunity_id is null then 'SUBMITTED' else 'PENDING_DELIVERY' end,
       delivery_status = case when m.opportunity_id is null then 'NOT_REQUIRED'
         when m.is_enabled then 'PENDING' else 'BLOCKED' end,
       provider_key = m.provider_key
  from public.opportunities o
  left join private.scholarship_provider_mappings m on m.opportunity_id = o.id
 where o.id = a.opportunity_id and a.status = 'SUBMITTED';

update public.scholarship_application_status_history h
   set new_status = case when m.opportunity_id is null then 'SUBMITTED' else 'PENDING_DELIVERY' end
  from public.scholarship_applications a
  join public.opportunities o on o.id = a.opportunity_id
  left join private.scholarship_provider_mappings m on m.opportunity_id = o.id
 where h.scholarship_application_id = a.id and h.new_status = 'SUBMITTED';
update public.scholarship_application_status_history h
   set old_status = case when m.opportunity_id is null then 'SUBMITTED' else 'PENDING_DELIVERY' end
  from public.scholarship_applications a
  join public.opportunities o on o.id = a.opportunity_id
  left join private.scholarship_provider_mappings m on m.opportunity_id = o.id
 where h.scholarship_application_id = a.id and h.old_status = 'SUBMITTED';

insert into private.scholarship_delivery_outbox(
  application_id, provider_key, external_opportunity_id, status, last_error_code
)
select a.id, m.provider_key, m.external_opportunity_id,
       case when m.is_enabled then 'PENDING' else 'BLOCKED' end,
       case when m.is_enabled then null else 'PROVIDER_MAPPING_DISABLED' end
  from public.scholarship_applications a
  join public.opportunities o on o.id = a.opportunity_id
  join private.scholarship_provider_mappings m on m.opportunity_id = a.opportunity_id
 where not o.is_sample and a.status = 'PENDING_DELIVERY';

update public.scholarship_applications a
   set provider_key = m.provider_key,
       delivery_status = case when m.is_enabled then 'PENDING' else 'BLOCKED' end
  from private.scholarship_provider_mappings m
 where m.opportunity_id = a.opportunity_id and a.status = 'PENDING_DELIVERY';

create or replace function private.is_active_scholarship_reviewer(
  p_user_id uuid,
  p_provider_key text
)
returns boolean
language sql stable security definer set search_path = ''
as $is_active_scholarship_reviewer$
  select p_user_id is not null
    and p_provider_key is not null
    and exists (
      select 1 from private.scholarship_reviewers r
      join public.profiles p on p.id = r.user_id
      where r.user_id = p_user_id
        and r.provider_key = p_provider_key
        and r.is_active
        and p.account_status = 'ACTIVE'
    );
$is_active_scholarship_reviewer$;
revoke all on function private.is_active_scholarship_reviewer(uuid, text) from public, anon, authenticated;
grant execute on function private.is_active_scholarship_reviewer(uuid, text) to service_role;

create or replace function private.is_active_scholarship_admin(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $is_active_scholarship_admin$
  select p_user_id is not null and exists (
    select 1
      from private.platform_admins a
      join public.profiles p on p.id = a.user_id
      join auth.users u on u.id = a.user_id
     where a.user_id = p_user_id
       and a.is_active
       and p.account_status = 'ACTIVE'
       and u.email_confirmed_at is not null
  );
$is_active_scholarship_admin$;
revoke all on function private.is_active_scholarship_admin(uuid) from public, anon, authenticated;
grant execute on function private.is_active_scholarship_admin(uuid) to service_role;

create or replace function public.configure_scholarship_provider_mapping(
  p_opportunity_id uuid, p_provider_key text, p_external_opportunity_id text,
  p_is_enabled boolean default true
)
returns boolean language plpgsql security definer set search_path = ''
as $configure_scholarship_provider_mapping$
declare v_actor uuid := public._require_uid();
begin
  if not private.is_platform_admin() then raise exception 'ADMIN_REQUIRED' using errcode = 'PT403'; end if;
  if p_opportunity_id is null or p_provider_key is null
     or p_provider_key !~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'
     or p_external_opportunity_id is null
     or length(btrim(p_external_opportunity_id)) not between 1 and 200
     or p_is_enabled is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (select 1 from public.opportunities
    where id=p_opportunity_id and type='SCHOLARSHIP' and not is_sample) then
    raise exception 'SCHOLARSHIP_PROVIDER_MAPPING_NOT_ALLOWED' using errcode = 'PT422';
  end if;

  insert into private.scholarship_provider_mappings(
    opportunity_id,provider_key,external_opportunity_id,is_enabled,configured_by,configured_at,updated_at
  ) values (
    p_opportunity_id,p_provider_key,btrim(p_external_opportunity_id),p_is_enabled,v_actor,now(),now()
  )
  on conflict (opportunity_id) do update
    set provider_key=excluded.provider_key,
        external_opportunity_id=excluded.external_opportunity_id,
        is_enabled=excluded.is_enabled,
        configured_by=excluded.configured_by,
        updated_at=now();

  insert into public.scholarship_application_status_history(
    scholarship_application_id,old_status,new_status,source_type,actor_user_id,note
  )
  select a.id,'SUBMITTED','PENDING_DELIVERY','SYSTEM',v_actor,
         'A platform administrator configured an external provider for this Scholarship.'
    from public.scholarship_applications a
   where a.opportunity_id=p_opportunity_id and a.status='SUBMITTED';

  update public.scholarship_applications
     set status='PENDING_DELIVERY',provider_key=p_provider_key,
         delivery_status=case when p_is_enabled then 'PENDING' else 'BLOCKED' end
   where opportunity_id=p_opportunity_id and status='SUBMITTED';

  insert into private.scholarship_delivery_outbox(
    application_id,provider_key,external_opportunity_id,status,last_error_code
  )
  select a.id,p_provider_key,btrim(p_external_opportunity_id),
         case when p_is_enabled then 'PENDING' else 'BLOCKED' end,
         case when p_is_enabled then null else 'PROVIDER_MAPPING_DISABLED' end
    from public.scholarship_applications a
   where a.opportunity_id=p_opportunity_id and a.status='PENDING_DELIVERY'
     and not exists(select 1 from private.scholarship_delivery_outbox o where o.application_id=a.id)
  on conflict (application_id) do nothing;

  if p_is_enabled then
    update private.scholarship_delivery_outbox o
       set provider_key=p_provider_key,external_opportunity_id=btrim(p_external_opportunity_id),
           status='PENDING',attempts=0,delivery_generation=delivery_generation+1,
           next_attempt_at=now(),lease_expires_at=null,last_error_code=null,updated_at=now()
      from public.scholarship_applications a
     where o.application_id=a.id and a.opportunity_id=p_opportunity_id
       and o.status in ('BLOCKED','FAILED')
       and a.status in ('PENDING_DELIVERY','DELIVERY_FAILED');
    update public.scholarship_applications
       set status='PENDING_DELIVERY',provider_key=p_provider_key,delivery_status='PENDING'
     where opportunity_id=p_opportunity_id and status in ('PENDING_DELIVERY','DELIVERY_FAILED');
  else
    update private.scholarship_delivery_outbox o
       set status='BLOCKED',lease_expires_at=null,
           last_error_code='PROVIDER_MAPPING_DISABLED',updated_at=now()
      from public.scholarship_applications a
     where o.application_id=a.id and a.opportunity_id=p_opportunity_id and o.status='PENDING';
    update public.scholarship_applications a set delivery_status='BLOCKED'
     where a.opportunity_id=p_opportunity_id and a.status='PENDING_DELIVERY'
       and exists(select 1 from private.scholarship_delivery_outbox o
                   where o.application_id=a.id and o.status='BLOCKED');
  end if;
  return true;
end
$configure_scholarship_provider_mapping$;

create or replace function public.set_scholarship_reviewer(
  p_user_id uuid,
  p_provider_key text,
  p_is_active boolean
)
returns boolean
language plpgsql security definer set search_path = ''
as $set_scholarship_reviewer$
declare v_actor uuid := public._require_uid();
begin
  if not private.is_active_scholarship_admin(v_actor) then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_user_id is null or p_provider_key is null
     or p_provider_key !~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'
     or p_is_active is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (
    select 1 from public.profiles p
    join auth.users u on u.id = p.id
    where p.id = p_user_id and p.account_status = 'ACTIVE'
      and u.email_confirmed_at is not null
  ) then
    raise exception 'REVIEWER_NOT_ACTIVE' using errcode = 'PT422';
  end if;
  if not exists (
    select 1 from private.scholarship_provider_mappings m
    where m.provider_key = p_provider_key and m.is_enabled
  ) then
    raise exception 'SCHOLARSHIP_PROVIDER_NOT_CONFIGURED' using errcode = 'PT422';
  end if;
  insert into private.scholarship_reviewers(user_id, provider_key, is_active, granted_by, granted_at)
  values (p_user_id, p_provider_key, p_is_active, v_actor, now())
  on conflict (user_id, provider_key) do update
    set is_active = excluded.is_active, granted_by = excluded.granted_by, granted_at = now();
  return true;
end
$set_scholarship_reviewer$;

create or replace function public.get_scholarship_review_queue(
  p_provider_key text default null,
  p_status text default null,
  p_limit integer default 50
)
returns table (
  application_id uuid,
  opportunity_id uuid,
  opportunity_title text,
  provider_key text,
  graduate_id uuid,
  graduate_name text,
  graduate_email text,
  cv_document_id uuid,
  personal_statement text,
  application_data jsonb,
  status text,
  delivery_status text,
  provider_application_reference text,
  applied_at timestamptz,
  externally_submitted_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $get_scholarship_review_queue$
declare
  v_uid uuid := public._require_uid();
  v_is_admin boolean := private.is_active_scholarship_admin(v_uid);
begin
  if not v_is_admin and (
    p_provider_key is null
    or not private.is_active_scholarship_reviewer(v_uid, p_provider_key)
  ) then
    raise exception 'SCHOLARSHIP_REVIEWER_REQUIRED' using errcode = 'PT403';
  end if;
  if p_provider_key is not null and p_provider_key !~ '^[A-Z0-9][A-Z0-9_-]{1,63}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if p_status is not null and p_status not in (
    'PENDING_DELIVERY','SUBMITTED_EXTERNALLY','IN_REVIEW','ACCEPTED','REJECTED','DELIVERY_FAILED'
  ) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  return query
  select a.id, a.opportunity_id, o.title, a.provider_key,
         a.graduate_id, p.full_name, p.email, a.cv_document_id,
         a.personal_statement, a.application_data, a.status, a.delivery_status,
         a.provider_application_reference, a.applied_at, a.externally_submitted_at
    from public.scholarship_applications a
    join public.opportunities o on o.id = a.opportunity_id
    join public.profiles p on p.id = a.graduate_id and p.account_status = 'ACTIVE'
   where (p_provider_key is null or a.provider_key = p_provider_key)
     and (p_status is null or a.status = p_status)
     and (v_is_admin or private.is_active_scholarship_reviewer(v_uid, a.provider_key))
   order by a.applied_at asc, a.id asc
   limit p_limit;
end
$get_scholarship_review_queue$;

create or replace function public.review_scholarship_application(
  p_application_id uuid, p_status text, p_note text default null
)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $review_scholarship_application$
declare
  v_uid uuid := public._require_uid();
  v_app public.scholarship_applications;
  v_title text;
  v_is_sample boolean;
  v_is_admin boolean;
  v_source_type text;
  v_old_status text;
  v_message text;
  v_notification_type text;
begin
  if p_application_id is null or p_status is null
     or p_status not in ('UNDER_REVIEW','IN_REVIEW','ACCEPTED','REJECTED')
     or (p_note is not null and length(p_note)>2000) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_app from public.scholarship_applications where id=p_application_id for update;
  if not found then raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  select title,is_sample into v_title,v_is_sample from public.opportunities where id=v_app.opportunity_id;
  if v_is_sample then raise exception 'SAMPLE_DATA_NOT_REVIEWABLE' using errcode = 'PT422'; end if;
  v_is_admin := private.is_active_scholarship_admin(v_uid);

  if v_app.status in ('SUBMITTED','UNDER_REVIEW') then
    if not v_is_admin then raise exception 'ADMIN_REQUIRED' using errcode = 'PT403'; end if;
    if p_note is not null and length(p_note)>1000 then raise exception 'INVALID_INPUT' using errcode = 'PT422'; end if;
    if not ((v_app.status='SUBMITTED' and p_status='UNDER_REVIEW')
         or (v_app.status='UNDER_REVIEW' and p_status in ('ACCEPTED','REJECTED'))) then
      raise exception 'INVALID_STATUS_TRANSITION' using errcode = 'PT422';
    end if;
    v_old_status:=v_app.status;
    v_source_type:='ADMIN_ACTION';
    v_notification_type:='SCHOLARSHIP_APPLICATION_STATUS_UPDATED';
    v_message:=case p_status
      when 'UNDER_REVIEW' then 'بدأت مراجعة طلبك على «'||v_title||'».'
      when 'ACCEPTED' then 'تم قبول طلبك على «'||v_title||'».'
      else 'تم رفض طلبك على «'||v_title||'».' end;
  elsif v_app.status in ('SUBMITTED_EXTERNALLY','IN_REVIEW') then
    if not v_is_admin and not private.is_active_scholarship_reviewer(v_uid,v_app.provider_key) then
      raise exception 'SCHOLARSHIP_REVIEWER_REQUIRED' using errcode = 'PT403';
    end if;
    if p_note is null or length(btrim(p_note)) not between 3 and 2000 then
      raise exception 'INVALID_INPUT' using errcode = 'PT422';
    end if;
    if not ((v_app.status='SUBMITTED_EXTERNALLY' and p_status='IN_REVIEW')
         or (v_app.status='IN_REVIEW' and p_status in ('ACCEPTED','REJECTED'))) then
      raise exception 'INVALID_SCHOLARSHIP_STATUS_TRANSITION' using errcode = 'PT409';
    end if;
    v_old_status:=v_app.status;
    v_source_type:=case when v_is_admin then 'ADMIN' else 'REVIEWER' end;
    v_notification_type:='SCHOLARSHIP_APPLICATION_'||p_status;
    v_message:=case p_status
      when 'IN_REVIEW' then 'بدأت الجهة مراجعة طلبك على «'||v_title||'».'
      when 'ACCEPTED' then 'تم قبول طلبك على «'||v_title||'».'
      else 'تم رفض طلبك على «'||v_title||'». راجع الملاحظة المرفقة مع الطلب.' end;
  else
    raise exception 'INVALID_STATUS_TRANSITION' using errcode = 'PT422';
  end if;

  update public.scholarship_applications
     set status=p_status,
         reviewed_at=case when p_status in ('ACCEPTED','REJECTED') then now() else reviewed_at end,
         reviewed_by=v_uid,
         review_note=nullif(btrim(coalesce(p_note,'')),'')
   where id=v_app.id returning * into v_app;
  insert into public.scholarship_application_status_history(
    scholarship_application_id,old_status,new_status,source_type,actor_user_id,note
  ) values(v_app.id,v_old_status,p_status,v_source_type,v_uid,nullif(btrim(coalesce(p_note,'')),''));
  insert into public.notifications(profile_id,title,body,type,related_entity_id)
  values(v_app.graduate_id,
    case p_status when 'UNDER_REVIEW' then 'تحديث حالة طلب المنحة'
      when 'IN_REVIEW' then 'طلب المنحة قيد المراجعة'
      when 'ACCEPTED' then 'تم قبول طلب المنحة' else 'تم رفض طلب المنحة' end,
    v_message,v_notification_type,v_app.id);
  return v_app;
end
$review_scholarship_application$;

create or replace function public.retry_scholarship_delivery(p_application_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $retry_scholarship_delivery$
declare
  v_uid uuid := public._require_uid();
  v_app public.scholarship_applications;
  v_outbox private.scholarship_delivery_outbox;
  v_mapping private.scholarship_provider_mappings;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_application_id is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_app from public.scholarship_applications
   where id = p_application_id for update;
  if not found then raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_app.status not in ('PENDING_DELIVERY','DELIVERY_FAILED') then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_RETRYABLE' using errcode = 'PT409';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where application_id = v_app.id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status = 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_IN_PROGRESS' using errcode = 'PT409';
  end if;
  select * into v_mapping from private.scholarship_provider_mappings
   where opportunity_id = v_app.opportunity_id and is_enabled;
  if not found then raise exception 'SCHOLARSHIP_PROVIDER_NOT_CONFIGURED' using errcode = 'PT409'; end if;

  update private.scholarship_delivery_outbox
     set provider_key = v_mapping.provider_key,
         external_opportunity_id = v_mapping.external_opportunity_id,
         status = 'PENDING', attempts = 0, delivery_generation = delivery_generation + 1, next_attempt_at = now(),
         lease_expires_at = null, last_error_code = null, updated_at = now()
   where id = v_outbox.id;
  update public.scholarship_applications
     set status = 'PENDING_DELIVERY', delivery_status = 'PENDING',
         provider_key = v_mapping.provider_key,
         provider_application_reference = null,
         externally_submitted_at = null
   where id = v_app.id;
  if v_app.status = 'DELIVERY_FAILED' then
    insert into public.scholarship_application_status_history(
      scholarship_application_id, old_status, new_status, source_type, actor_user_id, note
    ) values (
      v_app.id, 'DELIVERY_FAILED', 'PENDING_DELIVERY', 'ADMIN', v_uid,
      'Administrator queued a new delivery attempt.'
    );
  end if;
  return true;
end
$retry_scholarship_delivery$;

create or replace function public.claim_scholarship_delivery(
  p_application_id uuid default null,
  p_limit integer default 10
)
returns table (
  outbox_id uuid,
  application_id uuid,
  provider_key text,
  external_opportunity_id text,
  attempt_number integer,
  idempotency_key text,
  request_payload jsonb,
  cv_storage_path text
)
language plpgsql security definer set search_path = ''
as $claim_scholarship_delivery$
declare
  v_item record;
  v_started_at timestamptz;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 50 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  for v_item in
    select a.id as application_id, o.id as outbox_id
      from public.scholarship_applications a
      join private.scholarship_delivery_outbox o on o.application_id = a.id
     where (p_application_id is null or a.id = p_application_id)
       and a.status = 'PENDING_DELIVERY'
       and (
         (o.status = 'PENDING' and o.next_attempt_at <= now())
         or (o.status = 'PROCESSING' and o.lease_expires_at < now())
       )
       and o.attempts < o.max_attempts
     order by o.next_attempt_at asc, o.created_at asc
     for update of a, o skip locked
     limit p_limit
  loop
    v_started_at := now();
    update private.scholarship_delivery_outbox
       set status = 'PROCESSING',
           attempts = attempts + 1,
           lease_expires_at = v_started_at + interval '2 minutes',
           updated_at = v_started_at
     where id = v_item.outbox_id;

    update public.scholarship_applications
       set delivery_status = 'PROCESSING'
     where id = v_item.application_id;

    return query
    select o.id, a.id, o.provider_key, o.external_opportunity_id, o.attempts,
           o.id::text,
           jsonb_build_object(
             'schema_version', '1.0',
             'event', 'scholarship.application.submitted',
             'application_id', a.id,
             'graduate_id', a.graduate_id,
             'cv_document_id', a.cv_document_id,
             'provider_opportunity_id', o.external_opportunity_id,
             'submitted_at', a.applied_at,
             'applicant', jsonb_build_object('full_name', p.full_name, 'email', p.email),
             'personal_statement', a.personal_statement,
             'answers', a.application_data
           ),
           cv.storage_path
      from private.scholarship_delivery_outbox o
      join public.scholarship_applications a on a.id = o.application_id
      join public.profiles p on p.id = a.graduate_id
      left join public.cv_documents cv on cv.id = a.cv_document_id and cv.graduate_id = a.graduate_id
     where o.id = v_item.outbox_id;
  end loop;
end
$claim_scholarship_delivery$;

create or replace function public.block_scholarship_delivery(
  p_outbox_id uuid,
  p_error_code text
)
returns boolean
language plpgsql security definer set search_path = ''
as $block_scholarship_delivery$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_rows integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null or p_error_code is null
     or p_error_code !~ '^[A-Z0-9_]{1,64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status <> 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;
  update private.scholarship_delivery_outbox
     set status = 'BLOCKED', lease_expires_at = null,
         last_error_code = p_error_code, updated_at = now()
   where id = p_outbox_id;
  update public.scholarship_applications
     set delivery_status = 'BLOCKED'
   where id = v_outbox.application_id;
  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, started_at, outcome, error_code
  ) values (
    v_outbox.id, v_outbox.delivery_generation, v_outbox.attempts, coalesce(v_outbox.updated_at, now()), 'BLOCKED', p_error_code
  );
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end
$block_scholarship_delivery$;

create or replace function public.complete_scholarship_delivery(
  p_outbox_id uuid,
  p_provider_reference text,
  p_http_status integer,
  p_request_id text default null
)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $complete_scholarship_delivery$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_app public.scholarship_applications;
  v_title text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null
     or p_provider_reference is null or length(btrim(p_provider_reference)) not between 1 and 200
     or p_http_status is null or p_http_status not between 200 and 299
     or (p_request_id is not null and length(p_request_id) > 200) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status = 'DELIVERED' then
    select * into v_app from public.scholarship_applications where id = v_outbox.application_id;
    return v_app;
  end if;
  if v_outbox.status <> 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;
  select * into v_app from public.scholarship_applications
   where id = v_outbox.application_id for update;
  if not found or v_app.status <> 'PENDING_DELIVERY' then
    raise exception 'SCHOLARSHIP_APPLICATION_NOT_DELIVERABLE' using errcode = 'PT409';
  end if;
  update private.scholarship_delivery_outbox
     set status = 'DELIVERED', lease_expires_at = null,
         provider_reference = btrim(p_provider_reference),
         delivered_at = now(), last_error_code = null, updated_at = now()
   where id = p_outbox_id;
  update public.scholarship_applications
     set status = 'SUBMITTED_EXTERNALLY',
         delivery_status = 'DELIVERED',
         provider_key = v_outbox.provider_key,
         provider_application_reference = btrim(p_provider_reference),
         externally_submitted_at = now()
   where id = v_app.id returning * into v_app;
  select title into v_title from public.opportunities where id = v_app.opportunity_id;
  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, note
  ) values (
    v_app.id, 'PENDING_DELIVERY', 'SUBMITTED_EXTERNALLY', 'PROVIDER',
    'Provider acknowledged delivery with reference ' || btrim(p_provider_reference) || '.'
  );
  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, outcome, http_status, provider_reference
  ) values (p_outbox_id, v_outbox.delivery_generation, v_outbox.attempts, 'DELIVERED', p_http_status, btrim(p_provider_reference));
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_app.graduate_id, 'تم إرسال طلب المنحة إلى الجهة المعلنة',
    'أكدت الجهة استلام طلبك على «' || v_title || '». رقم الطلب لدى الجهة: ' || btrim(p_provider_reference) || '.',
    'SCHOLARSHIP_APPLICATION_SUBMITTED_EXTERNALLY', v_app.id
  );
  return v_app;
exception
  when unique_violation then
    raise exception 'SCHOLARSHIP_PROVIDER_REFERENCE_CONFLICT' using errcode = 'PT409';
end
$complete_scholarship_delivery$;

create or replace function public.fail_scholarship_delivery(
  p_outbox_id uuid,
  p_error_code text,
  p_http_status integer default null,
  p_retryable boolean default true,
  p_retry_after_seconds integer default null
)
returns text
language plpgsql security definer set search_path = ''
as $fail_scholarship_delivery$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_final boolean;
  v_delay integer;
  v_app public.scholarship_applications;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null
     or p_error_code is null or p_error_code !~ '^[A-Z0-9_]{1,64}$'
     or (p_http_status is not null and p_http_status not between 100 and 599)
     or p_retryable is null
     or (p_retry_after_seconds is not null and p_retry_after_seconds not between 1 and 3600) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status <> 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;
  v_final := (not p_retryable) or v_outbox.attempts >= v_outbox.max_attempts;
  v_delay := least(
    3600,
    greatest(
      coalesce(p_retry_after_seconds, 0),
      (30 * power(2, greatest(v_outbox.attempts - 1, 0)))::integer
    )
  );

  update private.scholarship_delivery_outbox
     set status = case when v_final then 'FAILED' else 'PENDING' end,
         lease_expires_at = null,
         next_attempt_at = case when v_final then next_attempt_at else now() + make_interval(secs => v_delay) end,
         last_error_code = p_error_code,
         updated_at = now()
   where id = p_outbox_id;

  select * into v_app from public.scholarship_applications
   where id = v_outbox.application_id for update;
  update public.scholarship_applications
     set delivery_status = case when v_final then 'FAILED' else 'PENDING' end,
         status = case when v_final then 'DELIVERY_FAILED' else 'PENDING_DELIVERY' end
   where id = v_app.id returning * into v_app;

  insert into private.scholarship_delivery_attempts(
    outbox_id, attempt_number, outcome, http_status, error_code
  ) values (
    p_outbox_id, v_outbox.attempts,
    case when v_final then 'FAILED' else 'RETRY_SCHEDULED' end,
    p_http_status, p_error_code
  );

  if v_final then
    insert into public.scholarship_application_status_history(
      scholarship_application_id, old_status, new_status, source_type, note
    ) values (
      v_app.id, 'PENDING_DELIVERY', 'DELIVERY_FAILED', 'SYSTEM',
      'Provider delivery stopped after ' || v_outbox.attempts::text || ' attempts (' || p_error_code || ').'
    );
    insert into public.notifications(profile_id, title, body, type, related_entity_id)
    values (
      v_app.graduate_id, 'تعذر إرسال طلب المنحة',
      'لم نتمكن من إرسال طلبك إلى الجهة المعلنة بعد عدة محاولات. سيظهر الطلب كفشل إرسال إلى أن يعيد المسؤول المحاولة.',
      'SCHOLARSHIP_APPLICATION_DELIVERY_FAILED', v_app.id
    );
    return 'FAILED';
  end if;
  return 'PENDING';
end
$fail_scholarship_delivery$;

create or replace function public.process_scholarship_provider_event(
  p_provider_key text,
  p_event_id text,
  p_provider_reference text,
  p_new_status text,
  p_note text,
  p_payload_digest text
)
returns text
language plpgsql security definer set search_path = ''
as $process_scholarship_provider_event$
declare
  v_app public.scholarship_applications;
  v_title text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_provider_key is null or p_provider_key !~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'
     or p_event_id is null or length(btrim(p_event_id)) not between 1 and 200
     or p_provider_reference is null or length(btrim(p_provider_reference)) not between 1 and 200
     or p_new_status is null or p_new_status not in ('IN_REVIEW','ACCEPTED','REJECTED')
     or (p_note is not null and length(p_note) > 2000)
     or p_payload_digest is null or p_payload_digest !~ '^[a-f0-9]{64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select * into v_app from public.scholarship_applications
   where provider_key = p_provider_key
     and provider_application_reference = btrim(p_provider_reference)
   for update;
  if not found then
    raise exception 'SCHOLARSHIP_PROVIDER_REFERENCE_NOT_FOUND' using errcode = 'PT404';
  end if;

  if exists (
    select 1 from private.scholarship_provider_events
     where provider_key = p_provider_key and event_id = btrim(p_event_id)
  ) then
    return 'DUPLICATE';
  end if;
  if not (
    (v_app.status = 'SUBMITTED_EXTERNALLY' and p_new_status in ('IN_REVIEW','ACCEPTED','REJECTED'))
    or (v_app.status = 'IN_REVIEW' and p_new_status in ('ACCEPTED','REJECTED'))
  ) then
    raise exception 'INVALID_SCHOLARSHIP_STATUS_TRANSITION' using errcode = 'PT409';
  end if;

  insert into private.scholarship_provider_events(
    provider_key, event_id, application_id, received_status, payload_digest
  ) values (
    p_provider_key, btrim(p_event_id), v_app.id, p_new_status, p_payload_digest
  );
  update public.scholarship_applications
     set status = p_new_status,
         reviewed_at = case when p_new_status in ('ACCEPTED','REJECTED') then now() else reviewed_at end,
         review_note = nullif(btrim(coalesce(p_note,'')), '')
   where id = v_app.id returning * into v_app;
  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, note
  ) values (
    v_app.id,
    case when p_new_status = 'IN_REVIEW' then 'SUBMITTED_EXTERNALLY' else 'IN_REVIEW' end,
    p_new_status, 'PROVIDER', nullif(btrim(coalesce(p_note,'')), '')
  );
  select title into v_title from public.opportunities where id = v_app.opportunity_id;
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_app.graduate_id,
    case p_new_status when 'IN_REVIEW' then 'طلب المنحة قيد المراجعة'
      when 'ACCEPTED' then 'تم قبول طلب المنحة' else 'تم رفض طلب المنحة' end,
    case p_new_status when 'IN_REVIEW' then 'بدأت الجهة مراجعة طلبك على «' || v_title || '».'
      when 'ACCEPTED' then 'تم قبول طلبك على «' || v_title || '».'
      else 'تم رفض طلبك على «' || v_title || '». راجع الملاحظة المرفقة مع الطلب.' end,
    'SCHOLARSHIP_APPLICATION_' || p_new_status, v_app.id
  );
  return p_new_status;
end
$process_scholarship_provider_event$;

-- The new status check is validated only after existing rows have been normalized.
alter table public.scholarship_applications
  validate constraint scholarship_applications_status_check;

-- No provider mapping preserves the internal Alumni Connect review path; a mapping opts in to delivery.
create or replace function public.apply_for_scholarship(
  p_opportunity_id uuid,p_cv_document_id uuid default null,
  p_personal_statement text default null,p_application_data jsonb default '{}'::jsonb
)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $apply_for_scholarship$
declare
  v_uid uuid := public._require_uid();
  v_opportunity public.opportunities;
  v_mapping private.scholarship_provider_mappings;
  v_has_mapping boolean := false;
  v_status text;
  v_delivery_status text;
  v_app public.scholarship_applications;
begin
  if p_opportunity_id is null or p_application_data is null
     or jsonb_typeof(p_application_data) is distinct from 'object'
     or octet_length(p_application_data::text)>32768
     or (p_personal_statement is not null and length(p_personal_statement)>10000) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_opportunity from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_opportunity.type<>'SCHOLARSHIP' then raise exception 'NOT_A_SCHOLARSHIP' using errcode = 'PT422'; end if;
  if not public.is_opportunity_open(v_opportunity.status,v_opportunity.deadline,v_opportunity.end_at) then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  if cardinality(public.eligibility_failures(v_uid,v_opportunity.id))>0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422',
      detail=array_to_string(public.eligibility_failures(v_uid,v_opportunity.id),',');
  end if;
  if p_cv_document_id is not null and not exists(
    select 1 from public.cv_documents where id=p_cv_document_id and graduate_id=v_uid
  ) then raise exception 'CV_NOT_FOUND' using errcode = 'PT404'; end if;

  if not v_opportunity.is_sample then
    select * into v_mapping from private.scholarship_provider_mappings
     where opportunity_id=v_opportunity.id;
    v_has_mapping:=found;
  end if;
  if v_has_mapping then
    v_status:='PENDING_DELIVERY';
    v_delivery_status:=case when v_mapping.is_enabled then 'PENDING' else 'BLOCKED' end;
  else
    v_status:='SUBMITTED';
    v_delivery_status:='NOT_REQUIRED';
  end if;

  begin
    insert into public.scholarship_applications(
      opportunity_id,graduate_id,cv_document_id,personal_statement,application_data,status,delivery_status,provider_key
    ) values(
      v_opportunity.id,v_uid,p_cv_document_id,nullif(btrim(coalesce(p_personal_statement,'')),''),
      p_application_data,v_status,v_delivery_status,case when v_has_mapping then v_mapping.provider_key else null end
    ) returning * into v_app;
  exception when unique_violation then raise exception 'ALREADY_APPLIED' using errcode = 'PT409';
  end;

  if v_has_mapping then
    insert into private.scholarship_delivery_outbox(
      application_id,provider_key,external_opportunity_id,status,last_error_code
    ) values(
      v_app.id,v_mapping.provider_key,v_mapping.external_opportunity_id,
      case when v_mapping.is_enabled then 'PENDING' else 'BLOCKED' end,
      case when v_mapping.is_enabled then null else 'PROVIDER_MAPPING_DISABLED' end
    );
  end if;

  insert into public.scholarship_application_status_history(
    scholarship_application_id,old_status,new_status,source_type,actor_user_id,note
  ) values(v_app.id,null,v_status,'GRADUATE_ACTION',v_uid,
    case when v_opportunity.is_sample then 'Sample Scholarship saved locally; no external delivery.'
      when v_has_mapping and v_mapping.is_enabled then 'Application queued for provider delivery.'
      when v_has_mapping then 'Application saved locally; provider delivery is blocked.'
      else 'Application submitted for internal Alumni Connect review; no provider mapping configured.' end);
  insert into public.notifications(profile_id,title,body,type,related_entity_id)
  values(v_uid,'تم استلام طلب المنحة',
    case when v_opportunity.is_sample then 'تم حفظ طلبك على «'||v_opportunity.title||'» كبيانات تجريبية داخل المنصة.'
      when v_has_mapping and v_mapping.is_enabled then 'تم استلام طلبك على «'||v_opportunity.title||'» وهو الآن في قائمة انتظار الإرسال.'
      when v_has_mapping then 'تم حفظ طلبك على «'||v_opportunity.title||'» لكن الإرسال متوقف لأن تكامل الجهة معطل.'
      else 'تم استلام طلبك على «'||v_opportunity.title||'» داخل المنصة وسيتم مراجعته من فريق Alumni Connect.' end,
    'SCHOLARSHIP_APPLICATION_SUBMITTED',v_app.id);
  return v_app;
end
$apply_for_scholarship$;

create or replace function public.withdraw_scholarship_application(p_application_id uuid)
returns public.scholarship_applications language plpgsql security definer set search_path = ''
as $withdraw_scholarship_application$
declare
 v_uid uuid:=public._require_uid(); v_app public.scholarship_applications;
 v_outbox private.scholarship_delivery_outbox; v_old_status text;
begin
 if p_application_id is null then raise exception 'INVALID_INPUT' using errcode='PT422'; end if;
 select * into v_app from public.scholarship_applications
  where id=p_application_id and graduate_id=v_uid for update;
 if not found then raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode='PT404'; end if;
 if v_app.status not in ('SUBMITTED','INTERNAL_ONLY','PENDING_DELIVERY','DELIVERY_FAILED') then
  raise exception 'CANNOT_WITHDRAW_SCHOLARSHIP_APPLICATION' using errcode='PT422';
 end if;
 v_old_status:=v_app.status;
 if v_old_status not in ('SUBMITTED','INTERNAL_ONLY') then
  select * into v_outbox from private.scholarship_delivery_outbox where application_id=v_app.id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode='PT404'; end if;
  if v_outbox.status in ('PROCESSING','DELIVERED') then
   raise exception 'SCHOLARSHIP_DELIVERY_IN_PROGRESS' using errcode='PT409';
  end if;
  update private.scholarship_delivery_outbox
   set status='CANCELLED',lease_expires_at=null,updated_at=now() where id=v_outbox.id;
 end if;
 update public.scholarship_applications set status='WITHDRAWN',
   delivery_status=case when v_old_status in ('SUBMITTED','INTERNAL_ONLY') then 'NOT_REQUIRED' else 'CANCELLED' end
  where id=v_app.id returning * into v_app;
 insert into public.scholarship_application_status_history(
   scholarship_application_id,old_status,new_status,source_type,actor_user_id
 ) values(v_app.id,v_old_status,'WITHDRAWN','GRADUATE_ACTION',v_uid);
 insert into public.notifications(profile_id,title,body,type,related_entity_id)
 values(v_uid,'تم سحب طلب المنحة',
   'تم إيقاف طلبك داخل المنصة. لا يمكن سحب الطلب بعد تأكيد إرساله إلى الجهة المعلنة.',
   'SCHOLARSHIP_APPLICATION_WITHDRAWN',v_app.id);
 return v_app;
end
$withdraw_scholarship_application$;

create or replace function public.retry_scholarship_delivery(p_application_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $retry_scholarship_delivery$
declare
  v_uid uuid := public._require_uid();
  v_app public.scholarship_applications;
  v_outbox private.scholarship_delivery_outbox;
  v_mapping private.scholarship_provider_mappings;
begin
  if not private.is_active_scholarship_admin(v_uid) then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_application_id is null then raise exception 'INVALID_INPUT' using errcode = 'PT422'; end if;

  select * into v_app from public.scholarship_applications
   where id = p_application_id for update;
  if not found then raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_app.status not in ('PENDING_DELIVERY','DELIVERY_FAILED') then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_RETRYABLE' using errcode = 'PT409';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where application_id = v_app.id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status = 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_IN_PROGRESS' using errcode = 'PT409';
  end if;
  select * into v_mapping from private.scholarship_provider_mappings
   where opportunity_id = v_app.opportunity_id and is_enabled;
  if not found then raise exception 'SCHOLARSHIP_PROVIDER_NOT_CONFIGURED' using errcode = 'PT409'; end if;

  update private.scholarship_delivery_outbox
     set provider_key = v_mapping.provider_key,
         external_opportunity_id = v_mapping.external_opportunity_id,
         status = 'PENDING', attempts = 0, delivery_generation = delivery_generation + 1, next_attempt_at = now(),
         lease_expires_at = null, last_error_code = null, updated_at = now()
   where id = v_outbox.id;
  update public.scholarship_applications
     set status = 'PENDING_DELIVERY', delivery_status = 'PENDING',
         provider_key = v_mapping.provider_key,
         provider_application_reference = null,
         externally_submitted_at = null
   where id = v_app.id;

  if v_app.status = 'DELIVERY_FAILED' then
    insert into public.scholarship_application_status_history(
      scholarship_application_id, old_status, new_status, source_type, actor_user_id, note
    ) values (
      v_app.id, 'DELIVERY_FAILED', 'PENDING_DELIVERY', 'ADMIN', v_uid,
      'Administrator queued a new delivery attempt.'
    );
  end if;
  return true;
end
$retry_scholarship_delivery$;

-- If a worker disappears after the last allowed attempt, close the expired lease permanently.
create or replace function private.expire_scholarship_delivery_leases()
returns integer
language plpgsql security definer set search_path = ''
as $expire_scholarship_delivery_leases$
declare v_rows integer;
begin
  with expired as (
    update private.scholarship_delivery_outbox
       set status = 'FAILED', lease_expires_at = null,
           last_error_code = 'DELIVERY_WORKER_LEASE_EXPIRED',
           updated_at = now()
     where status = 'PROCESSING'
       and lease_expires_at < now()
       and attempts >= max_attempts
    returning id, application_id, attempts
  )
  update public.scholarship_applications a
     set status = 'DELIVERY_FAILED', delivery_status = 'FAILED'
    from expired e
   where a.id = e.application_id;
  get diagnostics v_rows = row_count;
  return v_rows;
end
$expire_scholarship_delivery_leases$;

create or replace function public.claim_scholarship_delivery(
  p_application_id uuid default null,
  p_limit integer default 10
)
returns table (
  outbox_id uuid,
  application_id uuid,
  provider_key text,
  external_opportunity_id text,
  attempt_number integer,
  idempotency_key text,
  request_payload jsonb,
  cv_storage_path text
)
language plpgsql security definer set search_path = ''
as $claim_scholarship_delivery$
declare
  v_item record;
  v_started_at timestamptz;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 50 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  perform private.expire_scholarship_delivery_leases();

  for v_item in
    select a.id as application_id, o.id as outbox_id
      from public.scholarship_applications a
      join private.scholarship_delivery_outbox o on o.application_id = a.id
     where (p_application_id is null or a.id = p_application_id)
       and a.status = 'PENDING_DELIVERY'
       and (
         (o.status = 'PENDING' and o.next_attempt_at <= now())
         or (o.status = 'PROCESSING' and o.lease_expires_at < now())
       )
       and o.attempts < o.max_attempts
     order by o.next_attempt_at asc, o.created_at asc
     for update of a, o skip locked
     limit p_limit
  loop
    v_started_at := now();
    update private.scholarship_delivery_outbox
       set status = 'PROCESSING',
           attempts = attempts + 1,
           last_attempt_started_at = v_started_at,
           lease_expires_at = v_started_at + interval '2 minutes',
           updated_at = v_started_at
     where id = v_item.outbox_id;

    update public.scholarship_applications
       set delivery_status = 'PROCESSING'
     where id = v_item.application_id;

    return query
    select o.id, a.id, o.provider_key, o.external_opportunity_id, o.attempts,
           o.id::text,
           jsonb_build_object(
             'schema_version', '1.0',
             'event', 'scholarship.application.submitted',
             'application_id', a.id,
             'provider_opportunity_id', o.external_opportunity_id,
             'submitted_at', a.applied_at,
             'applicant', jsonb_build_object('full_name', p.full_name, 'email', p.email),
             'personal_statement', a.personal_statement,
             'answers', a.application_data
           ),
           cv.storage_path
      from private.scholarship_delivery_outbox o
      join public.scholarship_applications a on a.id = o.application_id
      join public.profiles p on p.id = a.graduate_id
      left join public.cv_documents cv on cv.id = a.cv_document_id and cv.graduate_id = a.graduate_id
     where o.id = v_item.outbox_id;
  end loop;
end
$claim_scholarship_delivery$;

create or replace function public.block_scholarship_delivery(
  p_outbox_id uuid,
  p_error_code text
)
returns boolean
language plpgsql security definer set search_path = ''
as $block_scholarship_delivery$
declare
  v_outbox private.scholarship_delivery_outbox;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null or p_error_code is null
     or p_error_code !~ '^[A-Z0-9_]{1,64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status <> 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;
  update private.scholarship_delivery_outbox
     set status = 'BLOCKED', lease_expires_at = null,
         last_error_code = p_error_code, updated_at = now()
   where id = p_outbox_id;
  update public.scholarship_applications
     set delivery_status = 'BLOCKED'
   where id = v_outbox.application_id;
  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, started_at, outcome, error_code
  ) values (
    v_outbox.id, v_outbox.delivery_generation, v_outbox.attempts, coalesce(v_outbox.last_attempt_started_at, now()),
    'BLOCKED', p_error_code
  );
  return true;
end
$block_scholarship_delivery$;

create or replace function public.complete_scholarship_delivery(
  p_outbox_id uuid,
  p_provider_reference text,
  p_http_status integer,
  p_request_id text default null
)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $complete_scholarship_delivery$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_app public.scholarship_applications;
  v_title text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null
     or p_provider_reference is null or length(btrim(p_provider_reference)) not between 1 and 200
     or p_http_status is null or p_http_status not between 200 and 299
     or (p_request_id is not null and length(p_request_id) > 200) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status = 'DELIVERED' then
    select * into v_app from public.scholarship_applications where id = v_outbox.application_id;
    return v_app;
  end if;
  if v_outbox.status <> 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;
  select * into v_app from public.scholarship_applications
   where id = v_outbox.application_id for update;
  if not found or v_app.status <> 'PENDING_DELIVERY' then
    raise exception 'SCHOLARSHIP_APPLICATION_NOT_DELIVERABLE' using errcode = 'PT409';
  end if;
  update private.scholarship_delivery_outbox
     set status = 'DELIVERED', lease_expires_at = null,
         provider_reference = btrim(p_provider_reference),
         delivered_at = now(), last_error_code = null, updated_at = now()
   where id = p_outbox_id;
  update public.scholarship_applications
     set status = 'SUBMITTED_EXTERNALLY',
         delivery_status = 'DELIVERED',
         provider_key = v_outbox.provider_key,
         provider_application_reference = btrim(p_provider_reference),
         externally_submitted_at = now()
   where id = v_app.id returning * into v_app;
  select title into v_title from public.opportunities where id = v_app.opportunity_id;
  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, note
  ) values (
    v_app.id, 'PENDING_DELIVERY', 'SUBMITTED_EXTERNALLY', 'PROVIDER',
    'Provider acknowledged delivery with reference ' || btrim(p_provider_reference) || '.'
  );
  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, started_at, outcome, http_status, provider_reference
  ) values (
    p_outbox_id, v_outbox.delivery_generation, v_outbox.attempts, coalesce(v_outbox.last_attempt_started_at, now()),
    'DELIVERED', p_http_status, btrim(p_provider_reference)
  );
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_app.graduate_id, 'تم إرسال طلب المنحة إلى الجهة المعلنة',
    'أكدت الجهة استلام طلبك على «' || v_title || '». رقم الطلب لدى الجهة: ' || btrim(p_provider_reference) || '.',
    'SCHOLARSHIP_APPLICATION_SUBMITTED_EXTERNALLY', v_app.id
  );
  return v_app;
exception
  when unique_violation then
    raise exception 'SCHOLARSHIP_PROVIDER_REFERENCE_CONFLICT' using errcode = 'PT409';
end
$complete_scholarship_delivery$;

create or replace function public.fail_scholarship_delivery(
  p_outbox_id uuid,
  p_error_code text,
  p_http_status integer default null,
  p_retryable boolean default true,
  p_retry_after_seconds integer default null
)
returns text
language plpgsql security definer set search_path = ''
as $fail_scholarship_delivery$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_final boolean;
  v_delay integer;
  v_app public.scholarship_applications;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null
     or p_error_code is null or p_error_code !~ '^[A-Z0-9_]{1,64}$'
     or (p_http_status is not null and p_http_status not between 100 and 599)
     or p_retryable is null
     or (p_retry_after_seconds is not null and p_retry_after_seconds not between 1 and 3600) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_outbox.status <> 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;
  v_final := (not p_retryable) or v_outbox.attempts >= v_outbox.max_attempts;
  v_delay := least(
    3600,
    greatest(
      coalesce(p_retry_after_seconds, 0),
      (30 * power(2, greatest(v_outbox.attempts - 1, 0)))::integer
    )
  );

  update private.scholarship_delivery_outbox
     set status = case when v_final then 'FAILED' else 'PENDING' end,
         lease_expires_at = null,
         next_attempt_at = case when v_final then next_attempt_at else now() + make_interval(secs => v_delay) end,
         last_error_code = p_error_code,
         updated_at = now()
   where id = p_outbox_id;

  select * into v_app from public.scholarship_applications
   where id = v_outbox.application_id for update;
  update public.scholarship_applications
     set delivery_status = case when v_final then 'FAILED' else 'PENDING' end,
         status = case when v_final then 'DELIVERY_FAILED' else 'PENDING_DELIVERY' end
   where id = v_app.id returning * into v_app;

  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, started_at, outcome, http_status, error_code
  ) values (
    p_outbox_id, v_outbox.delivery_generation, v_outbox.attempts, coalesce(v_outbox.last_attempt_started_at, now()),
    case when v_final then 'FAILED' else 'RETRY_SCHEDULED' end,
    p_http_status, p_error_code
  );

  if v_final then
    insert into public.scholarship_application_status_history(
      scholarship_application_id, old_status, new_status, source_type, note
    ) values (
      v_app.id, 'PENDING_DELIVERY', 'DELIVERY_FAILED', 'SYSTEM',
      'Provider delivery stopped after ' || v_outbox.attempts::text || ' attempts (' || p_error_code || ').'
    );
    insert into public.notifications(profile_id, title, body, type, related_entity_id)
    values (
      v_app.graduate_id, 'تعذر إرسال طلب المنحة',
      'لم نتمكن من إرسال طلبك إلى الجهة المعلنة بعد عدة محاولات. سيظهر الطلب كفشل إرسال إلى أن يعيد المسؤول المحاولة.',
      'SCHOLARSHIP_APPLICATION_DELIVERY_FAILED', v_app.id
    );
    return 'FAILED';
  end if;
  return 'PENDING';
end
$fail_scholarship_delivery$;

create or replace function public.process_scholarship_provider_event(
  p_provider_key text,
  p_event_id text,
  p_provider_reference text,
  p_new_status text,
  p_note text,
  p_payload_digest text
)
returns text
language plpgsql security definer set search_path = ''
as $process_scholarship_provider_event$
declare
  v_app public.scholarship_applications;
  v_title text;
  v_existing_digest text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_provider_key is null or p_provider_key !~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'
     or p_event_id is null or length(btrim(p_event_id)) not between 1 and 200
     or p_provider_reference is null or length(btrim(p_provider_reference)) not between 1 and 200
     or p_new_status is null or p_new_status not in ('IN_REVIEW','ACCEPTED','REJECTED')
     or (p_note is not null and length(p_note) > 2000)
     or p_payload_digest is null or p_payload_digest !~ '^[a-f0-9]{64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select payload_digest into v_existing_digest
    from private.scholarship_provider_events
   where provider_key = p_provider_key and event_id = btrim(p_event_id);
  if found then
    if v_existing_digest <> p_payload_digest then
      raise exception 'PROVIDER_EVENT_ID_CONFLICT' using errcode = 'PT409';
    end if;
    return 'DUPLICATE';
  end if;

  select * into v_app from public.scholarship_applications
   where provider_key = p_provider_key
     and provider_application_reference = btrim(p_provider_reference)
   for update;
  if not found then
    raise exception 'SCHOLARSHIP_PROVIDER_REFERENCE_NOT_FOUND' using errcode = 'PT404';
  end if;
  if not (
    (v_app.status = 'SUBMITTED_EXTERNALLY' and p_new_status in ('IN_REVIEW','ACCEPTED','REJECTED'))
    or (v_app.status = 'IN_REVIEW' and p_new_status in ('ACCEPTED','REJECTED'))
  ) then
    raise exception 'INVALID_SCHOLARSHIP_STATUS_TRANSITION' using errcode = 'PT409';
  end if;

  begin
    insert into private.scholarship_provider_events(
      provider_key, event_id, application_id, received_status, payload_digest
    ) values (
      p_provider_key, btrim(p_event_id), v_app.id, p_new_status, p_payload_digest
    );
  exception when unique_violation then
    -- Another concurrent callback may have inserted this provider event after our first
    -- lookup. Re-read its digest after the unique-index wait instead of blindly accepting
    -- a changed payload as an idempotent retry.
    select payload_digest into v_existing_digest
      from private.scholarship_provider_events
     where provider_key = p_provider_key and event_id = btrim(p_event_id);
    if v_existing_digest = p_payload_digest then
      return 'DUPLICATE';
    end if;
    raise exception 'PROVIDER_EVENT_ID_CONFLICT' using errcode = 'PT409';
  end;

  update public.scholarship_applications
     set status = p_new_status,
         reviewed_at = case when p_new_status in ('ACCEPTED','REJECTED') then now() else reviewed_at end,
         review_note = nullif(btrim(coalesce(p_note,'')), '')
   where id = v_app.id returning * into v_app;
  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, note
  ) values (
    v_app.id,
    case when p_new_status = 'IN_REVIEW' then 'SUBMITTED_EXTERNALLY' else 'IN_REVIEW' end,
    p_new_status, 'PROVIDER', nullif(btrim(coalesce(p_note,'')), '')
  );
  select title into v_title from public.opportunities where id = v_app.opportunity_id;
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_app.graduate_id,
    case p_new_status when 'IN_REVIEW' then 'طلب المنحة قيد المراجعة'
      when 'ACCEPTED' then 'تم قبول طلب المنحة' else 'تم رفض طلب المنحة' end,
    case p_new_status when 'IN_REVIEW' then 'بدأت الجهة مراجعة طلبك على «' || v_title || '».'
      when 'ACCEPTED' then 'تم قبول طلبك على «' || v_title || '».'
      else 'تم رفض طلبك على «' || v_title || '». راجع الملاحظة المرفقة مع الطلب.' end,
    'SCHOLARSHIP_APPLICATION_' || p_new_status, v_app.id
  );
  return p_new_status;
end
$process_scholarship_provider_event$;


create or replace function public.get_scholarship_review_cv_path(p_application_id uuid)
returns text
language plpgsql stable security definer set search_path = ''
as $get_scholarship_review_cv_path$
declare
  v_uid uuid := public._require_uid();
  v_provider_key text;
  v_status text;
  v_path text;
begin
  if p_application_id is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select a.provider_key, a.status, cv.storage_path
    into v_provider_key, v_status, v_path
    from public.scholarship_applications a
    left join public.cv_documents cv
      on cv.id = a.cv_document_id and cv.graduate_id = a.graduate_id
   where a.id = p_application_id;
  if not found then
    raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode = 'PT404';
  end if;
  if v_status not in ('SUBMITTED_EXTERNALLY','IN_REVIEW','ACCEPTED','REJECTED') then
    raise exception 'SCHOLARSHIP_APPLICATION_NOT_REVIEWABLE' using errcode = 'PT409';
  end if;
  if not private.is_active_scholarship_admin(v_uid)
     and not private.is_active_scholarship_reviewer(v_uid, v_provider_key) then
    raise exception 'SCHOLARSHIP_REVIEWER_REQUIRED' using errcode = 'PT403';
  end if;
  return v_path;
end
$get_scholarship_review_cv_path$;
revoke all on function public.get_scholarship_review_cv_path(uuid) from public, anon, authenticated;
grant execute on function public.get_scholarship_review_cv_path(uuid) to authenticated;

-- Lock down every new database entry point. Only trusted Edge Functions may claim/complete
-- deliveries or apply provider callbacks; authenticated users see only scoped reviewer RPCs.
revoke all on function public.configure_scholarship_provider_mapping(uuid,text,text,boolean) from public, anon, authenticated;
revoke all on function public.set_scholarship_reviewer(uuid,text,boolean) from public, anon, authenticated;
revoke all on function public.get_scholarship_review_queue(text,text,integer) from public, anon, authenticated;
revoke all on function public.review_scholarship_application(uuid,text,text) from public, anon, authenticated;
revoke all on function public.retry_scholarship_delivery(uuid) from public, anon, authenticated;
revoke all on function public.get_scholarship_review_cv_path(uuid) from public, anon, authenticated;
revoke all on function public.claim_scholarship_delivery(uuid,integer) from public, anon, authenticated;
revoke all on function public.block_scholarship_delivery(uuid,text) from public, anon, authenticated;
revoke all on function public.complete_scholarship_delivery(uuid,text,integer,text) from public, anon, authenticated;
revoke all on function public.fail_scholarship_delivery(uuid,text,integer,boolean,integer) from public, anon, authenticated;
revoke all on function public.process_scholarship_provider_event(text,text,text,text,text,text) from public, anon, authenticated;

grant execute on function public.configure_scholarship_provider_mapping(uuid,text,text,boolean),
  public.set_scholarship_reviewer(uuid,text,boolean),
  public.get_scholarship_review_queue(text,text,integer),
  public.review_scholarship_application(uuid,text,text),
  public.retry_scholarship_delivery(uuid),
  public.get_scholarship_review_cv_path(uuid) to authenticated;

grant execute on function public.claim_scholarship_delivery(uuid,integer),
  public.block_scholarship_delivery(uuid,text),
  public.complete_scholarship_delivery(uuid,text,integer,text),
  public.fail_scholarship_delivery(uuid,text,integer,boolean,integer),
  public.process_scholarship_provider_event(text,text,text,text,text,text)
to service_role;

revoke all on function private.is_active_scholarship_reviewer(uuid,text) from public, anon, authenticated;
grant execute on function private.is_active_scholarship_reviewer(uuid,text) to service_role;

comment on table private.scholarship_delivery_outbox is
  'Private transactional outbox for external scholarship delivery; retries are idempotent by outbox UUID.';
comment on table private.scholarship_delivery_attempts is
  'Minimal delivery attempt audit. Raw personal data and provider response bodies are never stored here.';
comment on table private.scholarship_provider_events is
  'Idempotency ledger for HMAC-authenticated provider status webhooks.';
comment on table private.scholarship_reviewers is
  'Provider-scoped internal reviewer authorization. A reviewer cannot see another provider queue.';
comment on column public.scholarship_applications.status is
  'Lifecycle: PENDING_DELIVERY is not sent; SUBMITTED_EXTERNALLY follows provider acknowledgment; INTERNAL_ONLY is sample-only.';
comment on column public.scholarship_applications.delivery_status is
  'Delivery sub-state independent from reviewer/application lifecycle.';

-- Keep the provider's correlation/request id in the minimal audit record.
alter table private.scholarship_delivery_attempts
  add column if not exists provider_request_id text check (
    provider_request_id is null or length(provider_request_id) <= 200
  );

create or replace function public.assert_scholarship_admin()
returns boolean
language plpgsql security definer set search_path = ''
as $assert_scholarship_admin$
declare v_uid uuid := public._require_uid();
begin
  if not private.is_active_scholarship_admin(v_uid) then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  return true;
end
$assert_scholarship_admin$;
revoke all on function public.assert_scholarship_admin() from public, anon, authenticated;
grant execute on function public.assert_scholarship_admin() to authenticated;

-- Mapping administration follows the same application -> outbox lock order as submit,
-- withdraw, claim and retry. A disabled mapping never cancels an in-flight HTTP request.
create or replace function public.configure_scholarship_provider_mapping(
  p_opportunity_id uuid, p_provider_key text, p_external_opportunity_id text,
  p_is_enabled boolean default true
)
returns boolean language plpgsql security definer set search_path = ''
as $configure_scholarship_provider_mapping_v2$
declare
  v_actor uuid := public._require_uid();
begin
  if not private.is_active_scholarship_admin(v_actor) then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_opportunity_id is null or p_provider_key is null
     or p_provider_key !~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'
     or p_external_opportunity_id is null
     or length(btrim(p_external_opportunity_id)) not between 1 and 200
     or p_is_enabled is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists(select 1 from public.opportunities
    where id=p_opportunity_id and type='SCHOLARSHIP' and not is_sample) then
    raise exception 'SCHOLARSHIP_PROVIDER_MAPPING_NOT_ALLOWED' using errcode = 'PT422';
  end if;

  insert into private.scholarship_provider_mappings(
    opportunity_id,provider_key,external_opportunity_id,is_enabled,configured_by,configured_at,updated_at
  ) values(p_opportunity_id,p_provider_key,btrim(p_external_opportunity_id),p_is_enabled,v_actor,now(),now())
  on conflict(opportunity_id) do update
    set provider_key=excluded.provider_key,
        external_opportunity_id=excluded.external_opportunity_id,
        is_enabled=excluded.is_enabled,
        configured_by=excluded.configured_by,
        updated_at=now();

  insert into public.scholarship_application_status_history(
    scholarship_application_id,old_status,new_status,source_type,actor_user_id,note
  )
  select a.id,'SUBMITTED','PENDING_DELIVERY','SYSTEM',v_actor,
         'A platform administrator configured an external provider for this Scholarship.'
    from public.scholarship_applications a
   where a.opportunity_id=p_opportunity_id and a.status='SUBMITTED';

  update public.scholarship_applications
     set status='PENDING_DELIVERY',provider_key=p_provider_key,
         delivery_status=case when p_is_enabled then 'PENDING' else 'BLOCKED' end
   where opportunity_id=p_opportunity_id and status='SUBMITTED';

  insert into private.scholarship_delivery_outbox(
    application_id,provider_key,external_opportunity_id,status,last_error_code
  )
  select a.id,p_provider_key,btrim(p_external_opportunity_id),
         case when p_is_enabled then 'PENDING' else 'BLOCKED' end,
         case when p_is_enabled then null else 'PROVIDER_MAPPING_DISABLED' end
    from public.scholarship_applications a
   where a.opportunity_id=p_opportunity_id
     and a.status in ('PENDING_DELIVERY','DELIVERY_FAILED')
     and not exists(select 1 from private.scholarship_delivery_outbox o where o.application_id=a.id)
  on conflict(application_id) do nothing;

  if p_is_enabled then
    update private.scholarship_delivery_outbox o
       set provider_key=p_provider_key,
           external_opportunity_id=btrim(p_external_opportunity_id),
           status='PENDING',
           attempts=case when o.status in ('BLOCKED','FAILED') then 0 else o.attempts end,
           delivery_generation=o.delivery_generation+case
             when o.status in ('BLOCKED','FAILED')
               or o.provider_key is distinct from p_provider_key
               or o.external_opportunity_id is distinct from btrim(p_external_opportunity_id)
             then 1 else 0 end,
           next_attempt_at=now(),lease_expires_at=null,last_error_code=null,updated_at=now()
      from public.scholarship_applications a
     where o.application_id=a.id and a.opportunity_id=p_opportunity_id
       and a.status in ('PENDING_DELIVERY','DELIVERY_FAILED')
       and o.status in ('PENDING','BLOCKED','FAILED');

    update public.scholarship_applications a
       set status='PENDING_DELIVERY',provider_key=p_provider_key,delivery_status='PENDING'
     where a.opportunity_id=p_opportunity_id
       and a.status in ('PENDING_DELIVERY','DELIVERY_FAILED')
       and exists(select 1 from private.scholarship_delivery_outbox o
                   where o.application_id=a.id and o.status='PENDING');
  else
    update private.scholarship_delivery_outbox o
       set status='BLOCKED',lease_expires_at=null,
           last_error_code='PROVIDER_MAPPING_DISABLED',updated_at=now()
      from public.scholarship_applications a
     where o.application_id=a.id and a.opportunity_id=p_opportunity_id
       and o.status in ('PENDING','BLOCKED','FAILED');

    update public.scholarship_applications a set delivery_status='BLOCKED'
     where a.opportunity_id=p_opportunity_id and a.status='PENDING_DELIVERY'
       and exists(select 1 from private.scholarship_delivery_outbox o
                   where o.application_id=a.id and o.status='BLOCKED');
  end if;
  return true;
end
$configure_scholarship_provider_mapping_v2$;

create or replace function private.expire_scholarship_delivery_leases()
returns integer
language plpgsql security definer set search_path = ''
as $expire_scholarship_delivery_leases_v2$
declare
  v_item record;
  v_outbox private.scholarship_delivery_outbox;
  v_count integer := 0;
  v_title text;
begin
  for v_item in
    select a.id, a.graduate_id, a.opportunity_id
      from public.scholarship_applications a
      join private.scholarship_delivery_outbox o on o.application_id = a.id
     where a.status = 'PENDING_DELIVERY'
       and o.status = 'PROCESSING'
       and o.lease_expires_at < now()
       and o.attempts >= o.max_attempts
     order by o.lease_expires_at
     for update of a skip locked
  loop
    select * into v_outbox from private.scholarship_delivery_outbox
     where application_id = v_item.id for update;
    if not found or v_outbox.status <> 'PROCESSING'
       or v_outbox.lease_expires_at >= now()
       or v_outbox.attempts < v_outbox.max_attempts then
      continue;
    end if;
    update private.scholarship_delivery_outbox
       set status = 'FAILED', lease_expires_at = null,
           last_error_code = 'DELIVERY_WORKER_LEASE_EXPIRED', updated_at = now()
     where id = v_outbox.id;
    update public.scholarship_applications
       set status = 'DELIVERY_FAILED', delivery_status = 'FAILED'
     where id = v_item.id;
    insert into public.scholarship_application_status_history(
      scholarship_application_id, old_status, new_status, source_type, note
    ) values (
      v_item.id, 'PENDING_DELIVERY', 'DELIVERY_FAILED', 'SYSTEM',
      'Delivery worker lease expired after the configured maximum attempts.'
    );
    select title into v_title from public.opportunities where id = v_item.opportunity_id;
    insert into public.notifications(profile_id, title, body, type, related_entity_id)
    values (
      v_item.graduate_id, 'تعذر إرسال طلب المنحة',
      'انتهت مهلة محاولات الإرسال إلى «' || v_title || '». سيحتاج الطلب إلى إعادة محاولة من المسؤول.',
      'SCHOLARSHIP_APPLICATION_DELIVERY_FAILED', v_item.id
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$expire_scholarship_delivery_leases_v2$;
revoke all on function private.expire_scholarship_delivery_leases() from public, anon, authenticated;
grant execute on function private.expire_scholarship_delivery_leases() to service_role;

create or replace function public.claim_scholarship_delivery(
  p_application_id uuid default null,
  p_limit integer default 10
)
returns table (
  outbox_id uuid,
  application_id uuid,
  provider_key text,
  external_opportunity_id text,
  attempt_number integer,
  idempotency_key text,
  request_payload jsonb,
  cv_storage_path text
)
language plpgsql security definer set search_path = ''
as $claim_scholarship_delivery_v2$
declare
  v_item record;
  v_outbox private.scholarship_delivery_outbox;
  v_started_at timestamptz;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 50 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  perform private.expire_scholarship_delivery_leases();

  for v_item in
    select a.id as application_id
      from public.scholarship_applications a
      join private.scholarship_delivery_outbox o on o.application_id = a.id
     where (p_application_id is null or a.id = p_application_id)
       and a.status = 'PENDING_DELIVERY'
       and (
         (o.status = 'PENDING' and o.next_attempt_at <= now())
         or (o.status = 'PROCESSING' and o.lease_expires_at < now())
       )
       and o.attempts < o.max_attempts
     order by o.next_attempt_at asc, o.created_at asc
     for update of a skip locked
     limit p_limit
  loop
    select * into v_outbox from private.scholarship_delivery_outbox o
     where o.application_id = v_item.application_id for update;
    if not found or not (
      (v_outbox.status = 'PENDING' and v_outbox.next_attempt_at <= now())
      or (v_outbox.status = 'PROCESSING' and v_outbox.lease_expires_at < now())
    ) or v_outbox.attempts >= v_outbox.max_attempts then
      continue;
    end if;

    v_started_at := now();
    update private.scholarship_delivery_outbox
       set status = 'PROCESSING',
           attempts = attempts + 1,
           last_attempt_started_at = v_started_at,
           lease_expires_at = v_started_at + interval '2 minutes',
           updated_at = v_started_at
     where id = v_outbox.id;

    update public.scholarship_applications
       set delivery_status = 'PROCESSING'
     where id = v_item.application_id;

    return query
    select o.id, a.id, o.provider_key, o.external_opportunity_id, o.attempts,
           o.id::text,
           jsonb_build_object(
             'schema_version', '1.0',
             'event', 'scholarship.application.submitted',
             'application_id', a.id,
             'provider_opportunity_id', o.external_opportunity_id,
             'submitted_at', a.applied_at,
             'applicant', jsonb_build_object('full_name', p.full_name, 'email', p.email),
             'personal_statement', a.personal_statement,
             'answers', a.application_data
           ),
           cv.storage_path
      from private.scholarship_delivery_outbox o
      join public.scholarship_applications a on a.id = o.application_id
      join public.profiles p on p.id = a.graduate_id
      left join public.cv_documents cv on cv.id = a.cv_document_id and cv.graduate_id = a.graduate_id
     where o.id = v_outbox.id;
  end loop;
end
$claim_scholarship_delivery_v2$;

create or replace function public.block_scholarship_delivery(
  p_outbox_id uuid,
  p_error_code text
)
returns boolean
language plpgsql security definer set search_path = ''
as $block_scholarship_delivery_v2$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_application_id uuid;
  v_app public.scholarship_applications;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null or p_error_code is null
     or p_error_code !~ '^[A-Z0-9_]{1,64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select application_id into v_application_id from private.scholarship_delivery_outbox
   where id = p_outbox_id;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into v_app from public.scholarship_applications
   where id = v_application_id for update;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if v_outbox.status <> 'PROCESSING' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;
  update private.scholarship_delivery_outbox
     set status = 'BLOCKED', lease_expires_at = null,
         last_error_code = p_error_code, updated_at = now()
   where id = p_outbox_id;
  update public.scholarship_applications set delivery_status = 'BLOCKED'
   where id = v_app.id;
  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, started_at, outcome, error_code
  ) values (
    v_outbox.id, v_outbox.delivery_generation, v_outbox.attempts, coalesce(v_outbox.last_attempt_started_at, now()),
    'BLOCKED', p_error_code
  );
  return true;
end
$block_scholarship_delivery_v2$;

create or replace function public.complete_scholarship_delivery(
  p_outbox_id uuid,
  p_provider_reference text,
  p_http_status integer,
  p_request_id text default null
)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $complete_scholarship_delivery_v2$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_application_id uuid;
  v_app public.scholarship_applications;
  v_title text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null
     or p_provider_reference is null or length(btrim(p_provider_reference)) not between 1 and 200
     or p_http_status is null or p_http_status not between 200 and 299
     or (p_request_id is not null and length(p_request_id) > 200) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select application_id into v_application_id from private.scholarship_delivery_outbox
   where id = p_outbox_id;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into v_app from public.scholarship_applications
   where id = v_application_id for update;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if v_outbox.status = 'DELIVERED' then
    if v_app.provider_application_reference is distinct from btrim(p_provider_reference) then
      raise exception 'SCHOLARSHIP_PROVIDER_REFERENCE_CONFLICT' using errcode = 'PT409';
    end if;
    return v_app;
  end if;
  if v_outbox.status <> 'PROCESSING' or v_app.status <> 'PENDING_DELIVERY' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;

  update private.scholarship_delivery_outbox
     set status = 'DELIVERED', lease_expires_at = null,
         provider_reference = btrim(p_provider_reference),
         delivered_at = now(), last_error_code = null, updated_at = now()
   where id = p_outbox_id;
  update public.scholarship_applications
     set status = 'SUBMITTED_EXTERNALLY',
         delivery_status = 'DELIVERED',
         provider_key = v_outbox.provider_key,
         provider_application_reference = btrim(p_provider_reference),
         externally_submitted_at = now()
   where id = v_app.id returning * into v_app;
  select title into v_title from public.opportunities where id = v_app.opportunity_id;
  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, note
  ) values (
    v_app.id, 'PENDING_DELIVERY', 'SUBMITTED_EXTERNALLY', 'PROVIDER',
    'Provider acknowledged delivery with reference ' || btrim(p_provider_reference) || '.'
  );
  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, started_at, outcome, http_status,
    provider_reference, provider_request_id
  ) values (
    p_outbox_id, v_outbox.delivery_generation, v_outbox.attempts, coalesce(v_outbox.last_attempt_started_at, now()),
    'DELIVERED', p_http_status, btrim(p_provider_reference), nullif(btrim(coalesce(p_request_id,'')), '')
  );
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_app.graduate_id, 'تم إرسال طلب المنحة إلى الجهة المعلنة',
    'أكدت الجهة استلام طلبك على «' || v_title || '». رقم الطلب لدى الجهة: ' || btrim(p_provider_reference) || '.',
    'SCHOLARSHIP_APPLICATION_SUBMITTED_EXTERNALLY', v_app.id
  );
  return v_app;
exception
  when unique_violation then
    raise exception 'SCHOLARSHIP_PROVIDER_REFERENCE_CONFLICT' using errcode = 'PT409';
end
$complete_scholarship_delivery_v2$;

create or replace function public.fail_scholarship_delivery(
  p_outbox_id uuid,
  p_error_code text,
  p_http_status integer default null,
  p_retryable boolean default true,
  p_retry_after_seconds integer default null
)
returns text
language plpgsql security definer set search_path = ''
as $fail_scholarship_delivery_v2$
declare
  v_outbox private.scholarship_delivery_outbox;
  v_application_id uuid;
  v_app public.scholarship_applications;
  v_final boolean;
  v_delay integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_outbox_id is null
     or p_error_code is null or p_error_code !~ '^[A-Z0-9_]{1,64}$'
     or (p_http_status is not null and p_http_status not between 100 and 599)
     or p_retryable is null
     or (p_retry_after_seconds is not null and p_retry_after_seconds not between 1 and 3600) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select application_id into v_application_id from private.scholarship_delivery_outbox
   where id = p_outbox_id;
  if not found then raise exception 'SCHOLARSHIP_DELIVERY_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into v_app from public.scholarship_applications
   where id = v_application_id for update;
  select * into v_outbox from private.scholarship_delivery_outbox
   where id = p_outbox_id for update;
  if v_outbox.status <> 'PROCESSING' or v_app.status <> 'PENDING_DELIVERY' then
    raise exception 'SCHOLARSHIP_DELIVERY_NOT_IN_PROGRESS' using errcode = 'PT409';
  end if;

  v_final := (not p_retryable) or v_outbox.attempts >= v_outbox.max_attempts;
  v_delay := least(3600,
    greatest(coalesce(p_retry_after_seconds, 0),
      (30 * power(2, greatest(v_outbox.attempts - 1, 0)))::integer
    )
  );
  update private.scholarship_delivery_outbox
     set status = case when v_final then 'FAILED' else 'PENDING' end,
         lease_expires_at = null,
         next_attempt_at = case when v_final then next_attempt_at else now() + make_interval(secs => v_delay) end,
         last_error_code = p_error_code,
         updated_at = now()
   where id = p_outbox_id;
  update public.scholarship_applications
     set delivery_status = case when v_final then 'FAILED' else 'PENDING' end,
         status = case when v_final then 'DELIVERY_FAILED' else 'PENDING_DELIVERY' end
   where id = v_app.id returning * into v_app;

  insert into private.scholarship_delivery_attempts(
    outbox_id, delivery_generation, attempt_number, started_at, outcome, http_status, error_code
  ) values (
    p_outbox_id, v_outbox.delivery_generation, v_outbox.attempts, coalesce(v_outbox.last_attempt_started_at, now()),
    case when v_final then 'FAILED' else 'RETRY_SCHEDULED' end, p_http_status, p_error_code
  );

  if v_final then
    insert into public.scholarship_application_status_history(
      scholarship_application_id, old_status, new_status, source_type, note
    ) values (
      v_app.id, 'PENDING_DELIVERY', 'DELIVERY_FAILED', 'SYSTEM',
      'Provider delivery stopped after ' || v_outbox.attempts::text || ' attempts (' || p_error_code || ').'
    );
    insert into public.notifications(profile_id, title, body, type, related_entity_id)
    values (
      v_app.graduate_id, 'تعذر إرسال طلب المنحة',
      'لم نتمكن من إرسال طلبك إلى الجهة المعلنة بعد عدة محاولات. سيظهر الطلب كفشل إرسال إلى أن يعيد المسؤول المحاولة.',
      'SCHOLARSHIP_APPLICATION_DELIVERY_FAILED', v_app.id
    );
    return 'FAILED';
  end if;
  return 'PENDING';
end
$fail_scholarship_delivery_v2$;

-- Lock down the status helper and the worker's lease-maintenance routine as well.
revoke all on function private.expire_scholarship_delivery_leases() from public, anon, authenticated;
grant execute on function private.expire_scholarship_delivery_leases() to service_role;



create or replace function public.process_scholarship_provider_event(
  p_provider_key text,
  p_event_id text,
  p_provider_reference text,
  p_new_status text,
  p_note text,
  p_payload_digest text
)
returns text
language plpgsql security definer set search_path = ''
as $process_scholarship_provider_event_v2$
declare
  v_app public.scholarship_applications;
  v_title text;
  v_existing_digest text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_provider_key is null or p_provider_key !~ '^[A-Z0-9][A-Z0-9_-]{1,63}$'
     or p_event_id is null or length(btrim(p_event_id)) not between 1 and 200
     or p_provider_reference is null or length(btrim(p_provider_reference)) not between 1 and 200
     or p_new_status is null or p_new_status not in ('IN_REVIEW','ACCEPTED','REJECTED')
     or (p_note is not null and length(p_note) > 2000)
     or p_payload_digest is null or p_payload_digest !~ '^[a-f0-9]{64}$'
then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  -- Serialize callbacks for a provider event ID before checking its digest. Concurrent
  -- replays now observe the committed first event and cannot bypass payload conflict checks.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('scholarship-provider-event:' || p_provider_key || ':' || btrim(p_event_id), 0)
  );

  select payload_digest into v_existing_digest
    from private.scholarship_provider_events
   where provider_key = p_provider_key and event_id = btrim(p_event_id);
  if found then
    if v_existing_digest <> p_payload_digest then
      raise exception 'PROVIDER_EVENT_ID_CONFLICT' using errcode = 'PT409';
    end if;
    return 'DUPLICATE';
  end if;

  select * into v_app from public.scholarship_applications
   where provider_key = p_provider_key
     and provider_application_reference = btrim(p_provider_reference)
   for update;
  if not found then
    raise exception 'SCHOLARSHIP_PROVIDER_REFERENCE_NOT_FOUND' using errcode = 'PT404';
  end if;
  if not (
    (v_app.status = 'SUBMITTED_EXTERNALLY' and p_new_status in ('IN_REVIEW','ACCEPTED','REJECTED'))
    or (v_app.status = 'IN_REVIEW' and p_new_status in ('ACCEPTED','REJECTED'))
  ) then
    raise exception 'INVALID_SCHOLARSHIP_STATUS_TRANSITION' using errcode = 'PT409';
  end if;

  begin
    insert into private.scholarship_provider_events(
      provider_key, event_id, application_id, received_status, payload_digest
    ) values (
      p_provider_key, btrim(p_event_id), v_app.id, p_new_status, p_payload_digest
    );
  exception when unique_violation then
    -- Another concurrent callback may have inserted this provider event after our first
    -- lookup. Re-read its digest after the unique-index wait instead of blindly accepting
    -- a changed payload as an idempotent retry.
    select payload_digest into v_existing_digest
      from private.scholarship_provider_events
     where provider_key = p_provider_key and event_id = btrim(p_event_id);
    if v_existing_digest = p_payload_digest then
      return 'DUPLICATE';
    end if;
    raise exception 'PROVIDER_EVENT_ID_CONFLICT' using errcode = 'PT409';
  end;

  update public.scholarship_applications
     set status = p_new_status,
         reviewed_at = case when p_new_status in ('ACCEPTED','REJECTED') then now() else reviewed_at end,
         review_note = nullif(btrim(coalesce(p_note,'')), '')
   where id = v_app.id returning * into v_app;
  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, note
  ) values (
    v_app.id,
    case when p_new_status = 'IN_REVIEW' then 'SUBMITTED_EXTERNALLY' else 'IN_REVIEW' end,
    p_new_status, 'PROVIDER', nullif(btrim(coalesce(p_note,'')), '')
  );
  select title into v_title from public.opportunities where id = v_app.opportunity_id;
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_app.graduate_id,
    case p_new_status when 'IN_REVIEW' then 'طلب المنحة قيد المراجعة'
      when 'ACCEPTED' then 'تم قبول طلب المنحة' else 'تم رفض طلب المنحة' end,
    case p_new_status when 'IN_REVIEW' then 'بدأت الجهة مراجعة طلبك على «' || v_title || '».'
      when 'ACCEPTED' then 'تم قبول طلبك على «' || v_title || '».'
      else 'تم رفض طلبك على «' || v_title || '». راجع الملاحظة المرفقة مع الطلب.' end,
    'SCHOLARSHIP_APPLICATION_' || p_new_status, v_app.id
  );
  return p_new_status;
end


$process_scholarship_provider_event_v2$;
