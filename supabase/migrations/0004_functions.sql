-- 0004: business-rule RPCs. Identity always comes from auth.uid(), never from client input.
-- Error convention: RAISE EXCEPTION '<CODE>' USING ERRCODE='PTnnn' => PostgREST returns HTTP nnn,
-- body.message = <CODE>, body.details = optional extra info.

create or replace function public._require_uid() returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'UNAUTHENTICATED' using errcode = 'PT401'; end if;
  return v;
end $$;

-- Hard eligibility (BR-017). Returns the list of failed requirements; empty = eligible.
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
    f := f || 'GRADUATION_YEAR_TOO_EARLY';
  end if;
  if e.max_graduation_year is not null
     and (gp.graduation_year is null or gp.graduation_year > e.max_graduation_year) then
    f := f || 'GRADUATION_YEAR_TOO_LATE';
  end if;
  if cardinality(e.allowed_degrees) > 0
     and (gp.degree is null
          or not (lower(gp.degree) = any (select lower(d) from unnest(e.allowed_degrees) d))) then
    f := f || 'DEGREE_NOT_ALLOWED';
  end if;
  foreach cert in array e.required_certifications loop
    if not exists (select 1 from public.certifications c
                    where c.graduate_id = p_graduate and lower(c.title) = lower(cert)) then
      f := f || ('MISSING_CERTIFICATION:' || cert);
    end if;
  end loop;
  return f;
end $$;

create or replace function public.get_opportunity_eligibility(p_opportunity_id uuid)
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := public._require_uid();
begin
  if not exists (select 1 from public.opportunities where id = p_opportunity_id) then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  return public.eligibility_failures(v_uid, p_opportunity_id);
end $$;

create or replace function public.apply_for_job(
  p_opportunity_id uuid, p_cv_document_id uuid default null, p_note text default null)
returns public.applications language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities; f text[]; app public.applications;
begin
  select * into o from public.opportunities where id = p_opportunity_id;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  -- ASSUMPTION A2: source pseudo-code (7.1) allows type JOB only; INTERNSHIP is not appliable.
  if o.type <> 'JOB' then raise exception 'NOT_A_JOB' using errcode = 'PT422'; end if;
  if o.status <> 'ACTIVE' or (o.deadline is not null and o.deadline < now()) then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  if p_cv_document_id is not null and not exists (
       select 1 from public.cv_documents where id = p_cv_document_id and graduate_id = v_uid) then
    raise exception 'CV_NOT_FOUND' using errcode = 'PT404';
  end if;
  begin
    insert into public.applications (opportunity_id, graduate_id, cv_document_id, note)
    values (o.id, v_uid, p_cv_document_id, p_note) returning * into app;
  exception when unique_violation then
    raise exception 'ALREADY_APPLIED' using errcode = 'PT409';
  end;
  insert into public.application_status_history (application_id, old_status, new_status, source_type)
  values (app.id, null, 'SUBMITTED', 'APP_ACTION');
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم تقديم طلبك',
          'تم إنشاء طلب التقديم على «' || o.title || '» (بيانات تجريبية، لا يوجد قرار توظيف حقيقي).',
          'APPLICATION_SUBMITTED', app.id);
  return app;
end $$;

create or replace function public.withdraw_application(p_application_id uuid)
returns public.applications language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public._require_uid(); app public.applications;
begin
  select * into app from public.applications
   where id = p_application_id and graduate_id = v_uid for update;
  if not found then raise exception 'APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if app.status <> 'SUBMITTED' then raise exception 'CANNOT_WITHDRAW' using errcode = 'PT422'; end if;
  update public.applications set status = 'WITHDRAWN' where id = app.id returning * into app;
  insert into public.application_status_history (application_id, old_status, new_status, source_type)
  values (app.id, 'SUBMITTED', 'WITHDRAWN', 'APP_ACTION');
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم سحب الطلب', 'تم سحب طلب التقديم الخاص بك.', 'APPLICATION_WITHDRAWN', app.id);
  return app;
end $$;

