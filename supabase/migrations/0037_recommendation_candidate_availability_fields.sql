-- 0037: preserve opportunity lifecycle fields across SQL -> Edge Function recommendation input.
--
-- The deterministic scorer calls registrationAvailability(), which treats a missing status as CLOSED.
-- The previous candidate projection filtered active rows in SQL but omitted status/deadline/end_at from
-- each JSON object, silently dropping every valid recommendation before it could be cached.
-- Keep the SQL candidate filter authoritative and include the exact lifecycle fields needed by scoring.
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
    'id',o.id,'type',o.type,'status',o.status,'deadline',o.deadline,'end_at',o.end_at,
    'title',o.title,'company_name',o.company_name,'description',o.description,'location',o.location,
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

comment on function public.get_recommendation_candidates(uuid) is
  'Service-role candidate projection: includes status/deadline/end_at for deterministic availability scoring and only returns active, verified listings.';
