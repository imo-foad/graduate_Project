-- 0032: company verification state is a hard input to opportunity discovery and cached recommendations.
--
-- Operational rule:
--   * only VERIFIED companies' company-owned opportunities can be returned for recommendations or applied to;
--   * moving a company away from VERIFIED invalidates every recommendation snapshot;
--   * while suspended/rejected, company members cannot edit an already ACTIVE listing;
--   * they may close an ACTIVE listing as a safe deactivation action, but cannot republish it.
-- DRAFT editing remains allowed; publication is already gated by publish_company_job.

-- A company verification decision changes the candidate catalogue globally. Bump the recommendation
-- snapshot version as well as marking rows dirty, so an in-flight calculation cannot overwrite the
-- invalidation with a stale catalogue snapshot.
create or replace function private.mark_company_recommendations_dirty()
returns trigger
language plpgsql security definer set search_path = ''
as $mark_company_recommendations_dirty$
begin
  if new.verification_status is distinct from old.verification_status then
    update public.graduate_profiles
       set recommendations_dirty = true,
           profile_version = profile_version + 1,
           profile_updated_at = now();
  end if;
  return new;
end
$mark_company_recommendations_dirty$;

revoke all on function private.mark_company_recommendations_dirty()
  from public, anon, authenticated;

drop trigger if exists companies_recommendations_dirty on public.companies;
create trigger companies_recommendations_dirty
  after update of verification_status on public.companies
  for each row
  when (old.verification_status is distinct from new.verification_status)
  execute function private.mark_company_recommendations_dirty();

-- SECURITY DEFINER discovery RPCs bypass RLS. Enforce the same active-type and company-verification
-- gates here, not only in the client-side ranking code.
create or replace function public.get_recommendation_candidates(p_graduate_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $recommendation_candidates_v4$
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
      where ri.graduate_id=p_graduate_id and ri.created_at>=now()-interval '90 days' group by lower(field)) s),'[]'::jsonb),
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
     and (o.company_id is null or exists (
       select 1 from public.companies c
        where c.id=o.company_id and c.verification_status='VERIFIED'
     ))
    and not exists(select 1 from public.recommendation_interactions ri
      where ri.graduate_id=p_graduate_id and ri.opportunity_id=o.id and ri.interaction_type in ('DISMISS','NOT_INTERESTED')
      and not exists(select 1 from public.recommendation_interactions later
        where later.graduate_id=ri.graduate_id and later.opportunity_id=ri.opportunity_id and later.created_at>ri.created_at
          and later.interaction_type in ('VIEW','SAVE','APPLY','REGISTER')))),'[]'::jsonb)
 );
$recommendation_candidates_v4$;

-- Existing company RPCs already require an active OWNER/RECRUITER membership. A suspended/rejected
-- company cannot keep editing the content of an ACTIVE listing; closing remains an allowed safe action.
create or replace function public.update_company_job(
  p_opportunity_id uuid,
  p_title text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONSITE',
  p_deadline timestamptz default null
)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $update_company_job_verified$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
  v_company_status text;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found or o.company_id is null then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if not private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if o.status not in ('DRAFT','ACTIVE') then
    raise exception 'OPPORTUNITY_NOT_EDITABLE' using errcode = 'PT422';
  end if;
  if o.status = 'ACTIVE' then
    select c.verification_status into v_company_status
      from public.companies c where c.id = o.company_id for share;
    if v_company_status is distinct from 'VERIFIED' then
      raise exception 'COMPANY_NOT_VERIFIED' using errcode = 'PT422';
    end if;
  end if;
  if length(btrim(coalesce(p_title,''))) < 3 or length(btrim(coalesce(p_description,''))) < 10
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or (p_deadline is not null and p_deadline <= now()) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.opportunities set title = btrim(p_title), description = p_description,
    location = nullif(btrim(coalesce(p_location,'')), ''), attendance_mode = p_attendance_mode,
    deadline = p_deadline
   where id = o.id returning * into o;
  return o;
end
$update_company_job_verified$;

revoke all on function public.update_company_job(uuid,text,text,text,text,timestamptz)
  from public, anon, authenticated;
grant execute on function public.update_company_job(uuid,text,text,text,text,timestamptz)
  to authenticated;

comment on function public.get_recommendation_candidates(uuid) is
  'Service-role candidate projection: only active opportunity types and verified company-owned listings are returned.';
comment on function public.update_company_job(uuid,text,text,text,text,timestamptz) is
  'Company OWNER/RECRUITER can edit drafts; editing an ACTIVE listing requires company verification. Closing remains the safe deactivation action while suspended.';
