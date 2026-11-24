-- 0005: grants, RLS policies, private CV bucket. Default = deny; only what is listed is allowed.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- ---- table privileges (authenticated only; anon gets nothing) ----
grant select on public.profiles, public.graduate_profiles, public.skills, public.graduate_skills,
  public.career_history, public.projects, public.certifications, public.cv_documents, public.cv_suggestions,
  public.opportunities, public.job_details, public.event_details, public.opportunity_skills,
  public.opportunity_eligibility, public.saved_opportunities, public.applications,
  public.application_status_history, public.event_registrations, public.recommendations,
  public.notifications to authenticated;
grant update (full_name, avatar_url) on public.profiles to authenticated;
grant update (college, department, major, graduation_year, degree, employment_status, location,
              career_interests, work_preferences, hidden_fields) on public.graduate_profiles to authenticated;
grant insert (graduate_id, skill_id, level, years_experience, source) on public.graduate_skills to authenticated;
grant update (level, years_experience) on public.graduate_skills to authenticated;
grant delete on public.graduate_skills to authenticated;
-- past records only: is_current is not insertable/updatable directly (use set_current_job)
grant insert (graduate_id, company_name, job_title, field, description, start_date, end_date) on public.career_history to authenticated;
grant update (company_name, job_title, field, description, start_date, end_date) on public.career_history to authenticated;
grant insert, update, delete on public.projects, public.certifications to authenticated;
grant insert (graduate_id, storage_path, file_type, size_bytes) on public.cv_documents to authenticated;
grant update (is_active) on public.cv_documents to authenticated;
grant delete on public.cv_documents to authenticated;
grant insert (graduate_id, opportunity_id), delete on public.saved_opportunities to authenticated;
grant update (is_read) on public.notifications to authenticated;

-- ---- RLS ----
alter table public.profiles enable row level security;
alter table public.graduate_profiles enable row level security;
alter table public.skills enable row level security;
alter table public.graduate_skills enable row level security;
alter table public.career_history enable row level security;
alter table public.projects enable row level security;
alter table public.certifications enable row level security;
alter table public.cv_documents enable row level security;
alter table public.cv_suggestions enable row level security;
alter table public.opportunities enable row level security;
alter table public.job_details enable row level security;
alter table public.event_details enable row level security;
alter table public.opportunity_skills enable row level security;
alter table public.opportunity_eligibility enable row level security;
alter table public.saved_opportunities enable row level security;
alter table public.applications enable row level security;
alter table public.application_status_history enable row level security;
alter table public.event_registrations enable row level security;
alter table public.recommendations enable row level security;
alter table public.notifications enable row level security;

create policy profiles_select on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy gp_select on public.graduate_profiles for select to authenticated using (profile_id = (select auth.uid()));
create policy gp_update on public.graduate_profiles for update to authenticated
  using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));

create policy skills_select on public.skills for select to authenticated using (true);

create policy gs_select on public.graduate_skills for select to authenticated using (graduate_id = (select auth.uid()));
create policy gs_insert on public.graduate_skills for insert to authenticated
  with check (graduate_id = (select auth.uid()) and source = 'MANUAL');
create policy gs_update on public.graduate_skills for update to authenticated
  using (graduate_id = (select auth.uid())) with check (graduate_id = (select auth.uid()));
create policy gs_delete on public.graduate_skills for delete to authenticated using (graduate_id = (select auth.uid()));

create policy ch_select on public.career_history for select to authenticated using (graduate_id = (select auth.uid()));
create policy ch_insert on public.career_history for insert to authenticated
  with check (graduate_id = (select auth.uid()) and source = 'SELF_REPORTED');
create policy ch_update on public.career_history for update to authenticated
  using (graduate_id = (select auth.uid()) and source in ('SELF_REPORTED','CV_CONFIRMED'))
  with check (graduate_id = (select auth.uid()));
-- no delete policy: history is preserved (7.3)

create policy projects_all on public.projects for all to authenticated
  using (graduate_id = (select auth.uid())) with check (graduate_id = (select auth.uid()));
create policy certs_all on public.certifications for all to authenticated
  using (graduate_id = (select auth.uid())) with check (graduate_id = (select auth.uid()));

