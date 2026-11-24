-- 0014: free-first CV intelligence, explainable career paths, market gaps and interaction feedback.
-- No paid parser or LLM dependency is introduced. Extracted CV content remains pending until reviewed.

alter table public.cv_suggestions drop constraint if exists cv_suggestions_kind_check;
alter table public.cv_suggestions add constraint cv_suggestions_kind_check
  check (kind in ('SKILL','EXPERIENCE','CERTIFICATION','COURSE'));
alter table public.certifications add column if not exists credential_id text,
  add column if not exists expires_at date,
  add column if not exists source text not null default 'SELF_REPORTED';
alter table public.certifications drop constraint if exists certifications_source_check;
alter table public.certifications add constraint certifications_source_check
  check (source in ('SELF_REPORTED','CV_CONFIRMED','SEED'));

create table public.courses (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles(profile_id) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 200),
  provider text, completion_date date, duration text, reference_url text,
  skills text[] not null default '{}',
  source text not null default 'SELF_REPORTED' check (source in ('SELF_REPORTED','CV_CONFIRMED','SEED')),
  created_at timestamptz not null default now()
);
create index courses_graduate_idx on public.courses(graduate_id,completion_date desc);
alter table public.courses enable row level security;
grant select,insert,update,delete on public.courses to authenticated;
create policy courses_select on public.courses for select to authenticated using (graduate_id=(select auth.uid()));
create policy courses_insert on public.courses for insert to authenticated with check (graduate_id=(select auth.uid()) and source='SELF_REPORTED');
create policy courses_update on public.courses for update to authenticated
  using (graduate_id=(select auth.uid()) and source in ('SELF_REPORTED','CV_CONFIRMED'))
  with check (graduate_id=(select auth.uid()) and source in ('SELF_REPORTED','CV_CONFIRMED'));
create policy courses_delete on public.courses for delete to authenticated using (graduate_id=(select auth.uid()));
create trigger courses_dirty after insert or update or delete on public.courses
  for each row execute function public.mark_recommendations_dirty();

alter table public.job_details add column if not exists minimum_experience_years numeric(4,1),
  add column if not exists minimum_experience_required boolean not null default false;
alter table public.job_details drop constraint if exists job_details_minimum_experience_years_check;
alter table public.job_details add constraint job_details_minimum_experience_years_check
  check (minimum_experience_years is null or minimum_experience_years between 0 and 50);

create table public.recommendation_interactions (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles(profile_id) on delete cascade,
  opportunity_id uuid not null references public.opportunities(id) on delete cascade,
  interaction_type text not null check (interaction_type in ('IMPRESSION','VIEW','SAVE','APPLY','REGISTER','DISMISS','NOT_INTERESTED')),
  created_at timestamptz not null default now()
);
create index recommendation_interactions_grad_time_idx on public.recommendation_interactions(graduate_id,created_at desc);
create index recommendation_interactions_opportunity_idx on public.recommendation_interactions(graduate_id,opportunity_id,created_at desc);
alter table public.recommendation_interactions enable row level security;
grant select on public.recommendation_interactions to authenticated;
create policy recommendation_interactions_select on public.recommendation_interactions
  for select to authenticated using (graduate_id=(select auth.uid()));

create or replace function public.touch_recommendations_from_interaction()
returns trigger language plpgsql security definer set search_path = '' as $touch_interaction$
begin
 update public.graduate_profiles set recommendations_dirty=true,profile_version=profile_version+1,profile_updated_at=now()
 where profile_id=new.graduate_id;
 return new;
end
$touch_interaction$;
create trigger recommendation_interactions_touch after insert on public.recommendation_interactions
 for each row execute function public.touch_recommendations_from_interaction();

create or replace function public.log_saved_recommendation_interaction()
returns trigger language plpgsql security definer set search_path = '' as $log_saved_interaction$
begin
 insert into public.recommendation_interactions(graduate_id,opportunity_id,interaction_type)
 values(new.graduate_id,new.opportunity_id,'SAVE'); return new;
