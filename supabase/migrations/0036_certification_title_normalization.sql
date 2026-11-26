-- 0036: recognize equivalent CompTIA certification labels without weakening hard eligibility.
--
-- Opportunity fixtures may require the short label "Security+", while graduate CVs commonly
-- record the full vendor label "CompTIA Security+". Accept only that exact equivalence:
-- case and whitespace are ignored, and a leading "CompTIA" plus separator is optional.
-- Do not use substring/LIKE matching: CompTIA Network+ must never satisfy Security+.

create or replace function private.normalize_certification_title(p_title text)
returns text
language sql immutable parallel safe
set search_path = ''
as $normalize_certification_title$
  select regexp_replace(
    regexp_replace(lower(btrim(coalesce(p_title, ''))), '^comptia[[:space:]:-]+', ''),
    '[[:space:]]+',
    '',
    'g'
  )
$normalize_certification_title$;

revoke all on function private.normalize_certification_title(text)
  from public, anon, authenticated, service_role;

create or replace function public.eligibility_failures(p_graduate uuid, p_opportunity uuid)
returns text[]
language plpgsql stable security definer set search_path = ''
as $eligibility_failures_v2$
declare
  gp public.graduate_profiles;
  e public.opportunity_eligibility;
  f text[] := '{}';
  cert text;
begin
  select * into gp
    from public.graduate_profiles
   where profile_id = p_graduate;

  select * into e
    from public.opportunity_eligibility
   where opportunity_id = p_opportunity;

  if not found then
    return f;
  end if;

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

  foreach cert in array coalesce(e.required_certifications, '{}'::text[]) loop
    if private.normalize_certification_title(cert) = ''
       or not exists (
         select 1
           from public.certifications c
          where c.graduate_id = p_graduate
            and private.normalize_certification_title(c.title) =
                private.normalize_certification_title(cert)
            and private.normalize_certification_title(c.title) <> ''
       ) then
      f := f || ('MISSING_CERTIFICATION:' || cert);
    end if;
  end loop;

  return f;
end
$eligibility_failures_v2$;