create or replace function public.register_for_event(p_opportunity_id uuid)
returns public.event_registrations language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities; r public.event_registrations; f text[]; v_status text;
begin
  -- Row lock serialises concurrent registrations so capacity cannot be exceeded (BR-013).
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  -- ASSUMPTION A3: TRAINING is registrable too (source 4.2 scenario registers in a training;
  -- pseudo-code 7.2 lists only EVENT/CONFERENCE/VOLUNTEER). Flagged conflict.
  if o.type not in ('EVENT','CONFERENCE','VOLUNTEER','TRAINING') then
    raise exception 'NOT_REGISTRABLE' using errcode = 'PT422';
  end if;
  if o.status <> 'ACTIVE'
     or (o.registration_opens_at is not null and o.registration_opens_at > now())
     or (o.deadline is not null and o.deadline < now())
     or (o.deadline is null and o.end_at is not null and o.end_at < now()) then
    raise exception 'REGISTRATION_CLOSED' using errcode = 'PT422';
  end if;
  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  select * into r from public.event_registrations
   where graduate_id = v_uid and opportunity_id = o.id;
  if found and r.status <> 'CANCELLED' then
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
  if found then -- ASSUMPTION A4: re-registering after a cancellation reuses the same row.
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
               then 'تم تسجيلك في «' || o.title || '» (فعالية تجريبية).'
               else 'الفعالية «' || o.title || '» مكتملة العدد؛ تمت إضافتك إلى قائمة الانتظار.' end,
          'EVENT_REGISTERED', r.id);
  return r;
end $$;

create or replace function public.cancel_event_registration(p_opportunity_id uuid)
returns public.event_registrations language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities; r public.event_registrations;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into r from public.event_registrations
   where graduate_id = v_uid and opportunity_id = o.id for update;
  if not found then raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if r.status = 'CANCELLED' then raise exception 'ALREADY_CANCELLED' using errcode = 'PT409'; end if;
  if r.status = 'REGISTERED' then
    update public.opportunities set registered_count = greatest(registered_count - 1, 0) where id = o.id;
  end if;
  update public.event_registrations set status = 'CANCELLED' where id = r.id returning * into r;
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم إلغاء التسجيل', 'تم إلغاء تسجيلك في «' || o.title || '».', 'EVENT_CANCELLED', r.id);
  return r;
end $$;

-- Replaces the current job atomically: close the old record, insert the new one (7.3, BR-014).
create or replace function public.set_current_job(
  p_company_name text, p_job_title text, p_start_date date,
  p_field text default null, p_description text default null)
returns public.career_history language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := public._require_uid(); cur public.career_history; nw public.career_history;
begin
  if btrim(coalesce(p_company_name, '')) = '' or btrim(coalesce(p_job_title, '')) = ''
     or p_start_date is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  perform 1 from public.graduate_profiles where profile_id = v_uid for update;
  select * into cur from public.career_history where graduate_id = v_uid and is_current;
  if found then
    if p_start_date < cur.start_date then
      raise exception 'START_BEFORE_PREVIOUS' using errcode = 'PT422';
    end if;
    update public.career_history set end_date = p_start_date, is_current = false where id = cur.id;
  end if;
  insert into public.career_history
    (graduate_id, company_name, job_title, field, description, start_date, is_current, source)
  values (v_uid, btrim(p_company_name), btrim(p_job_title), p_field, p_description, p_start_date, true, 'SELF_REPORTED')
  returning * into nw;
  update public.graduate_profiles set employment_status = 'EMPLOYED' where profile_id = v_uid;
  return nw;
end $$;

-- Graduate reviews CV suggestions; only confirmed ones become real skills (BR-015).
-- ASSUMPTION A5: confirmed skill without a stated level is stored at level 1 (editable later).
create or replace function public.confirm_cv_suggestions(p_confirm uuid[], p_reject uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public._require_uid(); s public.cv_suggestions; n_ok int := 0; n_rej int := 0;
begin
  for s in select * from public.cv_suggestions
            where graduate_id = v_uid and status = 'PENDING' and id = any (coalesce(p_confirm, '{}'))
            for update loop
    if s.kind = 'SKILL' and exists (select 1 from public.skills where id = s.payload ->> 'skill_id') then
      insert into public.graduate_skills (graduate_id, skill_id, level, source)
      values (v_uid, s.payload ->> 'skill_id', coalesce((s.payload ->> 'level')::smallint, 1), 'CV_CONFIRMED')
      on conflict (graduate_id, skill_id) do nothing;
      update public.cv_suggestions set status = 'CONFIRMED', decided_at = now() where id = s.id;
      n_ok := n_ok + 1;
    end if;
  end loop;
  update public.cv_suggestions set status = 'REJECTED', decided_at = now()
   where graduate_id = v_uid and status = 'PENDING' and id = any (coalesce(p_reject, '{}'));
  get diagnostics n_rej = row_count;
  return jsonb_build_object('confirmed', n_ok, 'rejected', n_rej);
end $$;

-- Personal insights: strictly the caller's own data (no cross-graduate analytics).
-- ASSUMPTION A6: profile completion = 9 equally weighted items.
create or replace function public.get_my_insights() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := public._require_uid(); gp public.graduate_profiles;
  missing text[] := '{}'; v_skills int; v_total constant int := 9;
begin
  select * into gp from public.graduate_profiles where profile_id = v_uid;
  select count(*) into v_skills from public.graduate_skills where graduate_id = v_uid;
  if gp.college is null then missing := missing || 'college'; end if;
  if gp.department is null then missing := missing || 'department'; end if;
  if gp.major is null then missing := missing || 'major'; end if;
  if gp.graduation_year is null then missing := missing || 'graduation_year'; end if;
  if gp.degree is null then missing := missing || 'degree'; end if;
  if gp.location is null then missing := missing || 'location'; end if;
  if cardinality(gp.career_interests) = 0 then missing := missing || 'career_interests'; end if;
  if v_skills = 0 then missing := missing || 'skills'; end if;
  if gp.employment_status = 'NOT_SPECIFIED' then missing := missing || 'employment_status'; end if;
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
      'count', (select count(*) from public.recommendations where graduate_id = v_uid),
      'average_score', (select round(avg(score), 1) from public.recommendations where graduate_id = v_uid)),
    'top_skill_gaps', coalesce((select jsonb_agg(jsonb_build_object('skill_id', m, 'count', c)) from
        (select m, count(*) c from public.recommendations r
           cross join lateral jsonb_array_elements_text(r.missing_skill_ids) m
          where r.graduate_id = v_uid group by m order by c desc, m limit 5) g), '[]'::jsonb));