end
$log_saved_interaction$;
create trigger saved_opportunities_log_interaction after insert on public.saved_opportunities
 for each row execute function public.log_saved_recommendation_interaction();

create or replace function public.log_application_recommendation_interaction()
returns trigger language plpgsql security definer set search_path = '' as $log_application_interaction$
begin
 insert into public.recommendation_interactions(graduate_id,opportunity_id,interaction_type)
 values(new.graduate_id,new.opportunity_id,'APPLY'); return new;
end
$log_application_interaction$;
create trigger applications_log_interaction after insert on public.applications
 for each row execute function public.log_application_recommendation_interaction();

create or replace function public.log_event_recommendation_interaction()
returns trigger language plpgsql security definer set search_path = '' as $log_event_interaction$
begin
 if new.status in ('REGISTERED','WAITLISTED') then
  insert into public.recommendation_interactions(graduate_id,opportunity_id,interaction_type)
  values(new.graduate_id,new.opportunity_id,'REGISTER');
 end if;
 return new;
end
$log_event_interaction$;
create trigger event_registrations_log_interaction after insert on public.event_registrations
 for each row execute function public.log_event_recommendation_interaction();

create or replace function public.record_recommendation_interaction(p_opportunity_id uuid,p_interaction_type text)
returns jsonb language plpgsql security definer set search_path = '' as $record_recommendation_interaction$
declare v_uid uuid:=public._require_uid();
begin
 if p_opportunity_id is null or p_interaction_type is null
    or p_interaction_type not in ('IMPRESSION','VIEW','DISMISS','NOT_INTERESTED') then
  raise exception 'INVALID_INTERACTION' using errcode='PT422';
 end if;
 if not exists(select 1 from public.recommendations r join public.opportunities o on o.id=r.opportunity_id
   where r.graduate_id=v_uid and r.opportunity_id=p_opportunity_id
   and public.is_opportunity_open(o.status,o.deadline,o.end_at)) then
  raise exception 'RECOMMENDATION_NOT_FOUND' using errcode='PT404';
 end if;
 insert into public.recommendation_interactions(graduate_id,opportunity_id,interaction_type)
 values(v_uid,p_opportunity_id,p_interaction_type);
 return jsonb_build_object('recorded',true,'interaction_type',p_interaction_type);
end
$record_recommendation_interaction$;
revoke all on function public.record_recommendation_interaction(uuid,text) from public,anon;
grant execute on function public.record_recommendation_interaction(uuid,text) to authenticated;

create or replace function public.complete_cv_parse(p_cv_document_id uuid,p_graduate_id uuid,p_suggestions jsonb)
returns integer language plpgsql security definer set search_path = '' as $complete_cv_parse_v2$
declare v_status text; v_item jsonb; v_kind text; v_payload jsonb; v_count integer:=0;
begin
 if p_cv_document_id is null or p_graduate_id is null or p_suggestions is null
    or jsonb_typeof(p_suggestions) is distinct from 'array' or jsonb_array_length(p_suggestions)>200 then
  raise exception 'INVALID_CV_SUGGESTIONS' using errcode='PT422';
 end if;
 select parse_status into v_status from public.cv_documents
  where id=p_cv_document_id and graduate_id=p_graduate_id for update;
 if not found then raise exception 'CV_NOT_FOUND' using errcode='PT404'; end if;
 if v_status<>'PROCESSING' then raise exception 'CV_NOT_PROCESSING' using errcode='PT422'; end if;
 for v_item in select value from jsonb_array_elements(p_suggestions) loop
  if jsonb_typeof(v_item)<>'object' then raise exception 'INVALID_CV_SUGGESTIONS' using errcode='PT422'; end if;
  v_kind:=v_item->>'kind'; v_payload:=v_item->'payload';
  if v_kind not in ('SKILL','EXPERIENCE','CERTIFICATION','COURSE')
     or jsonb_typeof(v_payload) is distinct from 'object' then
   raise exception 'INVALID_CV_SUGGESTIONS' using errcode='PT422';
  end if;
  if v_kind='SKILL' and (coalesce(v_payload->>'skill_id','')='' or coalesce(v_payload->>'matched_term','')=''
     or length(v_payload->>'matched_term')>160
     or not exists(select 1 from public.skills where id=v_payload->>'skill_id')) then
   raise exception 'CV_SKILL_NOT_FOUND' using errcode='PT422';
  end if;
  if length(coalesce(v_payload->>'raw_text',''))>2000 then
   raise exception 'INVALID_CV_SUGGESTIONS' using errcode='PT422';
  end if;
 end loop;
 delete from public.cv_suggestions where cv_document_id=p_cv_document_id and graduate_id=p_graduate_id and status='PENDING';
 insert into public.cv_suggestions(graduate_id,cv_document_id,kind,payload,status)
 select p_graduate_id,p_cv_document_id,item->>'kind',item->'payload','PENDING'
 from jsonb_array_elements(p_suggestions) item;
 get diagnostics v_count=row_count;
 update public.cv_documents set parse_status='DONE',parsed_at=now(),error_message=null
 where id=p_cv_document_id and graduate_id=p_graduate_id;
 return v_count;
