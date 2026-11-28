-- GENERATED from fixtures/university-accounts.json. Local-only; no secrets.
begin;
do $guard$ begin if current_setting('app.synthetic_seed_allowed',true) is distinct from 'local-only' then raise exception 'SYNTHETIC_UNIVERSITY_SEED_REQUIRES_LOCAL_GUARD'; end if; end $guard$;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550100' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550100'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-01'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-01'; end if; end $auth_check$;
update public.profiles set full_name='Alya Nasser (Synthetic Student 01)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550100';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0001','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-01","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550100'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0001','Computer Science','Software Engineering','Software Engineering',1,3.81,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550100'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550101' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550101'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-02'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-02'; end if; end $auth_check$;
update public.profiles set full_name='Yousef Kareem (Synthetic Student 02)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550101';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0002','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-02","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550101'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0002','Computer Science','Software Engineering','Software Engineering',2,3.42,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550101'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550102' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550102'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-03'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-03'; end if; end $auth_check$;
update public.profiles set full_name='Mira Tarek (Synthetic Student 03)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550102';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0003','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-03","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550102'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0003','Computer Science','Software Engineering','Software Engineering',3,2.95,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550102'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550103' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550103'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-04'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-04'; end if; end $auth_check$;
update public.profiles set full_name='Ziad Hany (Synthetic Student 04)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550103';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0004','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-04","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550103'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0004','Computer Science','Software Engineering','Software Engineering',4,3.17,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550103'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550104' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550104'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-05'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-05'; end if; end $auth_check$;
update public.profiles set full_name='Lina Faris (Synthetic Student 05)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550104';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0005','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-05","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550104'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0005','Artificial Intelligence','Artificial Intelligence','Artificial Intelligence',2,3.94,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550104'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550105' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550105'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-06'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-06'; end if; end $auth_check$;
update public.profiles set full_name='Omar Nabil (Synthetic Student 06)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550105';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0006','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-06","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550105'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0006','Artificial Intelligence','Artificial Intelligence','Artificial Intelligence',3,3.56,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550105'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550106' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550106'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-07'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-07'; end if; end $auth_check$;
update public.profiles set full_name='Nour Adham (Synthetic Student 07)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550106';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0007','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-07","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550106'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0007','Artificial Intelligence','Artificial Intelligence','Artificial Intelligence',1,2.74,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550106'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550107' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550107'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-08'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-08'; end if; end $auth_check$;
update public.profiles set full_name='Salma Rami (Synthetic Student 08)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550107';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0008','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-08","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550107'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0008','Data Science','Data Science and Analytics','Data Science and Analytics',4,3.68,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550107'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550108' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550108'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-09'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-09'; end if; end $auth_check$;
update public.profiles set full_name='Adam Sami (Synthetic Student 09)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550108';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0009','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-09","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550108'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0009','Data Science','Data Science and Analytics','Data Science and Analytics',2,3.21,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550108'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550109' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550109'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-10'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-10'; end if; end $auth_check$;
update public.profiles set full_name='Jana Fady (Synthetic Student 10)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550109';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0010','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-10","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550109'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0010','Data Science','Data Science and Analytics','Data Science and Analytics',3,2.48,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550109'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550110' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550110'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-11'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-11'; end if; end $auth_check$;
update public.profiles set full_name='Malek Ashraf (Synthetic Student 11)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550110';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0011','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-11","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550110'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0011','Cybersecurity','Cybersecurity','Cybersecurity',2,3.77,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550110'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550111' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550111'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-12'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-12'; end if; end $auth_check$;
update public.profiles set full_name='Farah Sameh (Synthetic Student 12)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550111';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0012','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-12","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550111'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0012','Cybersecurity','Cybersecurity','Cybersecurity',3,3.06,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550111'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550112' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550112'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-13'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-13'; end if; end $auth_check$;
update public.profiles set full_name='Rayan Wael (Synthetic Student 13)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550112';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0013','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-13","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550112'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0013','Cybersecurity','Cybersecurity','Cybersecurity',1,2.89,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550112'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550113' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550113'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-14'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-14'; end if; end $auth_check$;
update public.profiles set full_name='Hana Karim (Synthetic Student 14)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550113';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0014','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-14","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550113'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0014','Computer Science','Mobile Development','Mobile Development',4,3.63,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550113'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550114' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550114'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-15'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-15'; end if; end $auth_check$;
update public.profiles set full_name='Tamer Fawzi (Synthetic Student 15)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550114';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0015','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-15","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550114'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0015','Computer Science','Mobile Development','Mobile Development',2,3.34,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550114'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550115' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550115'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-16'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-16'; end if; end $auth_check$;
update public.profiles set full_name='Dina Hossam (Synthetic Student 16)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550115';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0016','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-16","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550115'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0016','Computer Science','Mobile Development','Mobile Development',3,2.67,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550115'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550116' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550116'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-17'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-17'; end if; end $auth_check$;
update public.profiles set full_name='Khaled Amr (Synthetic Student 17)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550116';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0017','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-17","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550116'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0017','Computer Networks','Networks and Cloud','Networks and Cloud',1,3.49,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550116'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550117' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550117'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-18'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-18'; end if; end $auth_check$;
update public.profiles set full_name='Mariam Ayman (Synthetic Student 18)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550117';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0018','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-18","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550117'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0018','Computer Networks','Networks and Cloud','Networks and Cloud',4,2.31,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550117'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550118' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550118'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-19'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-19'; end if; end $auth_check$;
update public.profiles set full_name='Seif Ehab (Synthetic Student 19)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550118';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0019','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-19","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550118'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0019','Information Systems','Information Systems','Information Systems',2,3.88,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550118'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550119' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550119'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-student-20'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-student-20'; end if; end $auth_check$;
update public.profiles set full_name='Reem Bassem (Synthetic Student 20)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550119';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT','SYNTH-STU-0020','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-student-20","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550119'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,'SYNTH-STU-0020','Information Systems','Information Systems','Information Systems',3,2.14,4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550119'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550120' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550120'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-01'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-01'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Rami Haddad (Synthetic Faculty 01)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550120';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0001','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-01","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550120'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0001','Computer Science','Distributed Systems','PROFESSOR','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550120'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550121' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550121'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-02'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-02'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Salma Fawzi (Synthetic Faculty 02)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550121';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0002','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-02","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550121'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0002','Artificial Intelligence','Machine Learning','ASSOCIATE_PROFESSOR','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550121'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550122' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550122'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-03'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-03'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Nader Amin (Synthetic Faculty 03)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550122';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0003','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-03","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550122'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0003','Data Science','Statistical Learning','ASSISTANT_PROFESSOR','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550122'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550123' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550123'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-04'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-04'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Hala Mansour (Synthetic Faculty 04)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550123';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0004','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-04","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550123'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0004','Cybersecurity','Network Security','LECTURER','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550123'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550124' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550124'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-05'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-05'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Karim Adel (Synthetic Faculty 05)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550124';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0005','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-05","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550124'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0005','Software Engineering','Software Quality Assurance','ASSISTANT_LECTURER','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550124'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550125' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550125'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-06'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-06'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Dalia Nabil (Synthetic Faculty 06)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550125';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0006','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-06","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550125'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0006','Computer Science','Mobile Application Architecture','LECTURER','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550125'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550126' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550126'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-07'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-07'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Yara Samir (Synthetic Faculty 07)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550126';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0007','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-07","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550126'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0007','Computer Networks','Cloud Infrastructure','ASSOCIATE_PROFESSOR','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550126'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550127' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550127'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-08'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-08'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Tarek Emad (Synthetic Faculty 08)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550127';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0008','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-08","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550127'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0008','Information Systems','Enterprise Information Systems','PROFESSOR','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550127'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550128' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550128'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-09'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-09'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Mariam Fathy (Synthetic Faculty 09)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550128';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0009','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-09","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550128'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0009','Computer Science','Algorithms and Data Structures','TEACHING_ASSISTANT','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550128'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550129' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550129'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-faculty-10'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-faculty-10'; end if; end $auth_check$;
update public.profiles set full_name='Dr. Amr Khalil (Synthetic Faculty 10)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550129';
insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY','SYNTH-FAC-0010','VERIFIED','SYNTHETIC_SEED',
      '{"seed_key":"university-faculty-10","demo_verification":"SIMULATED_LOCAL_ONLY"}'::jsonb,now()
      from public.profiles p where p.phone='+12125550129'
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();
insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,'SYNTH-FAC-0010','Data Science','Data Governance','LECTURER','SYNTHETIC_SEED'
      from public.profiles p where p.phone='+12125550129'
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550130' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550130'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-01'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-01'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 01 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550130';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550130'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550131' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550131'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-02'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-02'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 02 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550131';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550131'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550132' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550132'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-03'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-03'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 03 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550132';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550132'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550133' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550133'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-04'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-04'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 04 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550133';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550133'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550134' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550134'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-05'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-05'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 05 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550134';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550134'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550135' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550135'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-06'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-06'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 06 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550135';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550135'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550136' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550136'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-07'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-07'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 07 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550136';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550136'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550137' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550137'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-08'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-08'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 08 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550137';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550137'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550138' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550138'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-09'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-09'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 09 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550138';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550138'
      on conflict(user_id) do update set is_active=true;
do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone='+12125550139' and p.email is null
      and private.normalize_auth_phone(a.phone)='+12125550139'
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = 'university-admin-10'
  ) then raise exception 'SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: university-admin-10'; end if; end $auth_check$;
update public.profiles set full_name='Demo University Administrator 10 (Synthetic)', account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone='+12125550139';
insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone='+12125550139'
      on conflict(user_id) do update set is_active=true;
do $role_guard$ begin
    if exists(select 1 from public.profiles p join public.graduate_profiles gp on gp.profile_id=p.id where p.phone between '+12125550100' and '+12125550139')
      then raise exception 'SYNTHETIC_STUDENT_FACULTY_ADMIN_MUST_NOT_HAVE_GRADUATE_PROFILE'; end if;
    if exists(select 1 from public.human_identities h join public.profiles p on p.id=h.profile_id
      where p.phone between '+12125550100' and '+12125550139' and h.identity_type='GRADUATE')
      then raise exception 'SYNTHETIC_COHORT_MUST_NOT_HAVE_GRADUATE_IDENTITY'; end if;
  end $role_guard$;
commit;
