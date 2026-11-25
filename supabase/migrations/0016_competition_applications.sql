-- 0016: dedicated graduate competition entries, distinct from event registration and scholarship submissions.

create table public.competition_applications (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references public.opportunities(id) on delete restrict,
  graduate_id uuid not null references public.graduate_profiles(profile_id) on delete cascade,
  cv_document_id uuid references public.cv_documents(id) on delete set null,
  personal_statement text,
  submission_data jsonb not null default '{}'::jsonb,
  status text not null default 'SUBMITTED' check (status in ('SUBMITTED','WITHDRAWN')),
  applied_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (graduate_id, opportunity_id),
  check (jsonb_typeof(submission_data) = 'object'),
  check (octet_length(submission_data::text) <= 32768),
  check (personal_statement is null or length(personal_statement) <= 10000)
);
create index competition_applications_graduate_idx on public.competition_applications(graduate_id, applied_at desc);
create index competition_applications_opportunity_idx on public.competition_applications(opportunity_id, applied_at desc);
create trigger competition_applications_updated_at
  before update on public.competition_applications
  for each row execute function public.set_updated_at();

create table public.competition_application_status_history (
  id uuid primary key default gen_random_uuid(),
  competition_application_id uuid not null references public.competition_applications(id) on delete cascade,
  old_status text,
  new_status text not null check (new_status in ('SUBMITTED','WITHDRAWN')),
  source_type text not null check (source_type = 'GRADUATE_ACTION'),
  actor_user_id uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now(),
  note text
);
create index competition_application_history_app_idx
  on public.competition_application_status_history(competition_application_id, changed_at);

alter table public.competition_applications enable row level security;
alter table public.competition_application_status_history enable row level security;
revoke all on public.competition_applications, public.competition_application_status_history from anon, authenticated;
grant select on public.competition_applications, public.competition_application_status_history to authenticated;
create policy competition_applications_select on public.competition_applications
  for select to authenticated using (graduate_id = (select auth.uid()));
create policy competition_application_history_select on public.competition_application_status_history
  for select to authenticated using (
    exists (
      select 1 from public.competition_applications a
      where a.id = competition_application_id and a.graduate_id = (select auth.uid())
    )
  );

-- Keep the already-submitted listings readable after closure for the owner.
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
  or exists (select 1 from public.competition_applications a
             where a.opportunity_id = opportunities.id and a.graduate_id = (select auth.uid()))
);

create or replace function public.log_competition_application_interaction()
returns trigger language plpgsql security definer set search_path = ''
as $log_competition_application_interaction$
begin
  insert into public.recommendation_interactions(graduate_id, opportunity_id, interaction_type)
  values (new.graduate_id, new.opportunity_id, 'APPLY');
  return new;
end
$log_competition_application_interaction$;
revoke all on function public.log_competition_application_interaction() from public, anon, authenticated;
create trigger competition_applications_log_interaction
  after insert on public.competition_applications
  for each row execute function public.log_competition_application_interaction();

create or replace function public.apply_for_competition(
  p_opportunity_id uuid,
  p_cv_document_id uuid default null,
  p_personal_statement text default null,
  p_submission_data jsonb default '{}'::jsonb
)
returns public.competition_applications
language plpgsql security definer set search_path = ''
as $apply_for_competition$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
  f text[];
  app public.competition_applications;
begin
  if p_opportunity_id is null
     or p_submission_data is null
     or jsonb_typeof(p_submission_data) is distinct from 'object'
     or octet_length(p_submission_data::text) > 32768
     or (p_personal_statement is not null and length(p_personal_statement) > 10000) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type <> 'COMPETITION' then raise exception 'NOT_A_COMPETITION' using errcode = 'PT422'; end if;
  if not public.is_opportunity_open(o.status, o.deadline, o.end_at) then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  if o.registration_opens_at is not null and o.registration_opens_at > now() then
    raise exception 'OPPORTUNITY_NOT_OPEN' using errcode = 'PT422';
  end if;

  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  if p_cv_document_id is not null and not exists (
    select 1 from public.cv_documents where id = p_cv_document_id and graduate_id = v_uid
  ) then raise exception 'CV_NOT_FOUND' using errcode = 'PT404'; end if;

  begin
    insert into public.competition_applications(
      opportunity_id, graduate_id, cv_document_id, personal_statement, submission_data
    ) values (
      o.id, v_uid, p_cv_document_id, nullif(btrim(coalesce(p_personal_statement, '')), ''), p_submission_data
    ) returning * into app;
  exception when unique_violation then
    raise exception 'ALREADY_APPLIED' using errcode = 'PT409';
  end;

  insert into public.competition_application_status_history(
    competition_application_id, old_status, new_status, source_type, actor_user_id
  ) values (app.id, null, 'SUBMITTED', 'GRADUATE_ACTION', v_uid);
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (
    v_uid, 'تم تقديم طلب المسابقة',
    case when o.is_sample
      then 'تم حفظ مشاركتك في «' || o.title || '» كبيانات تجريبية؛ لم تُرسل إلى الجهة المنظمة.'
      else 'تم تسجيل مشاركتك في «' || o.title || '» داخل المنصة.'
    end,
    'COMPETITION_APPLICATION_SUBMITTED', app.id
  );
  return app;
end
$apply_for_competition$;

create or replace function public.withdraw_competition_application(p_application_id uuid)
returns public.competition_applications
language plpgsql security definer set search_path = ''
as $withdraw_competition_application$
declare
  v_uid uuid := public._require_uid();
  app public.competition_applications;
begin
  select * into app from public.competition_applications
   where id = p_application_id and graduate_id = v_uid for update;
  if not found then raise exception 'COMPETITION_APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if app.status <> 'SUBMITTED' then
    raise exception 'CANNOT_WITHDRAW_COMPETITION_APPLICATION' using errcode = 'PT422';
  end if;
  update public.competition_applications set status = 'WITHDRAWN'
   where id = app.id returning * into app;
  insert into public.competition_application_status_history(
    competition_application_id, old_status, new_status, source_type, actor_user_id
  ) values (app.id, 'SUBMITTED', 'WITHDRAWN', 'GRADUATE_ACTION', v_uid);
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم سحب طلب المسابقة', 'تم سحب مشاركتك من قائمة طلبات المسابقات داخل المنصة.',
          'COMPETITION_APPLICATION_WITHDRAWN', app.id);
  return app;
end
$withdraw_competition_application$;

revoke all on function public.apply_for_competition(uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.withdraw_competition_application(uuid) from public, anon, authenticated;
grant execute on function public.apply_for_competition(uuid, uuid, text, jsonb),
  public.withdraw_competition_application(uuid) to authenticated;

comment on table public.competition_applications is
  'Graduate-owned competition submissions. Sample listings are stored locally and are not transmitted to external organizers.';
comment on column public.competition_applications.submission_data is
  'Flexible competition-entry data supplied by the client; JSON object, maximum 32 KiB. No team or judging workflow is assumed.';