end $$;

-- Skill gaps -> learning opportunities. ASSUMPTION A7: for TRAINING/EVENT rows,
-- opportunity_skills lists the skills the opportunity develops.
create or replace function public.get_skill_gaps() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := public._require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'skill_id', g.m, 'canonical_name', sk.canonical_name, 'recommendations_count', g.c,
      'learning_opportunities', coalesce((
        select jsonb_agg(jsonb_build_object('opportunity_id', o.id, 'type', o.type, 'title', o.title) order by os.importance desc, o.title)
        from public.opportunity_skills os join public.opportunities o on o.id = os.opportunity_id
        where os.skill_id = g.m and o.type in ('TRAINING','EVENT','CONFERENCE')
          and o.status = 'ACTIVE' and (o.deadline is null or o.deadline >= now())
          and (o.end_at is null or o.end_at >= now())), '[]'::jsonb)) order by g.c desc, g.m)
    from (select m, count(*) c from public.recommendations r
            cross join lateral jsonb_array_elements_text(r.missing_skill_ids) m
           where r.graduate_id = v_uid group by m) g
    join public.skills sk on sk.id = g.m), '[]'::jsonb);
end $$;

-- ===== service-role only (called by the `recommend` Edge Function after it verifies the JWT) =====
create or replace function public.get_recommendation_candidates(p_graduate_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
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
      where o.status = 'ACTIVE' and (o.deadline is null or o.deadline >= now())
        and (o.end_at is null or o.end_at >= now())), '[]'::jsonb));
$$;

-- Replaces the graduate's cached recommendations with freshly computed ones (stale rows removed).
create or replace function public.save_recommendations(p_graduate_id uuid, p_items jsonb, p_model_version text)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if jsonb_typeof(p_items) <> 'array' then raise exception 'INVALID_ITEMS' using errcode = 'PT422'; end if;
  delete from public.recommendations
   where graduate_id = p_graduate_id
     and opportunity_id not in (select (i ->> 'opportunity_id')::uuid from jsonb_array_elements(p_items) i);
  insert into public.recommendations (graduate_id, opportunity_id, score, band, score_breakdown, reasons,
                                      explanation_ar, matched_skill_ids, missing_skill_ids, gaps,
                                      model_version, generated_at)
  select p_graduate_id, (i ->> 'opportunity_id')::uuid, (i ->> 'score')::numeric, i ->> 'band',
         coalesce(i -> 'score_breakdown', '{}'), coalesce(i -> 'reasons', '[]'), i ->> 'explanation_ar',
         coalesce(i -> 'matched_skill_ids', '[]'), coalesce(i -> 'missing_skill_ids', '[]'),
         coalesce(i -> 'gaps', '[]'), p_model_version, now()
    from jsonb_array_elements(p_items) i
  on conflict (graduate_id, opportunity_id) do update set
    score = excluded.score, band = excluded.band, score_breakdown = excluded.score_breakdown,
    reasons = excluded.reasons, explanation_ar = excluded.explanation_ar,
    matched_skill_ids = excluded.matched_skill_ids, missing_skill_ids = excluded.missing_skill_ids,
    gaps = excluded.gaps, model_version = excluded.model_version, generated_at = excluded.generated_at;
  get diagnostics n = row_count;
  update public.graduate_profiles set recommendations_dirty = false where profile_id = p_graduate_id;
  return n;
end $$;