create policy cv_select on public.cv_documents for select to authenticated using (graduate_id = (select auth.uid()));
create policy cv_insert on public.cv_documents for insert to authenticated
  with check (graduate_id = (select auth.uid()) and storage_path like (select auth.uid())::text || '/%');
create policy cv_update on public.cv_documents for update to authenticated
  using (graduate_id = (select auth.uid())) with check (graduate_id = (select auth.uid()));
create policy cv_delete on public.cv_documents for delete to authenticated using (graduate_id = (select auth.uid()));
create policy cvs_select on public.cv_suggestions for select to authenticated using (graduate_id = (select auth.uid()));

-- Catalogue: read-only. Visible when open (BR-005) or when the graduate already interacted with it.
create policy opp_select on public.opportunities for select to authenticated using (
  (status = 'ACTIVE' and (deadline is null or deadline >= now()) and (end_at is null or end_at >= now()))
  or exists (select 1 from public.applications a where a.opportunity_id = opportunities.id and a.graduate_id = (select auth.uid()))
  or exists (select 1 from public.event_registrations r where r.opportunity_id = opportunities.id and r.graduate_id = (select auth.uid()))
  or exists (select 1 from public.saved_opportunities s where s.opportunity_id = opportunities.id and s.graduate_id = (select auth.uid())));
create policy jd_select on public.job_details for select to authenticated
  using (exists (select 1 from public.opportunities o where o.id = opportunity_id));
create policy ed_select on public.event_details for select to authenticated
  using (exists (select 1 from public.opportunities o where o.id = opportunity_id));
create policy os_select on public.opportunity_skills for select to authenticated
  using (exists (select 1 from public.opportunities o where o.id = opportunity_id));
create policy oe_select on public.opportunity_eligibility for select to authenticated
  using (exists (select 1 from public.opportunities o where o.id = opportunity_id));

create policy saved_select on public.saved_opportunities for select to authenticated using (graduate_id = (select auth.uid()));
create policy saved_insert on public.saved_opportunities for insert to authenticated with check (
  graduate_id = (select auth.uid()) and exists (select 1 from public.opportunities o where o.id = opportunity_id));
create policy saved_delete on public.saved_opportunities for delete to authenticated using (graduate_id = (select auth.uid()));

create policy app_select on public.applications for select to authenticated using (graduate_id = (select auth.uid()));
create policy ash_select on public.application_status_history for select to authenticated using (
  exists (select 1 from public.applications a where a.id = application_id and a.graduate_id = (select auth.uid())));
create policy reg_select on public.event_registrations for select to authenticated using (graduate_id = (select auth.uid()));
-- BR / 6.9: closed or expired opportunities disappear from recommendations immediately, even if cached.
create policy rec_select on public.recommendations for select to authenticated using (
  graduate_id = (select auth.uid()) and exists (select 1 from public.opportunities o
    where o.id = opportunity_id and o.status = 'ACTIVE' and (o.deadline is null or o.deadline >= now())
      and (o.end_at is null or o.end_at >= now())));
create policy notif_select on public.notifications for select to authenticated using (profile_id = (select auth.uid()));
create policy notif_update on public.notifications for update to authenticated
  using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));

-- ---- RPC execution rights ----
grant execute on function public.get_opportunity_eligibility(uuid), public.apply_for_job(uuid, uuid, text),
  public.withdraw_application(uuid), public.register_for_event(uuid), public.cancel_event_registration(uuid),
  public.set_current_job(text, text, date, text, text), public.confirm_cv_suggestions(uuid[], uuid[]),
  public.get_my_insights(), public.get_skill_gaps() to authenticated;
-- internal / service-role only (never callable by a client-supplied graduate id)
grant execute on function public.get_recommendation_candidates(uuid), public.save_recommendations(uuid, jsonb, text),
  public.eligibility_failures(uuid, uuid) to service_role;

-- ---- private CV bucket (5 MB, pdf/docx only; objects live under <auth.uid()>/...) ----
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cv-documents', 'cv-documents', false, 5242880,
        array['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
create policy cv_objects_select on storage.objects for select to authenticated
  using (bucket_id = 'cv-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy cv_objects_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'cv-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy cv_objects_delete on storage.objects for delete to authenticated
  using (bucket_id = 'cv-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
