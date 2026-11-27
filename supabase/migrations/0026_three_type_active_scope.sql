-- 0026: the active product scope is exactly JOB, INTERNSHIP and TRAINING.
--
-- Product decision 2026-11-26 (docs/PRODUCT_DECISIONS.md): EVENT, CONFERENCE and VOLUNTEER are not
-- independent opportunity types, and SCHOLARSHIP/COMPETITION stay permanently cancelled.
-- Forward-only: no historical migration is edited and no historical row is deleted. Legacy rows are
-- deactivated in place so audit data and foreign keys survive, while every entry point stops treating
-- them as actionable.
--
-- Database enforcement is two-layered on purpose:
--   * the trigger below rejects new excluded rows and any attempt to reactivate a legacy excluded row;
--   * public.is_opportunity_type_active is the single predicate used by discovery, recommendations,
--     learning suggestions and the registration path.
-- The pre-0026 CHECK constraint on opportunities.type must keep accepting legacy values: the retained
-- historical rows still carry them. The trigger is the constraint that enforces the active scope.

-- ---------------------------------------------------------------------------------------------------
-- 1. One predicate for the active catalogue, mirrored in TypeScript (opportunity-state.ts) and OpenAPI.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.is_opportunity_type_active(p_type text)
returns boolean
language sql
immutable
set search_path = ''
as $is_opportunity_type_active$
  -- coalesce matters: `null in (...)` is null, and a null predicate would silently skip both the
  -- insert guard and the RLS discovery filter.
  select coalesce(p_type in ('JOB','INTERNSHIP','TRAINING'), false)
$is_opportunity_type_active$;
revoke all on function public.is_opportunity_type_active(text) from public, anon;
grant execute on function public.is_opportunity_type_active(text) to authenticated, service_role;
comment on function public.is_opportunity_type_active(text) is
  'Active product scope. Only JOB, INTERNSHIP and TRAINING are active. EVENT, CONFERENCE, VOLUNTEER, SCHOLARSHIP and COMPETITION always return false.';

-- ---------------------------------------------------------------------------------------------------
-- 2. Hard guard: excluded types cannot be created, and a deactivated legacy row cannot be reactivated.
--    The single exception is the migration-safe write that deactivates an excluded row (status
--    CANCELLED), which is exactly how legacy data is neutralised.
-- ---------------------------------------------------------------------------------------------------
create or replace function private.reject_cancelled_opportunity_type()
returns trigger
language plpgsql
set search_path = ''
as $reject_cancelled_opportunity_type$
begin
  if public.is_opportunity_type_active(new.type) then
    return new;
  end if;
  -- INSERT is always rejected, even for a CANCELLED row: excluded types are not part of the catalogue.
  -- UPDATE is rejected unless it is a one-way deactivation of a retained historical row.
  if tg_op = 'INSERT' or new.status <> 'CANCELLED' then
    raise exception 'CANCELLED_OPPORTUNITY_TYPE' using errcode = 'PT422',
      detail = 'type ' || coalesce(new.type, '<null>') || ' is outside the active product scope (JOB, INTERNSHIP, TRAINING)';
  end if;
  return new;
end
$reject_cancelled_opportunity_type$;
revoke all on function private.reject_cancelled_opportunity_type() from public, anon, authenticated;

drop trigger if exists opportunities_reject_cancelled_type on public.opportunities;
create trigger opportunities_reject_cancelled_type
  before insert or update of type, status on public.opportunities
  for each row execute function private.reject_cancelled_opportunity_type();

-- ---------------------------------------------------------------------------------------------------
-- 3. Deactivate retained legacy rows in place (never delete history), then drop their derived cache.
-- ---------------------------------------------------------------------------------------------------
update public.opportunities
   set status = 'CANCELLED'
 where not public.is_opportunity_type_active(type)
   and status <> 'CANCELLED';

delete from public.recommendations r
 using public.opportunities o
 where o.id = r.opportunity_id
   and not public.is_opportunity_type_active(o.type);

-- Discovery uses public.is_opportunity_type_active inside opp_select from 0025, so the policy already
-- excludes the newly inactive types. Recreate it only to document the invariant for reviewers.
comment on policy opp_select on public.opportunities is
  'Open opportunities inside the active three-type scope; historical rows remain visible only to a user who already applied/registered/saved.';

-- ---------------------------------------------------------------------------------------------------
-- 4. Learning suggestions may only point at active TRAINING opportunities. EVENT/CONFERENCE were the
--    other suggested learning types; both are now outside the scope.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.get_skill_gaps() returns jsonb
language plpgsql stable security definer set search_path = '' as $get_skill_gaps_v2$
declare v_uid uuid := public._require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'skill_id', g.m, 'canonical_name', sk.canonical_name, 'recommendations_count', g.c,
      'learning_opportunities', coalesce((
        select jsonb_agg(jsonb_build_object('opportunity_id', o.id, 'type', o.type, 'title', o.title) order by os.importance desc, o.title)
        from public.opportunity_skills os join public.opportunities o on o.id = os.opportunity_id
        where os.skill_id = g.m and o.type = 'TRAINING'
          and public.is_opportunity_type_active(o.type)
          and public.is_opportunity_open(o.status, o.deadline, o.end_at)), '[]'::jsonb)) order by g.c desc, g.m)
    from (select m, count(*) c from public._open_recommendations(v_uid) r
            cross join lateral jsonb_array_elements_text(r.missing_skill_ids) m
           where true group by m) g
    join public.skills sk on sk.id = g.m), '[]'::jsonb);
end $get_skill_gaps_v2$;