end
$complete_cv_parse_v2$;
revoke all on function public.complete_cv_parse(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.complete_cv_parse(uuid,uuid,jsonb) to service_role;

create or replace function public.review_cv_suggestions(p_decisions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $review_cv_suggestions$
declare
 v_uid uuid:=public._require_uid(); v_decision jsonb; v_suggestion public.cv_suggestions;
 v_payload jsonb; v_status text; v_start date; v_end date; v_current boolean;
 v_confirmed integer:=0; v_rejected integer:=0; v_title text;
begin
 if p_decisions is null or jsonb_typeof(p_decisions)<>'array' or jsonb_array_length(p_decisions)>100 then
  raise exception 'INVALID_CV_DECISIONS' using errcode='PT422';
 end if;
 perform 1 from public.graduate_profiles where profile_id=v_uid for update;
 for v_decision in select value from jsonb_array_elements(p_decisions) loop
  if jsonb_typeof(v_decision)<>'object' or v_decision->>'status' not in ('CONFIRMED','REJECTED') then
   raise exception 'INVALID_CV_DECISIONS' using errcode='PT422';
  end if;
  select * into v_suggestion from public.cv_suggestions
   where id=(v_decision->>'id')::uuid and graduate_id=v_uid and status='PENDING' for update;
  if not found then raise exception 'CV_SUGGESTION_NOT_FOUND' using errcode='PT404'; end if;
  v_status:=v_decision->>'status'; v_payload:=coalesce(v_decision->'payload',v_suggestion.payload);
  if v_status='REJECTED' then
   update public.cv_suggestions set status='REJECTED',decided_at=now() where id=v_suggestion.id;
   v_rejected:=v_rejected+1; continue;
  end if;
  if jsonb_typeof(v_payload)<>'object' then raise exception 'INVALID_CV_DECISIONS' using errcode='PT422'; end if;
  if v_suggestion.kind='SKILL' then
   if not exists(select 1 from public.skills where id=v_payload->>'skill_id') then raise exception 'CV_SKILL_NOT_FOUND' using errcode='PT422'; end if;
   insert into public.graduate_skills(graduate_id,skill_id,level,source)
   values(v_uid,v_payload->>'skill_id',greatest(1,least(5,coalesce(nullif(v_payload->>'level','')::integer,1)))::smallint,'CV_CONFIRMED')
   on conflict(graduate_id,skill_id) do nothing;
  elsif v_suggestion.kind='EXPERIENCE' then
   if coalesce(btrim(v_payload->>'company_name'),'')='' or coalesce(btrim(v_payload->>'job_title'),'')=''
      or coalesce(v_payload->>'start_date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'CV_EXPERIENCE_NEEDS_REVIEW' using errcode='PT422';
   end if;
   v_start:=(v_payload->>'start_date')::date; v_current:=coalesce((v_payload->>'is_current')::boolean,false);
   if v_current then
    v_end:=null;
    if exists(select 1 from public.career_history where graduate_id=v_uid and is_current) then
     raise exception 'CURRENT_JOB_CONFLICT' using errcode='PT409';
    end if;
   else
    if coalesce(v_payload->>'end_date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
     raise exception 'CV_EXPERIENCE_NEEDS_REVIEW' using errcode='PT422';
    end if;
    v_end:=(v_payload->>'end_date')::date;
    if v_end<v_start then raise exception 'INVALID_CV_DATE_RANGE' using errcode='PT422'; end if;
   end if;
   if not exists(select 1 from public.career_history c where c.graduate_id=v_uid
     and lower(c.company_name)=lower(btrim(v_payload->>'company_name'))
     and lower(c.job_title)=lower(btrim(v_payload->>'job_title')) and c.start_date=v_start) then
    insert into public.career_history(graduate_id,company_name,job_title,field,description,start_date,end_date,is_current,source)
    values(v_uid,btrim(v_payload->>'company_name'),btrim(v_payload->>'job_title'),
      nullif(btrim(v_payload->>'field'),''),nullif(btrim(v_payload->>'description'),''),v_start,v_end,v_current,'CV_CONFIRMED');
   end if;
  elsif v_suggestion.kind='CERTIFICATION' then
   v_title:=left(btrim(coalesce(v_payload->>'title','')),200);
   if v_title='' then raise exception 'CV_CREDENTIAL_NEEDS_REVIEW' using errcode='PT422'; end if;
   if not exists(select 1 from public.certifications c where c.graduate_id=v_uid and lower(c.title)=lower(v_title)
     and coalesce(lower(c.issuer),'')=coalesce(lower(v_payload->>'issuer'),'')) then
    insert into public.certifications(graduate_id,title,issuer,issue_date,reference_url,credential_id,expires_at,source)
    values(v_uid,v_title,nullif(left(btrim(v_payload->>'issuer'),200),''),
      case when (v_payload->>'issue_date') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then (v_payload->>'issue_date')::date else null end,
      nullif(left(btrim(v_payload->>'reference_url'),500),''),nullif(left(btrim(v_payload->>'credential_id'),200),''),
      case when (v_payload->>'expires_at') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then (v_payload->>'expires_at')::date else null end,'CV_CONFIRMED');
   end if;
  elsif v_suggestion.kind='COURSE' then
   v_title:=left(btrim(coalesce(v_payload->>'title','')),200);
   if v_title='' then raise exception 'CV_CREDENTIAL_NEEDS_REVIEW' using errcode='PT422'; end if;
   if not exists(select 1 from public.courses c where c.graduate_id=v_uid and lower(c.title)=lower(v_title)
     and coalesce(lower(c.provider),'')=coalesce(lower(v_payload->>'issuer'),'')) then
    insert into public.courses(graduate_id,title,provider,completion_date,duration,reference_url,source)
    values(v_uid,v_title,nullif(left(btrim(v_payload->>'issuer'),200),''),
      case when (v_payload->>'issue_date') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then (v_payload->>'issue_date')::date else null end,
      nullif(left(btrim(v_payload->>'duration'),100),''),nullif(left(btrim(v_payload->>'reference_url'),500),''),'CV_CONFIRMED');
   end if;
  end if;
  update public.cv_suggestions set status='CONFIRMED',payload=v_payload,decided_at=now() where id=v_suggestion.id;
  v_confirmed:=v_confirmed+1;
 end loop;
 return jsonb_build_object('confirmed',v_confirmed,'rejected',v_rejected);
end
$review_cv_suggestions$;
revoke all on function public.review_cv_suggestions(jsonb) from public,anon;
grant execute on function public.review_cv_suggestions(jsonb) to authenticated;

create or replace function public.set_job_experience_requirement(
 p_opportunity_id uuid,p_minimum_experience_years numeric,p_is_required boolean
) returns void language plpgsql security definer set search_path = '' as $set_job_experience_requirement$
declare o public.opportunities;
begin
 select * into o from public.opportunities where id=p_opportunity_id for update;
 if not found or o.type<>'JOB' then raise exception 'JOB_NOT_FOUND' using errcode='PT404'; end if;
 if not private.is_platform_admin()
    and (o.company_id is null or not private.is_company_member(o.company_id,array['OWNER','RECRUITER']::text[])) then
  raise exception 'NOT_COMPANY_MEMBER' using errcode='PT403';
 end if;
 if o.status<>'DRAFT' then raise exception 'JOB_NOT_DRAFT' using errcode='PT422'; end if;
 if p_minimum_experience_years is not null and p_minimum_experience_years not between 0 and 50 then
  raise exception 'INVALID_INPUT' using errcode='PT422';
 end if;
 if coalesce(p_is_required,false) and p_minimum_experience_years is null then
  raise exception 'INVALID_INPUT' using errcode='PT422';
 end if;
 insert into public.job_details(opportunity_id,minimum_experience_years,minimum_experience_required)
 values(p_opportunity_id,p_minimum_experience_years,coalesce(p_is_required,false))
 on conflict(opportunity_id) do update set minimum_experience_years=excluded.minimum_experience_years,
 minimum_experience_required=excluded.minimum_experience_required;
end
$set_job_experience_requirement$;
revoke all on function public.set_job_experience_requirement(uuid,numeric,boolean) from public,anon;
grant execute on function public.set_job_experience_requirement(uuid,numeric,boolean) to authenticated;

create or replace function public.get_recommendation_candidates(p_graduate_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $recommendation_candidates_v2$
 select jsonb_build_object(
  'profile_version',(select gp0.profile_version from public.graduate_profiles gp0 where gp0.profile_id=p_graduate_id),
  'profile',(select jsonb_build_object('major',gp.major,'department',gp.department,'degree',gp.degree,
    'graduation_year',gp.graduation_year,'location',gp.location,'career_interests',to_jsonb(gp.career_interests),
    'work_preferences',gp.work_preferences,
    'experience_years',coalesce((select round(sum((coalesce(c.end_date,current_date)-c.start_date)::numeric/365.25),2)
      from public.career_history c where c.graduate_id=gp.profile_id),0))
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
    'skills',coalesce((select jsonb_agg(jsonb_build_object('skill_id',os.skill_id,'importance',os.importance,
      'min_level',os.minimum_level,'is_required',os.is_required)) from public.opportunity_skills os where os.opportunity_id=o.id),'[]'::jsonb),
    'eligibility_failures',to_jsonb(public.eligibility_failures(p_graduate_id,o.id))))
   from public.opportunities o left join public.job_details jd on jd.opportunity_id=o.id
   left join public.event_details ed on ed.opportunity_id=o.id
   where public.is_opportunity_open(o.status,o.deadline,o.end_at)
    and not exists(select 1 from public.recommendation_interactions ri
      where ri.graduate_id=p_graduate_id and ri.opportunity_id=o.id and ri.interaction_type in ('DISMISS','NOT_INTERESTED')
      and not exists(select 1 from public.recommendation_interactions later
        where later.graduate_id=ri.graduate_id and later.opportunity_id=ri.opportunity_id and later.created_at>ri.created_at
          and later.interaction_type in ('VIEW','SAVE','APPLY','REGISTER')))),'[]'::jsonb)
 );
$recommendation_candidates_v2$;

create or replace function public.get_career_market_insights()
returns jsonb language plpgsql stable security definer set search_path = '' as $career_market_insights$
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
     where os.skill_id=d.skill_id and o.type in ('TRAINING','EVENT','CONFERENCE')
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
   'your_experience_years',coalesce((select round(sum((coalesce(c.end_date,current_date)-c.start_date)::numeric/365.25),2)
     from public.career_history c where c.graduate_id=v_uid),0))
 );
end
$career_market_insights$;
revoke all on function public.get_career_market_insights() from public,anon;
grant execute on function public.get_career_market_insights() to authenticated;
