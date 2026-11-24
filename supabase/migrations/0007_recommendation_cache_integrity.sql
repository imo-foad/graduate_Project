-- 0007: recommendation cache integrity.
-- B1 save_recommendations used to DELETE before validating (unknown opportunity ids were silently dropped by a JOIN,
--    wiping the cache and then clearing recommendations_dirty).  Now: validate everything first, then lock, then write.
-- B2 stale-snapshot race: the cache could be marked fresh with results computed from an OLDER profile.
--    Now graduate_profiles.profile_version is bumped ONLY by real input changes (never by cache-flag updates); the candidates
--    RPC returns the version it read, and save_recommendations re-checks it inside PostgreSQL under a row lock.

alter table public.graduate_profiles add column if not exists profile_version bigint not null default 0;

-- Real input changes bump the version; flipping recommendations_dirty (or writing the version itself) never does.
create or replace function public.graduate_profile_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.college, new.department, new.major, new.graduation_year, new.degree, new.location,
      new.career_interests, new.work_preferences)
     is distinct from
     (old.college, old.department, old.major, old.graduation_year, old.degree, old.location,
      old.career_interests, old.work_preferences)
  then
    new.profile_version := old.profile_version + 1;
    new.recommendations_dirty := true;
    new.profile_updated_at := now();
  elsif (new.employment_status, new.hidden_fields) is distinct from (old.employment_status, old.hidden_fields) then
    new.profile_updated_at := now();
  end if;
  return new;
end $$;

-- skills / certifications / career_history changes (child tables) bump the version too.
create or replace function public.mark_recommendations_dirty() returns trigger
language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  if tg_op = 'DELETE' then gid := old.graduate_id; else gid := new.graduate_id; end if;
  update public.graduate_profiles
     set recommendations_dirty = true, profile_version = profile_version + 1, profile_updated_at = now()
   where profile_id = gid;
  return null;
end $$;

create or replace function public.get_recommendation_candidates(p_graduate_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'profile_version', (select gp0.profile_version from public.graduate_profiles gp0 where gp0.profile_id = p_graduate_id),
    'profile', (select jsonb_build_object(
        'major', gp.major, 'department', gp.department, 'degree', gp.degree,
        'graduation_year', gp.graduation_year, 'location', gp.location,
        'career_interests', to_jsonb(gp.career_interests), 'work_preferences', gp.work_preferences,
        'experience_years', coalesce((select round(sum((coalesce(c.end_date, current_date) - c.start_date) / 365.25), 2)
                                        from public.career_history c where c.graduate_id = gp.profile_id), 0))
      from public.graduate_profiles gp where gp.profile_id = p_graduate_id),
    'skills', coalesce((select jsonb_agg(jsonb_build_object('skill_id', skill_id, 'level', level))
                          from public.graduate_skills where graduate_id = p_graduate_id), '[]'::jsonb),
    'opportunities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'type', o.type, 'title', o.title, 'company_name', o.company_name,
        'description', o.description, 'location', o.location, 'attendance_mode', o.attendance_mode,
        'target_fields', to_jsonb(o.target_fields),
        'experience_level', jd.experience_level, 'minimum_qualification', jd.minimum_qualification,
        'target_audience', ed.target_audience,
        'skills', coalesce((select jsonb_agg(jsonb_build_object('skill_id', os.skill_id, 'importance', os.importance,
                                   'min_level', os.minimum_level, 'is_required', os.is_required))
                              from public.opportunity_skills os where os.opportunity_id = o.id), '[]'::jsonb),
        'eligibility_failures', to_jsonb(public.eligibility_failures(p_graduate_id, o.id))))
      from public.opportunities o
      left join public.job_details jd on jd.opportunity_id = o.id
      left join public.event_details ed on ed.opportunity_id = o.id
      where public.is_opportunity_open(o.status, o.deadline, o.end_at)), '[]'::jsonb));
$$;

-- The old 3-argument overload has no version check: remove it so it can never be called.
drop function if exists public.save_recommendations(uuid, jsonb, text);

