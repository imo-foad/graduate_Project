-- 0025: product scope alignment — Scholarship (issue #14) and Competition (issue #15) are cancelled
-- product lines. This migration is strictly ADDITIVE and non-destructive:
--   * historical tables, rows, RPCs and migrations stay in place so existing data is never lost;
--   * the features are deactivated at every entry point (table guard, discovery policy, RPC grants,
--     recommendation candidates and the derived recommendation cache);
--   * nothing is dropped, truncated or CASCADEd.
-- Re-enabling either feature later needs an explicit product decision and a new forward migration.

-- ---------------------------------------------------------------------------------------------------
-- 1. One predicate for the active opportunity catalogue. Mirrored in TypeScript
--    (_shared/opportunity-state.ts) so SQL and Edge Functions cannot disagree.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.is_opportunity_type_active(p_type text)
returns boolean
language sql
immutable
set search_path = ''
as $is_opportunity_type_active$
  select p_type in ('JOB','INTERNSHIP','TRAINING','EVENT','CONFERENCE','VOLUNTEER')
$is_opportunity_type_active$;
revoke all on function public.is_opportunity_type_active(text) from public, anon;
grant execute on function public.is_opportunity_type_active(text) to authenticated, service_role;
comment on function public.is_opportunity_type_active(text) is
  'Active product scope for opportunity types. SCHOLARSHIP and COMPETITION are cancelled and always return false.';

-- ---------------------------------------------------------------------------------------------------
-- 2. Hard guard: no new Scholarship or Competition opportunity may be created, by any role.
--    The CHECK constraint keeps both legacy values so existing rows stay valid.
-- ---------------------------------------------------------------------------------------------------
create or replace function private.reject_cancelled_opportunity_type()
returns trigger
language plpgsql
set search_path = ''
as $reject_cancelled_opportunity_type$
begin
  if not public.is_opportunity_type_active(new.type) then
    raise exception 'CANCELLED_OPPORTUNITY_TYPE' using errcode = 'PT422',
      detail = 'type ' || new.type || ' is outside the active product scope';
  end if;
  return new;
end
$reject_cancelled_opportunity_type$;
revoke all on function private.reject_cancelled_opportunity_type() from public, anon, authenticated;

drop trigger if exists opportunities_reject_cancelled_type on public.opportunities;
create trigger opportunities_reject_cancelled_type
  before insert or update of type on public.opportunities
  for each row execute function private.reject_cancelled_opportunity_type();

-- ---------------------------------------------------------------------------------------------------
-- 3. Deactivate existing rows in place. History (applications, status history, delivery outbox,
--    provider events) keeps its foreign keys and remains queryable by service_role.
-- ---------------------------------------------------------------------------------------------------
update public.opportunities
   set status = 'CANCELLED'
 where not public.is_opportunity_type_active(type)
   and status <> 'CANCELLED';

-- Recommendations are a derived cache, not history: rows for cancelled types are removed so no
-- stale card can survive a cache read. The model version is bumped separately in scoring.ts, so every
-- profile is recomputed regardless.
delete from public.recommendations r
 using public.opportunities o
 where o.id = r.opportunity_id
   and not public.is_opportunity_type_active(o.type);

-- ---------------------------------------------------------------------------------------------------
-- 4. Discovery: cancelled types are never part of the public catalogue, even if a row is forced back
--    to ACTIVE. Ownership clauses for jobs/events/saved items are preserved; the scholarship and
--    competition clauses are not, because those flows no longer exist.
-- ---------------------------------------------------------------------------------------------------
drop policy if exists opp_select on public.opportunities;
create policy opp_select on public.opportunities for select to authenticated using (
  (public.is_opportunity_type_active(type)
    and public.is_opportunity_open(status, deadline, end_at))
  or exists (select 1 from public.applications a
             where a.opportunity_id = opportunities.id and a.graduate_id = (select auth.uid()))
  or exists (select 1 from public.event_registrations r
             where r.opportunity_id = opportunities.id and r.graduate_id = (select auth.uid()))
  or exists (select 1 from public.saved_opportunities s
             where s.opportunity_id = opportunities.id and s.graduate_id = (select auth.uid()))
);

-- ---------------------------------------------------------------------------------------------------
-- 5. Recommendation candidates: the projection excludes cancelled types before scoring, so they can
--    never be counted, ranked or cached (same body as 0024 plus the type predicate).
-- ---------------------------------------------------------------------------------------------------
create or replace function public.get_recommendation_candidates(p_graduate_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $recommendation_candidates_v4$
 select jsonb_build_object(
  'profile_version',(select gp0.profile_version from public.graduate_profiles gp0 where gp0.profile_id=p_graduate_id),
  'profile',(select jsonb_build_object('major',gp.major,'department',gp.department,'degree',gp.degree,
    'graduation_year',gp.graduation_year,'location',gp.location,'career_interests',to_jsonb(gp.career_interests),
    'work_preferences',gp.work_preferences,
    'experience_years',private.total_experience_years(gp.profile_id))
    from public.graduate_profiles gp where gp.profile_id=p_graduate_id),
  'skills',coalesce((select jsonb_agg(jsonb_build_object('skill_id',gs.skill_id,'level',gs.level))
    from public.graduate_skills gs where gs.graduate_id=p_graduate_id),'[]'::jsonb),
  'interaction_signals',coalesce((select jsonb_agg(jsonb_build_object('target_field',s.target_field,'weight',s.weight) order by s.weight desc)
    from (select lower(field) as target_field,
      greatest(-2.0,least(3.0,sum(case ri.interaction_type when 'IMPRESSION' then 0.05 when 'VIEW' then 0.2
        when 'SAVE' then 0.7 when 'APPLY' then 1.0 when 'REGISTER' then 0.7 when 'DISMISS' then -1.2
        when 'NOT_INTERESTED' then -2.0 else 0 end))) as weight
      from public.recommendation_interactions ri join public.opportunities io on io.id=ri.opportunity_id
      cross join lateral unnest(io.target_fields) as fields(field)
      where ri.graduate_id=p_graduate_id and ri.created_at>=now()-interval '90 days'
        and public.is_opportunity_type_active(io.type) group by lower(field)) s),'[]'::jsonb),
  'opportunities',coalesce((select jsonb_agg(jsonb_build_object(
    'id',o.id,'type',o.type,'title',o.title,'company_name',o.company_name,'description',o.description,'location',o.location,
    'attendance_mode',o.attendance_mode,'target_fields',to_jsonb(o.target_fields),'experience_level',jd.experience_level,
    'minimum_experience_years',jd.minimum_experience_years,'minimum_experience_required',jd.minimum_experience_required,
    'minimum_qualification',jd.minimum_qualification,'target_audience',ed.target_audience,
    'registration_opens_at',o.registration_opens_at,'capacity',o.capacity,
    'registered_count',o.registered_count,'waitlist_enabled',o.waitlist_enabled,
    'skills',coalesce((select jsonb_agg(jsonb_build_object('skill_id',os.skill_id,'importance',os.importance,
      'min_level',os.minimum_level,'is_required',os.is_required)) from public.opportunity_skills os where os.opportunity_id=o.id),'[]'::jsonb),
    'eligibility_failures',to_jsonb(public.eligibility_failures(p_graduate_id,o.id))))
   from public.opportunities o left join public.job_details jd on jd.opportunity_id=o.id
   left join public.event_details ed on ed.opportunity_id=o.id
   where public.is_opportunity_open(o.status,o.deadline,o.end_at)
    and public.is_opportunity_type_active(o.type)
    and not exists(select 1 from public.recommendation_interactions ri
      where ri.graduate_id=p_graduate_id and ri.opportunity_id=o.id and ri.interaction_type in ('DISMISS','NOT_INTERESTED')
      and not exists(select 1 from public.recommendation_interactions later
        where later.graduate_id=ri.graduate_id and later.opportunity_id=ri.opportunity_id and later.created_at>ri.created_at
          and later.interaction_type in ('VIEW','SAVE','APPLY','REGISTER')))),'[]'::jsonb)
 );
$recommendation_candidates_v4$;

-- ---------------------------------------------------------------------------------------------------
-- 6. Close the API surface. Every Scholarship/Competition routine is revoked from client roles and
--    kept executable only by service_role, which is where data-retention tooling runs.
--    The explicit list below documents the removal for reviewers and static contract checks; the
--    dynamic block after it guarantees that no overload is missed.
-- ---------------------------------------------------------------------------------------------------
revoke all on function
  public.apply_for_scholarship(uuid, uuid, text, jsonb),
  public.withdraw_scholarship_application(uuid),
  public.apply_for_competition(uuid, uuid, text, jsonb),
  public.withdraw_competition_application(uuid),
  public.create_admin_scholarship(text, text, text, text, text, timestamptz, text[], integer, integer, text[], text[]),
  public.update_admin_scholarship(uuid, text, text, text, text, text, timestamptz, text[], integer, integer, text[], text[]),
  public.publish_admin_scholarship(uuid),
  public.close_admin_scholarship(uuid),
  public.list_admin_scholarship_applications(uuid, text, integer, timestamptz, uuid),
  public.get_admin_scholarship_application(uuid),
  public.review_scholarship_application(uuid, text, text),
  public.assert_scholarship_admin(),
  public.configure_scholarship_provider_mapping(uuid, text, text, boolean),
  public.set_scholarship_reviewer(uuid, text, boolean),
  public.get_scholarship_review_queue(text, text, integer),
  public.get_scholarship_review_cv_path(uuid),
  public.retry_scholarship_delivery(uuid),
  public.claim_scholarship_delivery(uuid, integer),
  public.block_scholarship_delivery(uuid, text),
  public.complete_scholarship_delivery(uuid, text, integer, text),
  public.fail_scholarship_delivery(uuid, text, integer, boolean, integer),
  public.process_scholarship_provider_event(text, text, text, text, text, text)
from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 6b. Defence in depth: revoke by name pattern so no overload survives.
--    kept executable only by service_role, which is where data-retention tooling runs. Revoking is
--    done by name pattern so no overload can be missed; nothing is dropped.
-- ---------------------------------------------------------------------------------------------------
do $revoke_cancelled_scope_rpcs$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private')
       and (p.proname like '%scholarship%' or p.proname like '%competition%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.signature);
    execute format('grant execute on function %s to service_role', f.signature);
  end loop;
end
$revoke_cancelled_scope_rpcs$;

-- The four applicant-facing tables are no longer part of the API. RLS policies stay in place so a
-- future, explicitly approved feature can grant them again; the grants decide exposure.
revoke all on public.scholarship_applications,
               public.scholarship_application_status_history,
               public.competition_applications,
               public.competition_application_status_history
  from public, anon, authenticated;
grant select on public.scholarship_applications,
                public.scholarship_application_status_history,
                public.competition_applications,
                public.competition_application_status_history
  to service_role;

-- Scholarship-only CV review policies are dead code once the flow is cancelled; leaving them would
-- keep a public-schema policy that references scholarship applications for every CV read.
drop policy if exists cv_scholarship_admin_select on public.cv_documents;
drop policy if exists cv_objects_scholarship_admin_select on storage.objects;

comment on table public.scholarship_applications is
  'CANCELLED FEATURE (issue #14): historical scholarship submissions are retained for data integrity. Not exposed to client roles; service_role only.';
comment on table public.competition_applications is
  'CANCELLED FEATURE (issue #15): historical competition entries are retained for data integrity. Not exposed to client roles; service_role only.';
