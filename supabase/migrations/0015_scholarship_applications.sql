-- 0015: graduate scholarship applications with ownership, eligibility and lifecycle guards.
-- Scholarship submissions are independent from job applications and event registrations.

create table public.scholarship_applications (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references public.opportunities(id) on delete restrict,
  graduate_id uuid not null references public.graduate_profiles(profile_id) on delete cascade,
  cv_document_id uuid references public.cv_documents(id) on delete set null,
  personal_statement text,
  application_data jsonb not null default '{}'::jsonb,
  status text not null default 'SUBMITTED' check (status in ('SUBMITTED','WITHDRAWN')),
  applied_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (graduate_id, opportunity_id),
  check (jsonb_typeof(application_data) = 'object'),
  check (octet_length(application_data::text) <= 32768),
  check (personal_statement is null or length(personal_statement) <= 10000)
);
create index scholarship_applications_graduate_idx on public.scholarship_applications(graduate_id, applied_at desc);
create index scholarship_applications_opportunity_idx on public.scholarship_applications(opportunity_id, applied_at desc);
create trigger scholarship_applications_updated_at
  before update on public.scholarship_applications
  for each row execute function public.set_updated_at();

create table public.scholarship_application_status_history (
  id uuid primary key default gen_random_uuid(),
  scholarship_application_id uuid not null references public.scholarship_applications(id) on delete cascade,
  old_status text,
  new_status text not null check (new_status in ('SUBMITTED','WITHDRAWN')),
  source_type text not null check (source_type = 'GRADUATE_ACTION'),
  actor_user_id uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now(),
  note text
);
create index scholarship_application_history_app_idx
  on public.scholarship_application_status_history(scholarship_application_id, changed_at);

alter table public.scholarship_applications enable row level security;
alter table public.scholarship_application_status_history enable row level security;
revoke all on public.scholarship_applications, public.scholarship_application_status_history from anon, authenticated;
grant select on public.scholarship_applications, public.scholarship_application_status_history to authenticated;
create policy scholarship_applications_select on public.scholarship_applications
  for select to authenticated using (graduate_id = (select auth.uid()));
create policy scholarship_application_history_select on public.scholarship_application_status_history
  for select to authenticated using (
    exists (
      select 1 from public.scholarship_applications a
      where a.id = scholarship_application_id and a.graduate_id = (select auth.uid())
    )
  );

-- Applicants retain read access to a scholarship listing after its deadline or closure.
drop policy if exists opp_select on public.opportunities;
create policy opp_select on public.opportunities for select to authenticated using (
  public.is_opportunity_open(status, deadline, end_at)
  or exists (select 1 from public.applications a
             where a.opportunity_id = opportunities.id and a.graduate_id = (select auth.uid()))
  or exists (select 1 from public.event_registrations r
             where r.opportunity_id = opportunities.id and r.graduate_id = (select auth.uid()))
  or exists (select 1 from public.saved_opportunities s
             where s.opportunity_id = opportunities.id and s.graduate_id = (select auth.uid()))
  or exists (select 1 from public.scholarship_applications a
             where a.opportunity_id = opportunities.id and a.graduate_id = (select auth.uid()))
);

create or replace function public.log_scholarship_application_interaction()
returns trigger language plpgsql security definer set search_path = ''
as $log_scholarship_application_interaction$
begin
  insert into public.recommendation_interactions(graduate_id, opportunity_id, interaction_type)
  values (new.graduate_id, new.opportunity_id, 'APPLY');
  return new;
end
$log_scholarship_application_interaction$;
revoke all on function public.log_scholarship_application_interaction() from public, anon, authenticated;
create trigger scholarship_applications_log_interaction
  after insert on public.scholarship_applications
  for each row execute function public.log_scholarship_application_interaction();

create or replace function public.apply_for_scholarship(
  p_opportunity_id uuid,
  p_cv_document_id uuid default null,
  p_personal_statement text default null,
  p_application_data jsonb default '{}'::jsonb
)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $apply_for_scholarship$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
  f text[];
  app public.scholarship_applications;
begin
  if p_opportunity_id is null
     or p_application_data is null
     or jsonb_typeof(p_application_data) is distinct from 'object'
     or octet_length(p_application_data::text) > 32768
     or (p_personal_statement is not null and length(p_personal_statement) > 10000) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type <> 'SCHOLARSHIP' then raise exception 'NOT_A_SCHOLARSHIP' using errcode = 'PT422'; end if;
  if not public.is_opportunity_open(o.status, o.deadline, o.end_at) then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;

  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  if p_cv_document_id is not null and not exists (
    select 1 from public.cv_documents where id = p_cv_document_id and graduate_id = v_uid
  ) then raise exception 'CV_NOT_FOUND' using errcode = 'PT404'; end if;

  begin
    insert into public.scholarship_applications(
      opportunity_id, graduate_id, cv_document_id, personal_statement, application_data
    ) values (
      o.id, v_uid, p_cv_document_id, nullif(btrim(coalesce(p_personal_statement, '')), ''), p_application_data
    ) returning * into app;
  exception when unique_violation then
    raise exception 'ALREADY_APPLIED' using errcode = 'PT409';
  end;

  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, actor_user_id
  ) values (app.id, null, 'SUBMITTED', 'GRADUATE_ACTION', v_uid);
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_uid, 'تم تقديم طلب المنحة',
    case when o.is_sample
      then 'تم حفظ طلبك على «' || o.title || '» كبيانات تجريبية؛ لم يُرسل إلى الجهة المعلنة.'
      else 'تم تسجيل طلبك على «' || o.title || '» داخل المنصة.'
    end,
    'SCHOLARSHIP_APPLICATION_SUBMITTED', app.id
  );
  return app;
end
$apply_for_scholarship$;

create or replace function public.withdraw_scholarship_application(p_application_id uuid)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $withdraw_scholarship_application$
declare
  v_uid uuid := public._require_uid();
  app public.scholarship_applications;
begin
  select * into app from public.scholarship_applications
   where id = p_application_id and graduate_id = v_uid for update;
  if not found then raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if app.status <> 'SUBMITTED' then
    raise exception 'CANNOT_WITHDRAW_SCHOLARSHIP_APPLICATION' using errcode = 'PT422';
  end if;
  update public.scholarship_applications set status = 'WITHDRAWN'
   where id = app.id returning * into app;
  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, actor_user_id
  ) values (app.id, 'SUBMITTED', 'WITHDRAWN', 'GRADUATE_ACTION', v_uid);
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم سحب طلب المنحة', 'تم سحب طلبك من قائمة طلبات المنح داخل المنصة.',
          'SCHOLARSHIP_APPLICATION_WITHDRAWN', app.id);
  return app;
end
$withdraw_scholarship_application$;

revoke all on function public.apply_for_scholarship(uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.withdraw_scholarship_application(uuid) from public, anon, authenticated;
grant execute on function public.apply_for_scholarship(uuid, uuid, text, jsonb),
  public.withdraw_scholarship_application(uuid) to authenticated;

comment on table public.scholarship_applications is
  'Graduate-owned scholarship submissions. Sample listings are stored locally and not transmitted to external providers.';
comment on column public.scholarship_applications.application_data is
  'Scholarship form answers supplied by the client; JSON object, maximum 32 KiB.';