-- Returns the number of rows stored. Error codes: INVALID_ITEMS (422), GRADUATE_NOT_FOUND (404),
-- STALE_SNAPSHOT (409, retry with fresh candidates), OPPORTUNITY_UNAVAILABLE (409, retry with fresh candidates).
-- An EMPTY array is valid ("nothing eligible for this snapshot") and clears the graduate's cache; NULL is invalid.
create or replace function public.save_recommendations(
  p_graduate_id uuid, p_items jsonb, p_model_version text, p_profile_version bigint)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  n integer; v_cur bigint; v_bad bigint;
  c_uuid constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  -- 1. payload validation: reads/writes nothing, so a rejected payload cannot change state
  if p_graduate_id is null or p_items is null or p_profile_version is null
     or btrim(coalesce(p_model_version, '')) = '' then
    raise exception 'INVALID_ITEMS' using errcode = 'PT422', detail = 'null argument';
  end if;
  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'INVALID_ITEMS' using errcode = 'PT422', detail = 'payload must be a JSON array';
  end if;
  select min(t.ord) into v_bad
    from jsonb_array_elements(p_items) with ordinality as t(i, ord)
   where jsonb_typeof(t.i) <> 'object'
      or jsonb_typeof(t.i -> 'opportunity_id') is distinct from 'string'
      or coalesce((t.i ->> 'opportunity_id') !~ c_uuid, true)
      or jsonb_typeof(t.i -> 'score') is distinct from 'number'
      or coalesce(case when jsonb_typeof(t.i -> 'score') = 'number'
                       then not ((t.i ->> 'score')::numeric between 0 and 100) end, true)
      or jsonb_typeof(t.i -> 'band') is distinct from 'string'
      or (t.i ->> 'band') is distinct from
         (case when jsonb_typeof(t.i -> 'score') = 'number' then
            case when (t.i ->> 'score')::numeric >= 80 then 'HIGH'
                 when (t.i ->> 'score')::numeric >= 65 then 'GOOD'
                 when (t.i ->> 'score')::numeric >= 50 then 'MEDIUM' else 'LOW' end end)
      or (t.i ? 'score_breakdown' and jsonb_typeof(t.i -> 'score_breakdown') <> 'object')
      or (t.i ? 'explanation_ar' and jsonb_typeof(t.i -> 'explanation_ar') <> 'string')
      or (t.i ? 'reasons' and jsonb_typeof(t.i -> 'reasons') <> 'array')
      or (t.i ? 'gaps' and jsonb_typeof(t.i -> 'gaps') <> 'array')
      or (t.i ? 'matched_skill_ids' and jsonb_typeof(t.i -> 'matched_skill_ids') <> 'array')
      or (t.i ? 'missing_skill_ids' and jsonb_typeof(t.i -> 'missing_skill_ids') <> 'array')
      or (case when jsonb_typeof(t.i -> 'matched_skill_ids') = 'array' then exists (
            select 1 from jsonb_array_elements(t.i -> 'matched_skill_ids') e where jsonb_typeof(e) <> 'string') else false end)
      or (case when jsonb_typeof(t.i -> 'missing_skill_ids') = 'array' then exists (
            select 1 from jsonb_array_elements(t.i -> 'missing_skill_ids') e where jsonb_typeof(e) <> 'string') else false end);
  if v_bad is not null then
    raise exception 'INVALID_ITEMS' using errcode = 'PT422', detail = 'invalid item #' || v_bad;
  end if;

  -- 2. serialise writers, lock the profile row (concurrent profile edits wait for us) and compare snapshot versions
  perform pg_advisory_xact_lock(hashtextextended('recommendations:' || p_graduate_id::text, 0));
  select gp.profile_version into v_cur from public.graduate_profiles gp
   where gp.profile_id = p_graduate_id for update;
  if not found then raise exception 'GRADUATE_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_cur <> p_profile_version then
    raise exception 'STALE_SNAPSHOT' using errcode = 'PT409',
      detail = 'current=' || v_cur || ' snapshot=' || p_profile_version;
  end if;

  -- 3. every referenced opportunity must exist and still be open (still no writes)
  select min(t.ord) into v_bad from jsonb_array_elements(p_items) with ordinality as t(i, ord)
   where not exists (select 1 from public.opportunities o where o.id = (t.i ->> 'opportunity_id')::uuid);
  if v_bad is not null then
    raise exception 'INVALID_ITEMS' using errcode = 'PT422', detail = 'unknown opportunity at item #' || v_bad;
  end if;
  select min(t.ord) into v_bad from jsonb_array_elements(p_items) with ordinality as t(i, ord)
    join public.opportunities o on o.id = (t.i ->> 'opportunity_id')::uuid
   where not public.is_opportunity_open(o.status, o.deadline, o.end_at);
  if v_bad is not null then
    raise exception 'OPPORTUNITY_UNAVAILABLE' using errcode = 'PT409', detail = 'closed or expired at item #' || v_bad;
  end if;

  -- 4. only now touch the cache. Duplicate opportunity ids: highest score wins, then first in the payload.
  delete from public.recommendations d
   where d.graduate_id = p_graduate_id
     and not exists (select 1 from jsonb_array_elements(p_items) i
                      where (i ->> 'opportunity_id')::uuid = d.opportunity_id);
  insert into public.recommendations (graduate_id, opportunity_id, score, band, score_breakdown, reasons,
                                      explanation_ar, matched_skill_ids, missing_skill_ids, gaps,
                                      model_version, generated_at)
  select distinct on (s.opp_id) p_graduate_id, s.opp_id, (s.i ->> 'score')::numeric, s.i ->> 'band',
         coalesce(s.i -> 'score_breakdown', '{}'), coalesce(s.i -> 'reasons', '[]'), s.i ->> 'explanation_ar',
         coalesce(s.i -> 'matched_skill_ids', '[]'), coalesce(s.i -> 'missing_skill_ids', '[]'),
         coalesce(s.i -> 'gaps', '[]'), p_model_version, now()
    from (select (t.i ->> 'opportunity_id')::uuid as opp_id, t.i, t.ord
            from jsonb_array_elements(p_items) with ordinality as t(i, ord)) s
   order by s.opp_id, (s.i ->> 'score')::numeric desc, s.ord
  on conflict (graduate_id, opportunity_id) do update set
    score = excluded.score, band = excluded.band, score_breakdown = excluded.score_breakdown,
    reasons = excluded.reasons, explanation_ar = excluded.explanation_ar,
    matched_skill_ids = excluded.matched_skill_ids, missing_skill_ids = excluded.missing_skill_ids,
    gaps = excluded.gaps, model_version = excluded.model_version, generated_at = excluded.generated_at;
  get diagnostics n = row_count;

  -- 5. fresh only because the version matched while we held the lock
  update public.graduate_profiles set recommendations_dirty = false where profile_id = p_graduate_id;
  return n;
end $$;
revoke all on function public.save_recommendations(uuid, jsonb, text, bigint) from public, anon, authenticated;
grant execute on function public.save_recommendations(uuid, jsonb, text, bigint) to service_role;
