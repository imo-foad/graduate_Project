-- 0008: fix scalar-to-array appends in eligibility and profile insights.
-- array_append makes scalar element types explicit and preserves the public API.

create or replace function public.eligibility_failures(p_graduate uuid, p_opportunity uuid)
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare
  gp public.graduate_profiles; e public.opportunity_eligibility;
  f text[] := '{}'; cert text;
begin
  select * into gp from public.graduate_profiles where profile_id = p_graduate;
  select * into e from public.opportunity_eligibility where opportunity_id = p_opportunity;
  if not found then return f; end if;
  if e.min_graduation_year is not null
     and (gp.graduation_year is null or gp.graduation_year < e.min_graduation_year) then
    f := array_append(f, 'GRADUATION_YEAR_TOO_EARLY');
  end if;
  if e.max_graduation_year is not null
     and (gp.graduation_year is null or gp.graduation_year > e.max_graduation_year) then
    f := array_append(f, 'GRADUATION_YEAR_TOO_LATE');
  end if;
  if cardinality(e.allowed_degrees) > 0
     and (gp.degree is null
          or not (lower(gp.degree) = any (select lower(d) from unnest(e.allowed_degrees) d))) then
    f := array_append(f, 'DEGREE_NOT_ALLOWED');
  end if;
  foreach cert in array e.required_certifications loop
    if not exists (select 1 from public.certifications c
                    where c.graduate_id = p_graduate and lower(c.title) = lower(cert)) then
      f := array_append(f, 'MISSING_CERTIFICATION:' || cert);
    end if;
  end loop;
  return f;
end $$;

create or replace function public.get_my_insights() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := public._require_uid(); gp public.graduate_profiles;
  missing text[] := '{}'; v_skills int; v_total constant int := 9;
begin
  select * into gp from public.graduate_profiles where profile_id = v_uid;
  select count(*) into v_skills from public.graduate_skills where graduate_id = v_uid;
  if gp.college is null then missing := array_append(missing, 'college'); end if;
  if gp.department is null then missing := array_append(missing, 'department'); end if;
  if gp.major is null then missing := array_append(missing, 'major'); end if;
  if gp.graduation_year is null then missing := array_append(missing, 'graduation_year'); end if;
  if gp.degree is null then missing := array_append(missing, 'degree'); end if;
  if gp.location is null then missing := array_append(missing, 'location'); end if;
  if cardinality(gp.career_interests) = 0 then missing := array_append(missing, 'career_interests'); end if;
  if v_skills = 0 then missing := array_append(missing, 'skills'); end if;
  if gp.employment_status = 'NOT_SPECIFIED' then missing := array_append(missing, 'employment_status'); end if;
  return jsonb_build_object(
    'profile_completion', jsonb_build_object(
      'percent', round(100.0 * (v_total - cardinality(missing)) / v_total),
      'missing_fields', to_jsonb(missing)),
    'employment_status', gp.employment_status,
    'skills_count', v_skills,
    'applications', jsonb_build_object(
      'total', (select count(*) from public.applications where graduate_id = v_uid),
      'sample_records', (select count(*) from public.applications where graduate_id = v_uid and status_source = 'SEED_SAMPLE'),
      'by_status', coalesce((select jsonb_object_agg(status, c) from
         (select status, count(*) c from public.applications where graduate_id = v_uid group by status) t), '{}'::jsonb)),
    'events', jsonb_build_object(
      'upcoming', (select count(*) from public.event_registrations r join public.opportunities o on o.id = r.opportunity_id
                    where r.graduate_id = v_uid and r.status in ('REGISTERED','WAITLISTED')
                      and coalesce(o.end_at, o.start_at, o.deadline) >= now()),
      'past', (select count(*) from public.event_registrations r join public.opportunities o on o.id = r.opportunity_id
                where r.graduate_id = v_uid and r.status in ('REGISTERED','WAITLISTED')
                  and coalesce(o.end_at, o.start_at, o.deadline) < now())),
    'saved_opportunities', (select count(*) from public.saved_opportunities where graduate_id = v_uid),
    'recommendations', jsonb_build_object(
      'count', (select count(*) from public._open_recommendations(v_uid)),
      'average_score', (select round(avg(score), 1) from public._open_recommendations(v_uid))),
    'top_skill_gaps', coalesce((select jsonb_agg(jsonb_build_object('skill_id', m, 'count', c)) from
        (select m, count(*) c from public._open_recommendations(v_uid) r
           cross join lateral jsonb_array_elements_text(r.missing_skill_ids) m
          where true group by m order by c desc, m limit 5) g), '[]'::jsonb));
end $$;
