-- 0013: service-only, atomic finalization for uploaded CV parsing.
-- The Edge Function verifies the graduate JWT and uses this RPC only after it has
-- downloaded and parsed that graduate's own private CV object.
create or replace function public.complete_cv_parse(
  p_cv_document_id uuid,
  p_graduate_id uuid,
  p_suggestions jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $complete_cv_parse$
declare
  v_status text;
  v_count integer := 0;
begin
  if p_cv_document_id is null or p_graduate_id is null or p_suggestions is null then
    raise exception 'INVALID_CV_SUGGESTIONS' using errcode = 'PT422';
  end if;
  if jsonb_typeof(p_suggestions) is distinct from 'array' then
    raise exception 'INVALID_CV_SUGGESTIONS' using errcode = 'PT422';
  end if;
  if jsonb_array_length(p_suggestions) > 200 then
    raise exception 'INVALID_CV_SUGGESTIONS' using errcode = 'PT422';
  end if;

  select parse_status into v_status
    from public.cv_documents
   where id = p_cv_document_id and graduate_id = p_graduate_id
   for update;
  if not found then
    raise exception 'CV_NOT_FOUND' using errcode = 'PT404';
  end if;
  if v_status <> 'PROCESSING' then
    raise exception 'CV_NOT_PROCESSING' using errcode = 'PT422';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(p_suggestions) item
     where jsonb_typeof(item) <> 'object'
        or coalesce(item ->> 'skill_id', '') = ''
        or coalesce(item ->> 'matched_term', '') = ''
        or length(item ->> 'matched_term') > 160
  ) then
    raise exception 'INVALID_CV_SUGGESTIONS' using errcode = 'PT422';
  end if;

  if exists (
    select 1
      from jsonb_to_recordset(p_suggestions) as item(skill_id text, matched_term text)
     where not exists (select 1 from public.skills s where s.id = item.skill_id)
  ) then
    raise exception 'CV_SKILL_NOT_FOUND' using errcode = 'PT422';
  end if;

  -- Replacing only PENDING rows makes a retry safe without erasing graduate decisions.
  delete from public.cv_suggestions
   where cv_document_id = p_cv_document_id
     and graduate_id = p_graduate_id
     and status = 'PENDING';

  insert into public.cv_suggestions (graduate_id, cv_document_id, kind, payload, status)
  select p_graduate_id, p_cv_document_id, 'SKILL',
         jsonb_build_object('skill_id', item.skill_id, 'matched_term', item.matched_term),
         'PENDING'
    from (
      select skill_id, min(matched_term) as matched_term
        from jsonb_to_recordset(p_suggestions) as parsed(skill_id text, matched_term text)
       group by skill_id
    ) item;
  get diagnostics v_count = row_count;

  update public.cv_documents
     set parse_status = 'DONE', parsed_at = now(), error_message = null
   where id = p_cv_document_id and graduate_id = p_graduate_id;

  return v_count;
end
$complete_cv_parse$;

revoke all on function public.complete_cv_parse(uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.complete_cv_parse(uuid, uuid, jsonb) to service_role;

comment on function public.complete_cv_parse(uuid, uuid, jsonb) is
  'Service-role only. Atomically replaces pending CV skill suggestions and marks a verified document DONE; never writes graduate_skills.';