create or replace function public.get_career_market_insights()
returns jsonb language plpgsql stable security definer set search_path = '' as $career_market_insights_v2$
declare v_uid uuid:=public._require_uid();
begin
 return (
  with demand as (
   select os.skill_id,count(distinct o.id)::integer as job_count from public.opportunity_skills os
   join public.opportunities o on o.id=os.opportunity_id
   where o.type in ('JOB','INTERNSHIP') and public.is_opportunity_open(o.status,o.deadline,o.end_at) group by os.skill_id
  ), top_demand as (
   select d.skill_id,s.canonical_name,d.job_count from demand d join public.skills s on s.id=d.skill_id
   order by d.job_count desc,s.canonical_name limit 20
  ), priority_gaps as (
   select d.skill_id,s.canonical_name,d.job_count,
    coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'type',o.type,'title',o.title) order by os.importance desc,o.title)
     from public.opportunity_skills os join public.opportunities o on o.id=os.opportunity_id
     where os.skill_id=d.skill_id and o.type = 'TRAINING'
       and public.is_opportunity_type_active(o.type)
       and public.is_opportunity_open(o.status,o.deadline,o.end_at)),'[]'::jsonb) as learning_opportunities
   from demand d join public.skills s on s.id=d.skill_id
   where not exists(select 1 from public.graduate_skills gs where gs.graduate_id=v_uid and gs.skill_id=d.skill_id)
   order by d.job_count desc,s.canonical_name limit 10
  )
  select jsonb_build_object('market_basis','active JOB and INTERNSHIP opportunities in this platform',
   'active_job_count',(select count(*) from public.opportunities o where o.type in ('JOB','INTERNSHIP')
     and public.is_opportunity_open(o.status,o.deadline,o.end_at)),
   'top_demand_skills',coalesce((select jsonb_agg(to_jsonb(t)) from top_demand t),'[]'::jsonb),
   'priority_skill_gaps',coalesce((select jsonb_agg(to_jsonb(g)) from priority_gaps g),'[]'::jsonb),
   'your_skills',coalesce((select jsonb_agg(jsonb_build_object('skill_id',gs.skill_id,'level',gs.level))
     from public.graduate_skills gs where gs.graduate_id=v_uid),'[]'::jsonb),
   'your_experience_years',private.total_experience_years(v_uid))
 );
end
$career_market_insights_v2$;
revoke all on function public.get_career_market_insights() from public,anon;
grant execute on function public.get_career_market_insights() to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 5. Direct registration is a TRAINING workflow only. The RPC name is historical (register_for_event)
--    and stays callable for client compatibility; its business contract is direct training registration.
--    JOB/INTERNSHIP use applications, and excluded types have no registration flow at all.
--    Phase 3 adds FIFO waitlist promotion on top of this same function.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.register_for_event(p_opportunity_id uuid)
returns public.event_registrations language plpgsql security definer set search_path = '' as $register_for_training$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities; r public.event_registrations; f text[]; v_status text;
  v_existing boolean;
begin
  -- Row lock serialises concurrent registrations so capacity cannot be exceeded (BR-013).
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type <> 'TRAINING' then
    raise exception 'NOT_REGISTRABLE' using errcode = 'PT422',
      detail = 'direct registration is only available for TRAINING';
  end if;
  if not public.is_opportunity_open(o.status, o.deadline, o.end_at)
     or (o.registration_opens_at is not null and o.registration_opens_at > now()) then
    raise exception 'REGISTRATION_CLOSED' using errcode = 'PT422';
  end if;
  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  select * into r from public.event_registrations
   where graduate_id = v_uid and opportunity_id = o.id;
  v_existing := found; -- capture NOW: later UPDATE statements overwrite FOUND
  if v_existing and r.status <> 'CANCELLED' then
    raise exception 'ALREADY_REGISTERED' using errcode = 'PT409';
  end if;
  if o.capacity is null or o.registered_count < o.capacity then
    v_status := 'REGISTERED';
    update public.opportunities set registered_count = registered_count + 1 where id = o.id;
  elsif o.waitlist_enabled then
    v_status := 'WAITLISTED';
  else
    raise exception 'EVENT_FULL' using errcode = 'PT409';
  end if;
  if v_existing then -- re-registering after a cancellation reuses the same logical row.
    update public.event_registrations set status = v_status, registered_at = now()
     where id = r.id returning * into r;
  else
    insert into public.event_registrations (opportunity_id, graduate_id, status)
    values (o.id, v_uid, v_status) returning * into r;
  end if;
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid,
          case when v_status = 'REGISTERED' then 'تم تسجيلك' else 'أنت في قائمة الانتظار' end,
          case when v_status = 'REGISTERED'
               then 'تم تسجيلك مباشرة في «' || o.title || '» (تدريب).'
               else 'البرنامج التدريبي «' || o.title || '» مكتمل العدد؛ تمت إضافتك إلى قائمة الانتظار (FIFO).' end,
          'TRAINING_REGISTERED', r.id);
  return r;
end $register_for_training$;
revoke all on function public.register_for_event(uuid) from public, anon, authenticated;
grant execute on function public.register_for_event(uuid) to authenticated;
comment on function public.register_for_event(uuid) is
  'Direct TRAINING registration (historical name kept for clients). JOB/INTERNSHIP use applications; excluded types are not registrable.';

-- The recommendation cache trigger from 0024 already invalidates rankings on type/status changes.
comment on table public.opportunities is
  'Opportunity catalogue. Active product scope is JOB/INTERNSHIP/TRAINING; excluded types are retained only as CANCELLED history.';
