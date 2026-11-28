-- 0044: Social Feed v2 — unified social actors, image posts and first-class shares.
--
-- WHY THIS MIGRATION EXISTS
--   0017 tied social_posts/social_post_comments/social_post_likes to public.graduate_profiles, so a
--   verified STUDENT or FACULTY member needed an artificial graduate profile to publish. 0017 also
--   stored text only: there was no image attachment or share lifecycle.
--
-- WHAT THIS MIGRATION DOES (forward-only; 0017/0018 are untouched)
--   * adds public.social_actors, a server-managed projection of one real platform identity
--     (HUMAN profile or ORGANIZATION company). Clients never create or mutate actors;
--   * attaches an actor and the publishing human to posts/comments/likes while keeping every
--     historical row and the legacy graduate references intact;
--   * adds public.social_post_media plus a private, retryable Storage cleanup ledger;
--   * adds shares as posts that reference the original post (never a copy of its content);
--   * adds v2 RPCs and keeps every legacy 0017/0018 RPC callable with unchanged signatures.
--
-- INSTITUTIONS: this repository has no separate institution account table. Human institutional
-- affiliations live in public.human_identities (STUDENT/GRADUATE/FACULTY), and the only organization
-- identity with a verified membership model is public.companies. Organization actors therefore map to
-- companies only. No second identity system is invented here, and no client-supplied role is trusted.

-- ---------------------------------------------------------------------------------------------------
-- 1. Unified actor model. One actor per real identity, created and maintained by the server only.
-- ---------------------------------------------------------------------------------------------------
create table public.social_actors (
  id uuid primary key default gen_random_uuid(),
  actor_type text not null check (actor_type in ('HUMAN','ORGANIZATION')),
  profile_id uuid references public.profiles(id) on delete cascade,
  company_id uuid references public.companies(id) on delete cascade,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint social_actors_identity_check check (
    (actor_type = 'HUMAN' and profile_id is not null and company_id is null)
    or (actor_type = 'ORGANIZATION' and company_id is not null and profile_id is null)
  )
);
create unique index social_actors_human_key on public.social_actors(profile_id) where profile_id is not null;
create unique index social_actors_company_key on public.social_actors(company_id) where company_id is not null;
alter table public.social_actors enable row level security;
revoke all on public.social_actors from public, anon, authenticated;

create trigger social_actors_updated_at before update on public.social_actors
  for each row execute function public.set_updated_at();

create or replace function private.create_human_social_actor()
returns trigger language plpgsql security definer set search_path = ''
as $create_human_social_actor$
begin
  insert into public.social_actors(actor_type, profile_id)
  values ('HUMAN', new.id)
  on conflict do nothing;
  return new;
end $create_human_social_actor$;
revoke all on function private.create_human_social_actor() from public, anon, authenticated;

create trigger profiles_social_actor after insert on public.profiles
  for each row execute function private.create_human_social_actor();

create or replace function private.create_company_social_actor()
returns trigger language plpgsql security definer set search_path = ''
as $create_company_social_actor$
begin
  insert into public.social_actors(actor_type, company_id)
  values ('ORGANIZATION', new.id)
  on conflict do nothing;
  return new;
end $create_company_social_actor$;
revoke all on function private.create_company_social_actor() from public, anon, authenticated;

create trigger companies_social_actor after insert on public.companies
  for each row execute function private.create_company_social_actor();

-- Historical rows: every existing profile and company receives exactly one actor. No account,
-- graduate profile or identity is created here.
insert into public.social_actors(actor_type, profile_id)
select 'HUMAN', p.id from public.profiles p
on conflict do nothing;
insert into public.social_actors(actor_type, company_id)
select 'ORGANIZATION', c.id from public.companies c
on conflict do nothing;

-- A single read projection for actor display fields. Never exposed to clients: the RPCs below
-- decide which actor fields a caller may see.
create view private.social_actor_cards as
select a.id as actor_id,
       a.actor_type,
       a.is_active,
       a.profile_id,
       a.company_id,
       case when a.actor_type = 'HUMAN' then p.full_name else c.name end as display_name,
       case when a.actor_type = 'HUMAN'
            then case when coalesce('avatar_url' = any(gp.hidden_fields), false) then null else p.avatar_url end
            else null end as avatar_url,
       case when a.actor_type = 'ORGANIZATION' then c.verification_status = 'VERIFIED' else false end as verified,
       coalesce(c.verification_status, 'VERIFIED') as organization_status,
       p.account_status as human_account_status
  from public.social_actors a
  left join public.profiles p on p.id = a.profile_id
  left join public.graduate_profiles gp on gp.profile_id = a.profile_id
  left join public.companies c on c.id = a.company_id;
revoke all on private.social_actor_cards from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 2. Posts, comments and likes gain an actor while keeping their historical graduate reference.
--    author_id stays populated for historical/graduate rows and is NULL for non-graduate humans.
-- ---------------------------------------------------------------------------------------------------
alter table public.social_posts add column actor_id uuid references public.social_actors(id) on delete cascade;
alter table public.social_posts add column author_profile_id uuid references public.profiles(id) on delete cascade;
alter table public.social_posts add column shared_post_id uuid references public.social_posts(id) on delete cascade;
alter table public.social_posts add column edited_at timestamptz;
alter table public.social_posts alter column author_id drop not null;
alter table public.social_posts alter column content drop not null;
alter table public.social_posts drop constraint if exists social_posts_content_check;
alter table public.social_posts add constraint social_posts_content_length_check
  check (content is null or length(btrim(content)) <= 5000);

update public.social_posts sp
   set actor_id = a.id,
       author_profile_id = sp.author_id
  from public.social_actors a
 where a.actor_type = 'HUMAN' and a.profile_id = sp.author_id
   and (sp.actor_id is null or sp.author_profile_id is null);

alter table public.social_posts alter column actor_id set not null;
alter table public.social_posts alter column author_profile_id set not null;
create index social_posts_actor_idx on public.social_posts(actor_id, created_at desc);
create index social_posts_shared_post_idx on public.social_posts(shared_post_id) where shared_post_id is not null;
create unique index social_posts_one_share_per_actor
  on public.social_posts(shared_post_id, actor_id) where shared_post_id is not null;

alter table public.social_post_comments add column actor_id uuid references public.social_actors(id) on delete cascade;
alter table public.social_post_comments add column author_profile_id uuid references public.profiles(id) on delete cascade;
alter table public.social_post_comments alter column author_id drop not null;
update public.social_post_comments c
   set actor_id = a.id,
       author_profile_id = c.author_id
  from public.social_actors a
 where a.actor_type = 'HUMAN' and a.profile_id = c.author_id
   and (c.actor_id is null or c.author_profile_id is null);
alter table public.social_post_comments alter column actor_id set not null;
alter table public.social_post_comments alter column author_profile_id set not null;
create index social_post_comments_actor_idx on public.social_post_comments(actor_id, created_at desc);

alter table public.social_post_likes add column actor_id uuid references public.social_actors(id) on delete cascade;
update public.social_post_likes l
   set actor_id = a.id
  from public.social_actors a
 where a.actor_type = 'HUMAN' and a.profile_id = l.graduate_id
   and l.actor_id is null;
alter table public.social_post_likes alter column actor_id set not null;
-- The legacy primary key includes graduate_id; replace it before relaxing that column.
alter table public.social_post_likes drop constraint if exists social_post_likes_pkey;
alter table public.social_post_likes alter column graduate_id drop not null;
alter table public.social_post_likes add primary key (post_id, actor_id);
create index social_post_likes_actor_idx on public.social_post_likes(actor_id, created_at desc);

-- ---------------------------------------------------------------------------------------------------
-- 3. Image metadata + durable private Storage cleanup ledger.
--    Image bytes never live in PostgreSQL. Uploader (a real human Auth account) and publisher actor
--    are deliberately separate concepts.
-- ---------------------------------------------------------------------------------------------------
create table public.social_post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid references public.social_posts(id) on delete cascade,
  uploader_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid not null references public.social_actors(id) on delete cascade,
  status text not null default 'PENDING' check (status in ('PENDING','ATTACHED','RETIRED')),
  bucket_id text not null default 'social-media' check (bucket_id = 'social-media'),
  storage_path text not null unique check (length(storage_path) between 3 and 512),
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp')),
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  width integer not null check (width between 1 and 8000),
  height integer not null check (height between 1 and 8000),
  alt_text text check (alt_text is null or length(alt_text) <= 500),
  sort_order smallint not null default 0 check (sort_order between 0 and 49),
  created_at timestamptz not null default now(),
  attached_at timestamptz,
  constraint social_post_media_own_namespace check (storage_path like uploader_id::text || '/%'),
  constraint social_post_media_pixel_budget check (width::bigint * height::bigint <= 40000000),
  constraint social_post_media_attachment_state check ((status = 'ATTACHED') = (post_id is not null))
);
create unique index social_post_media_post_order on public.social_post_media(post_id, sort_order) where post_id is not null;
create index social_post_media_post_idx on public.social_post_media(post_id) where status = 'ATTACHED';
create index social_post_media_uploader_idx on public.social_post_media(uploader_id, created_at desc);
alter table public.social_post_media enable row level security;
revoke all on public.social_post_media from public, anon, authenticated;

create table private.social_media_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  media_id uuid,
  bucket_id text not null check (bucket_id = 'social-media'),
  storage_path text not null unique check (length(storage_path) between 3 and 512),
  reason text not null default 'MEDIA_RETIRED'
    check (reason in ('MEDIA_RETIRED','POST_DELETED','POST_REMOVED')),
  status text not null default 'PENDING' check (status in ('PENDING','PROCESSING','DONE','FAILED')),
  attempts integer not null default 0 check (attempts between 0 and 20),
  last_error text,
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index social_media_cleanup_queue_pending_idx
  on private.social_media_cleanup_queue(created_at) where status in ('PENDING','FAILED');
alter table private.social_media_cleanup_queue enable row level security;
revoke all on private.social_media_cleanup_queue from public, anon, authenticated;
grant select, insert, update on private.social_media_cleanup_queue to service_role;

-- Every storage path that ever enters the ledger becomes a permanent tombstone.
create or replace function private.social_media_path_available(p_name text)
returns boolean language sql stable security definer set search_path = ''
as $social_media_path_available$
  select p_name is not null and not exists (
    select 1 from private.social_media_cleanup_queue q where q.storage_path = p_name
  );
$social_media_path_available$;
revoke all on function private.social_media_path_available(text) from public, anon, authenticated;
grant execute on function private.social_media_path_available(text) to authenticated;

create or replace function private.enqueue_social_media_cleanup()
returns trigger language plpgsql security definer set search_path = ''
as $enqueue_social_media_cleanup$
begin
  if tg_op = 'DELETE' then
    insert into private.social_media_cleanup_queue(media_id, bucket_id, storage_path, reason)
    values (old.id, old.bucket_id, old.storage_path, 'POST_DELETED')
    on conflict (storage_path) do nothing;
    return old;
  end if;
  if new.status = 'RETIRED' and old.status <> 'RETIRED' then
    insert into private.social_media_cleanup_queue(media_id, bucket_id, storage_path, reason)
    values (new.id, new.bucket_id, new.storage_path, 'MEDIA_RETIRED')
    on conflict (storage_path) do nothing;
  end if;
  return new;
end $enqueue_social_media_cleanup$;
revoke all on function private.enqueue_social_media_cleanup() from public, anon, authenticated;

create trigger social_post_media_cleanup_queue
  after delete or update of status on public.social_post_media
  for each row execute function private.enqueue_social_media_cleanup();

-- Private bucket (5 MB, raster images only). Objects live under <auth.uid()>/... and are readable
-- directly only by their uploader; every other read goes through the signed-URL Edge Function,
-- which authorizes the target post first.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('social-media', 'social-media', false, 5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists social_media_objects_select on storage.objects;
create policy social_media_objects_select on storage.objects for select to authenticated
  using (bucket_id = 'social-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists social_media_objects_insert on storage.objects;
create policy social_media_objects_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'social-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and private.social_media_path_available(name));
drop policy if exists social_media_objects_delete on storage.objects;
create policy social_media_objects_delete on storage.objects for delete to authenticated
  using (bucket_id = 'social-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
comment on policy social_media_objects_select on storage.objects is
  'Private social-media objects: only the uploader may read the raw object. Other viewers receive short-lived signed URLs from the social-media-url Edge Function after post authorization.';

-- ---------------------------------------------------------------------------------------------------
-- 4. Authorization helpers. Organization authority is evaluated at action time, never cached in a
--    token or accepted from the client.
-- ---------------------------------------------------------------------------------------------------
create or replace function private.require_social_actor(p_uid uuid, p_actor_id uuid, p_capability text)
returns public.social_actors language plpgsql stable security definer set search_path = ''
as $require_social_actor$
declare v_actor public.social_actors; v_company public.companies;
begin
  if p_uid is null then raise exception 'UNAUTHENTICATED' using errcode = 'PT401'; end if;
  if p_actor_id is null then raise exception 'SOCIAL_ACTOR_NOT_FOUND' using errcode = 'PT404'; end if;

  select * into v_actor from public.social_actors where id = p_actor_id;
  if not found then raise exception 'SOCIAL_ACTOR_NOT_FOUND' using errcode = 'PT404'; end if;
  if not v_actor.is_active then raise exception 'SOCIAL_ACTOR_NOT_AUTHORIZED' using errcode = 'PT403'; end if;

  if v_actor.actor_type = 'HUMAN' then
    if v_actor.profile_id is distinct from p_uid then
      raise exception 'SOCIAL_ACTOR_NOT_AUTHORIZED' using errcode = 'PT403';
    end if;
    if not exists (
      select 1 from public.profiles p where p.id = p_uid and p.account_status = 'ACTIVE'
    ) then
      raise exception 'ACCOUNT_UNAVAILABLE' using errcode = 'PT403';
    end if;
    return v_actor;
  end if;

  select * into v_company from public.companies where id = v_actor.company_id;
  if not found then raise exception 'SOCIAL_ACTOR_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_company.verification_status = 'SUSPENDED' then
    raise exception 'ORGANIZATION_SUSPENDED' using errcode = 'PT403';
  end if;
  if v_company.verification_status <> 'VERIFIED' then
    raise exception 'ORGANIZATION_NOT_VERIFIED' using errcode = 'PT403';
  end if;
  if p_capability is not null and p_capability not in ('PUBLISH','MANAGE') then
    raise exception 'SOCIAL_ACTOR_NOT_AUTHORIZED' using errcode = 'PT403';
  end if;
  -- VIEWER is read-only: every publishing/management path requires an active OWNER or RECRUITER.
  if not exists (
    select 1 from public.company_memberships m
     where m.company_id = v_company.id and m.user_id = p_uid and m.is_active
       and m.role in ('OWNER','RECRUITER')
  ) then
    raise exception 'SOCIAL_ACTOR_NOT_AUTHORIZED' using errcode = 'PT403';
  end if;
  return v_actor;
end $require_social_actor$;
revoke all on function private.require_social_actor(uuid, uuid, text) from public, anon, authenticated;

-- Non-disclosing ownership predicate: another user's content is reported as NOT_FOUND, matching the
-- existing 0017 convention instead of revealing that the row exists.
create or replace function private.can_manage_social_actor(p_uid uuid, p_actor_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $can_manage_social_actor$
  select exists (
    select 1 from public.social_actors a
     where a.id = p_actor_id and a.is_active
       and (
         (a.actor_type = 'HUMAN' and a.profile_id = p_uid)
         or (a.actor_type = 'ORGANIZATION' and exists (
           select 1 from public.company_memberships m
            where m.company_id = a.company_id and m.user_id = p_uid and m.is_active
              and m.role in ('OWNER','RECRUITER')
         ))
       )
  );
$can_manage_social_actor$;
revoke all on function private.can_manage_social_actor(uuid, uuid) from public, anon, authenticated;

create or replace function private.require_visible_social_post(p_post_id uuid)
returns public.social_posts language plpgsql stable security definer set search_path = ''
as $require_visible_social_post$
declare v_post public.social_posts;
begin
  if p_post_id is null then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into v_post from public.social_posts
   where id = p_post_id and moderation_status = 'VISIBLE';
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  if not exists (
    select 1 from public.profiles p where p.id = v_post.author_profile_id and p.account_status = 'ACTIVE'
  ) then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;
  if not exists (
    select 1 from private.social_actor_cards ac
     where ac.actor_id = v_post.actor_id and ac.is_active
       and (ac.company_id is null or ac.organization_status = 'VERIFIED')
  ) then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;
  -- A share never outlives the visibility of its original.
  if v_post.shared_post_id is not null and not exists (
    select 1 from public.social_posts o
      join public.profiles op on op.id = o.author_profile_id and op.account_status = 'ACTIVE'
      join private.social_actor_cards oac on oac.actor_id = o.actor_id
     where o.id = v_post.shared_post_id and o.moderation_status = 'VISIBLE'
       and oac.is_active and (oac.company_id is null or oac.organization_status = 'VERIFIED')
  ) then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;
  return v_post;
end $require_visible_social_post$;
revoke all on function private.require_visible_social_post(uuid) from public, anon, authenticated;

create or replace function private.social_post_media_json(p_post_id uuid)
returns jsonb language sql stable set search_path = ''
as $social_post_media_json$
  select coalesce(jsonb_agg(jsonb_build_object(
           'media_id', m.id,
           'storage_path', m.storage_path,
           'mime_type', m.mime_type,
           'size_bytes', m.size_bytes,
           'width', m.width,
           'height', m.height,
           'alt_text', m.alt_text,
           'sort_order', m.sort_order
         ) order by m.sort_order, m.id), '[]'::jsonb)
    from public.social_post_media m
   where m.post_id = p_post_id and m.status = 'ATTACHED';
$social_post_media_json$;
revoke all on function private.social_post_media_json(uuid) from public, anon, authenticated;

create or replace function private.social_post_is_readable(p_post_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $social_post_is_readable$
  select exists (
    select 1
      from public.social_posts sp
      join public.profiles p on p.id = sp.author_profile_id and p.account_status = 'ACTIVE'
      join private.social_actor_cards ac on ac.actor_id = sp.actor_id
     where sp.id = p_post_id
       and sp.moderation_status = 'VISIBLE'
       and ac.is_active
       and (ac.company_id is null or ac.organization_status = 'VERIFIED')
       and (
         sp.shared_post_id is null
         or exists (
           select 1 from public.social_posts o
             join public.profiles op on op.id = o.author_profile_id and op.account_status = 'ACTIVE'
            where o.id = sp.shared_post_id and o.moderation_status = 'VISIBLE'
         )
       )
  );
$social_post_is_readable$;
revoke all on function private.social_post_is_readable(uuid) from public, anon, authenticated;

-- Delivery authorization is evaluated at read time against the post's current state, so a hidden or
-- removed post stops exposing its images even through a previously known object path.
create or replace function private.social_media_object_readable(p_name text)
returns boolean language sql stable security definer set search_path = ''
as $social_media_object_readable$
  select exists (
    select 1
      from public.social_post_media m
     where m.storage_path = p_name
       and m.status = 'ATTACHED'
       and m.post_id is not null
       and private.social_post_is_readable(m.post_id)
  );
$social_media_object_readable$;
revoke all on function private.social_media_object_readable(text) from public, anon, authenticated;
grant execute on function private.social_media_object_readable(text) to authenticated;

drop policy if exists social_media_objects_visible_read on storage.objects;
create policy social_media_objects_visible_read on storage.objects for select to authenticated
  using (bucket_id = 'social-media' and private.social_media_object_readable(name));


-- ---------------------------------------------------------------------------------------------------
-- 5. Feed projection (v2) with media, share attribution and counts. One statement, no N+1 media calls.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.get_social_feed_v2(
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  actor_id uuid,
  actor_type text,
  actor_name text,
  actor_avatar_url text,
  actor_verified boolean,
  content text,
  created_at timestamptz,
  updated_at timestamptz,
  edited_at timestamptz,
  likes_count bigint,
  comments_count bigint,
  shares_count bigint,
  liked_by_me boolean,
  shared_by_me boolean,
  media jsonb,
  shared_post jsonb
)
language plpgsql stable security definer set search_path = ''
as $get_social_feed_v2$
declare v_uid uuid := public._require_uid(); v_actor uuid;
begin
  perform public._require_active_social_user(v_uid);
  if p_limit is null or p_limit < 1 or p_limit > 50
     or ((p_before_created_at is null) is distinct from (p_before_id is null)) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select a.id into v_actor from public.social_actors a
   where a.actor_type = 'HUMAN' and a.profile_id = v_uid;

  return query
  select sp.id, sp.actor_id, ac.actor_type, ac.display_name, ac.avatar_url, ac.verified,
         sp.content, sp.created_at, sp.updated_at, sp.edited_at,
         (select count(*) from public.social_post_likes l where l.post_id = sp.id),
         (select count(*) from public.social_post_comments c
           where c.post_id = sp.id and c.moderation_status = 'VISIBLE'),
         (select count(*) from public.social_posts s
           where s.shared_post_id = sp.id and s.moderation_status = 'VISIBLE'
             and private.social_post_is_readable(s.id)),
         exists (select 1 from public.social_post_likes mine
                  where mine.post_id = sp.id and mine.actor_id = v_actor),
         exists (select 1 from public.social_posts mine_share
                  where mine_share.shared_post_id = sp.id and mine_share.actor_id = v_actor
                    and mine_share.moderation_status = 'VISIBLE'),
         private.social_post_media_json(sp.id),
         case when sp.shared_post_id is null then null else (
           select jsonb_build_object(
             'post_id', o.id,
             'actor_id', o.actor_id,
             'actor_type', oac.actor_type,
             'actor_name', oac.display_name,
             'actor_avatar_url', oac.avatar_url,
             'actor_verified', oac.verified,
             'content', o.content,
             'created_at', o.created_at,
             'media', private.social_post_media_json(o.id)
           )
             from public.social_posts o
             join private.social_actor_cards oac on oac.actor_id = o.actor_id
            where o.id = sp.shared_post_id and o.moderation_status = 'VISIBLE'
         ) end
    from public.social_posts sp
    join private.social_actor_cards ac on ac.actor_id = sp.actor_id
    join public.profiles publisher on publisher.id = sp.author_profile_id and publisher.account_status = 'ACTIVE'
   where sp.moderation_status = 'VISIBLE'
     and ac.is_active
     and (ac.company_id is null or ac.organization_status = 'VERIFIED')
     and private.social_post_is_readable(sp.id)
     and (p_before_created_at is null
       or (sp.created_at, sp.id) < (p_before_created_at, p_before_id))
   order by sp.created_at desc, sp.id desc
   limit p_limit;
end $get_social_feed_v2$;

-- Legacy 0017 signature and projection stay available for existing Android builds.
create or replace function public.get_social_feed(
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  author_name text,
  author_avatar_url text,
  content text,
  created_at timestamptz,
  updated_at timestamptz,
  likes_count bigint,
  comments_count bigint,
  liked_by_me boolean
)
language plpgsql stable security definer set search_path = ''
as $get_social_feed_legacy$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  return query
  select f.id, f.actor_name, f.actor_avatar_url, f.content, f.created_at, f.updated_at,
         f.likes_count, f.comments_count, f.liked_by_me
    from public.get_social_feed_v2(p_before_created_at, p_before_id, p_limit) f;
end $get_social_feed_legacy$;

create or replace function public.get_my_social_actors()
returns table (
  actor_id uuid,
  actor_type text,
  display_name text,
  avatar_url text,
  organization_verified boolean,
  membership_role text,
  can_publish boolean
)
language plpgsql volatile security definer set search_path = ''
as $get_my_social_actors$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  -- Belt and braces for accounts created before the actor trigger existed.
  insert into public.social_actors(actor_type, profile_id)
  values ('HUMAN', v_uid)
  on conflict do nothing;

  return query
  select a.id, a.actor_type, ac.display_name, ac.avatar_url,
         coalesce(ac.verified, false),
         m.role,
         case when a.actor_type = 'HUMAN' then true
              else coalesce(m.is_active and m.role in ('OWNER','RECRUITER')
                            and ac.organization_status = 'VERIFIED', false) end
    from public.social_actors a
    join private.social_actor_cards ac on ac.actor_id = a.id
    left join public.company_memberships m
      on m.company_id = a.company_id and m.user_id = v_uid and m.is_active
   where a.is_active
     and ((a.actor_type = 'HUMAN' and a.profile_id = v_uid)
          or (a.actor_type = 'ORGANIZATION' and m.user_id is not null))
   order by a.actor_type, ac.display_name;
end $get_my_social_actors$;

-- ---------------------------------------------------------------------------------------------------
-- 6. Media registration and authorized delivery.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.register_social_media(
  p_actor_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_size_bytes integer,
  p_width integer,
  p_height integer,
  p_alt_text text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $register_social_media$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
  v_path text := btrim(coalesce(p_storage_path, ''));
  v_object storage.objects;
  v_retry integer;
  v_id uuid;
  v_pending integer;
begin
  perform public._require_active_social_user(v_uid);
  v_actor := private.require_social_actor(v_uid, p_actor_id, 'PUBLISH');

  if p_mime_type is null or p_mime_type not in ('image/jpeg','image/png','image/webp') then
    raise exception 'SOCIAL_MEDIA_INVALID' using errcode = 'PT422';
  end if;
  if p_size_bytes is null or p_size_bytes < 1 then
    raise exception 'SOCIAL_MEDIA_INVALID' using errcode = 'PT422';
  end if;
  if p_size_bytes > 5242880 then
    raise exception 'SOCIAL_MEDIA_TOO_LARGE' using errcode = 'PT422';
  end if;
  if p_width is null or p_height is null or p_width < 1 or p_height < 1
     or p_width > 8000 or p_height > 8000
     or (p_width::bigint * p_height::bigint) > 40000000 then
    raise exception 'SOCIAL_MEDIA_INVALID' using errcode = 'PT422';
  end if;
  if p_alt_text is not null and length(p_alt_text) > 500 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  -- The upload namespace is derived from the authenticated account, never trusted from input.
  if v_path not like v_uid::text || '/%' or length(v_path) > 512 then
    raise exception 'SOCIAL_MEDIA_NOT_OWNED' using errcode = 'PT403';
  end if;
  if private.social_media_path_available(v_path) is not true then
    raise exception 'SOCIAL_MEDIA_RETIRED' using errcode = 'PT409';
  end if;

  select * into v_object from storage.objects o
   where o.bucket_id = 'social-media' and o.name = v_path;
  if not found then raise exception 'SOCIAL_MEDIA_UPLOAD_MISSING' using errcode = 'PT422'; end if;
  -- Compare the declared type/size with what Storage actually recorded.
  if coalesce(v_object.metadata ->> 'mimetype', p_mime_type) <> p_mime_type then
    raise exception 'SOCIAL_MEDIA_INVALID' using errcode = 'PT422';
  end if;
  if coalesce(nullif(v_object.metadata ->> 'size', '')::bigint, p_size_bytes::bigint) <> p_size_bytes::bigint then
    raise exception 'SOCIAL_MEDIA_INVALID' using errcode = 'PT422';
  end if;

  select count(*)::int into v_pending from public.social_post_media
   where uploader_id = v_uid and status = 'PENDING';
  if v_pending >= 20 then
    raise exception 'SOCIAL_MEDIA_LIMIT_EXCEEDED' using errcode = 'PT429';
  end if;

  v_retry := private.consume_user_rate_limit(v_uid, 'SOCIAL_MEDIA_UPLOAD');
  if v_retry > 0 then
    raise exception 'RATE_LIMIT_EXCEEDED'
      using errcode = 'PT429', detail = 'retry_after_seconds=' || v_retry::text;
  end if;

  begin
    insert into public.social_post_media
      (uploader_id, actor_id, bucket_id, storage_path, mime_type, size_bytes, width, height, alt_text)
    values (v_uid, v_actor.id, 'social-media', v_path, p_mime_type, p_size_bytes, p_width, p_height,
            nullif(btrim(coalesce(p_alt_text, '')), ''))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'SOCIAL_MEDIA_ALREADY_REGISTERED' using errcode = 'PT409';
  end;

  return jsonb_build_object(
    'media_id', v_id,
    'status', 'PENDING',
    'bucket_id', 'social-media',
    'mime_type', p_mime_type,
    'size_bytes', p_size_bytes,
    'width', p_width,
    'height', p_height,
    'alt_text', nullif(btrim(coalesce(p_alt_text, '')), '')
  );
end $register_social_media$;

create or replace function public.authorize_social_media(p_media_ids uuid[])
returns table (media_id uuid, storage_path text)
language plpgsql stable security definer set search_path = ''
as $authorize_social_media$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  if p_media_ids is null or cardinality(p_media_ids) < 1 or cardinality(p_media_ids) > 50 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  return query
  select m.id, m.storage_path
    from public.social_post_media m
    join public.social_posts sp on sp.id = m.post_id
    join private.social_actor_cards ac on ac.actor_id = sp.actor_id
   where m.id = any (p_media_ids)
     and m.status = 'ATTACHED'
     and m.post_id is not null
     and sp.moderation_status = 'VISIBLE'
     and ac.is_active
     and (ac.company_id is null or ac.organization_status = 'VERIFIED')
     and private.social_post_is_readable(sp.id);
end $authorize_social_media$;

-- ---------------------------------------------------------------------------------------------------
-- 7. Post creation, editing, deletion, sharing.
-- ---------------------------------------------------------------------------------------------------
create or replace function private.attach_social_post_media(
  p_uid uuid,
  p_post_id uuid,
  p_media_ids uuid[]
)
returns void language plpgsql security definer set search_path = ''
as $attach_social_post_media$
declare
  v_ids uuid[];
  v_id uuid;
  v_media public.social_post_media;
  v_index integer := 0;
  v_total bigint := 0;
begin
  if p_media_ids is null then return; end if;
  select array_agg(x order by ord) into v_ids
    from (select distinct on (value) value as x, ord
            from unnest(p_media_ids) with ordinality as t(value, ord)) d;
  if v_ids is null then return; end if;
  if cardinality(v_ids) > 10 then
    raise exception 'SOCIAL_MEDIA_LIMIT_EXCEEDED' using errcode = 'PT422';
  end if;

  foreach v_id in array v_ids loop
    select * into v_media from public.social_post_media where id = v_id for update;
    if not found then raise exception 'SOCIAL_MEDIA_NOT_OWNED' using errcode = 'PT404'; end if;
    if v_media.uploader_id is distinct from p_uid or v_media.status <> 'PENDING' then
      raise exception 'SOCIAL_MEDIA_NOT_ATTACHABLE' using errcode = 'PT409';
    end if;
    update public.social_post_media
       set post_id = p_post_id, status = 'ATTACHED', sort_order = v_index, attached_at = now()
     where id = v_media.id;
    v_total := v_total + v_media.size_bytes;
    v_index := v_index + 1;
  end loop;

  if v_total > 26214400 then
    raise exception 'SOCIAL_MEDIA_TOO_LARGE' using errcode = 'PT422';
  end if;
end $attach_social_post_media$;
revoke all on function private.attach_social_post_media(uuid, uuid, uuid[]) from public, anon, authenticated;

create or replace function public.create_social_post_v2(
  p_actor_id uuid,
  p_content text default null,
  p_media_ids uuid[] default null,
  p_shared_post_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $create_social_post_v2$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
  v_content text;
  v_original public.social_posts;
  v_post public.social_posts;
  v_share boolean := false;
begin
  perform public._require_active_social_user(v_uid);
  v_actor := private.require_social_actor(v_uid, p_actor_id, 'PUBLISH');

  v_content := nullif(btrim(coalesce(p_content, '')), '');
  if v_content is not null and length(v_content) > 5000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  if p_shared_post_id is not null then
    v_original := private.require_visible_social_post(p_shared_post_id);
    if v_original.shared_post_id is not null then
      raise exception 'SOCIAL_SHARE_NOT_ALLOWED' using errcode = 'PT422';
    end if;
    if v_content is not null and length(v_content) > 1000 then
      raise exception 'INVALID_INPUT' using errcode = 'PT422';
    end if;
    v_share := true;
  end if;

  if v_content is null and coalesce(cardinality(p_media_ids), 0) = 0 and not v_share then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  insert into public.social_posts(actor_id, author_profile_id, author_id, content, shared_post_id)
  values (
    v_actor.id,
    v_uid,
    case when exists (select 1 from public.graduate_profiles g where g.profile_id = v_uid) then v_uid end,
    v_content,
    p_shared_post_id
  )
  returning * into v_post;

  perform private.attach_social_post_media(v_uid, v_post.id, p_media_ids);

  return jsonb_build_object(
    'post_id', v_post.id,
    'actor_id', v_post.actor_id,
    'actor_type', v_actor.actor_type,
    'content', v_post.content,
    'shared_post_id', v_post.shared_post_id,
    'is_share', v_share,
    'created_at', v_post.created_at,
    'media', private.social_post_media_json(v_post.id)
  );
end $create_social_post_v2$;

create or replace function public.create_social_post(p_content text)
returns public.social_posts language plpgsql security definer set search_path = ''
as $create_social_post_legacy$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
  v_content text := nullif(btrim(coalesce(p_content, '')), '');
  v_post public.social_posts;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_actor from public.social_actors
   where actor_type = 'HUMAN' and profile_id = v_uid;
  if not found then raise exception 'SOCIAL_ACTOR_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_content is null or length(v_content) > 5000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.social_posts(actor_id, author_profile_id, author_id, content)
  values (
    v_actor.id,
    v_uid,
    case when exists (select 1 from public.graduate_profiles g where g.profile_id = v_uid) then v_uid end,
    v_content
  )
  returning * into v_post;
  return v_post;
end $create_social_post_legacy$;

create or replace function public.update_social_post_v2(
  p_post_id uuid,
  p_content text default null,
  p_media jsonb default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $update_social_post_v2$
declare
  v_uid uuid := public._require_uid();
  v_post public.social_posts;
  v_actor public.social_actors;
  v_content text;
  v_entry jsonb;
  v_media public.social_post_media;
  v_index integer := 0;
  v_total bigint := 0;
  v_attached integer;
  v_retry integer;
begin
  perform public._require_active_social_user(v_uid);
  v_post := private.require_visible_social_post(p_post_id);
  if private.can_manage_social_actor(v_uid, v_post.actor_id) is not true then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;
  v_actor := private.require_social_actor(v_uid, v_post.actor_id, 'MANAGE');

  if p_content is null then
    v_content := v_post.content;
  else
    v_content := nullif(btrim(p_content), '');
    if v_content is not null and length(v_content) > 5000 then
      raise exception 'INVALID_INPUT' using errcode = 'PT422';
    end if;
  end if;

  if p_media is not null then
    if jsonb_typeof(p_media) <> 'array' or jsonb_array_length(p_media) > 10 then
      raise exception 'INVALID_INPUT' using errcode = 'PT422';
    end if;
  end if;

  select count(*)::int into v_attached from public.social_post_media
   where post_id = v_post.id and status = 'ATTACHED';
  if v_content is null and v_post.shared_post_id is null and coalesce(v_attached, 0) = 0
     and (p_media is null or jsonb_array_length(p_media) = 0) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  -- A media-only edit must still consume the edit budget: the content trigger does not fire then.
  if v_content is not distinct from v_post.content then
    v_retry := private.consume_user_rate_limit(v_uid, 'SOCIAL_POST_EDIT');
    if v_retry > 0 then
      raise exception 'RATE_LIMIT_EXCEEDED'
        using errcode = 'PT429', detail = 'retry_after_seconds=' || v_retry::text;
    end if;
  end if;

  update public.social_posts
     set content = v_content,
         edited_at = case when v_content is distinct from v_post.content then now() else edited_at end
   where id = v_post.id
  returning * into v_post;

  if p_media is not null then
    -- Park current ordering out of the way so the unique (post_id, sort_order) index never collides.
    update public.social_post_media set sort_order = sort_order + 20
     where post_id = v_post.id;
    update public.social_post_media
       set post_id = null, status = 'RETIRED'
     where post_id = v_post.id
       and id not in (
         select (e ->> 'media_id')::uuid from jsonb_array_elements(p_media) e
       );

    for v_entry in select * from jsonb_array_elements(p_media) loop
      if (v_entry ->> 'media_id') is null then
        raise exception 'INVALID_INPUT' using errcode = 'PT422';
      end if;
      select * into v_media from public.social_post_media
       where id = (v_entry ->> 'media_id')::uuid for update;
      if not found then raise exception 'SOCIAL_MEDIA_NOT_OWNED' using errcode = 'PT404'; end if;
      if v_media.status = 'PENDING' then
        if v_media.uploader_id is distinct from v_uid then
          raise exception 'SOCIAL_MEDIA_NOT_OWNED' using errcode = 'PT403';
        end if;
        update public.social_post_media
           set post_id = v_post.id, status = 'ATTACHED', sort_order = v_index,
               alt_text = nullif(btrim(coalesce(v_entry ->> 'alt_text', '')), ''),
               attached_at = now()
         where id = v_media.id;
      elsif v_media.status = 'ATTACHED' and v_media.post_id = v_post.id then
        update public.social_post_media
           set sort_order = v_index,
               alt_text = case when v_entry ? 'alt_text'
                               then nullif(btrim(coalesce(v_entry ->> 'alt_text', '')), '')
                               else alt_text end
         where id = v_media.id;
      else
        raise exception 'SOCIAL_MEDIA_NOT_ATTACHABLE' using errcode = 'PT409';
      end if;
      v_total := v_total + v_media.size_bytes;
      v_index := v_index + 1;
    end loop;

    if v_total > 26214400 then
      raise exception 'SOCIAL_MEDIA_TOO_LARGE' using errcode = 'PT422';
    end if;
  end if;

  return jsonb_build_object(
    'post_id', v_post.id,
    'actor_id', v_post.actor_id,
    'actor_type', v_actor.actor_type,
    'content', v_post.content,
    'edited_at', v_post.edited_at,
    'shared_post_id', v_post.shared_post_id,
    'media', private.social_post_media_json(v_post.id)
  );
end $update_social_post_v2$;

create or replace function public.update_social_post(p_post_id uuid, p_content text)
returns public.social_posts language plpgsql security definer set search_path = ''
as $update_social_post_legacy$
declare
  v_uid uuid := public._require_uid();
  v_post public.social_posts;
  v_actor public.social_actors;
  v_content text := nullif(btrim(coalesce(p_content, '')), '');
begin
  perform public._require_active_social_user(v_uid);
  select * into v_post from public.social_posts
   where id = p_post_id and moderation_status = 'VISIBLE' for update;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into v_actor from public.social_actors where id = v_post.actor_id;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  -- The legacy RPC is personal-only: an organization post is managed through update_social_post_v2.
  if v_actor.actor_type <> 'HUMAN' or v_actor.profile_id is distinct from v_uid then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;
  if v_content is null or length(v_content) > 5000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.social_posts
     set content = v_content,
         edited_at = case when v_content is distinct from v_post.content then now() else edited_at end
   where id = v_post.id
  returning * into v_post;
  return v_post;
end $update_social_post_legacy$;

create or replace function public.delete_social_post(p_post_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $delete_social_post$
declare
  v_uid uuid := public._require_uid();
  v_post public.social_posts;
  v_actor public.social_actors;
  v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_post from public.social_posts where id = p_post_id;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  if private.can_manage_social_actor(v_uid, v_post.actor_id) is not true then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;
  v_actor := private.require_social_actor(v_uid, v_post.actor_id, 'MANAGE');
  delete from public.social_posts where id = v_post.id returning id into v_deleted;
  if v_deleted is null then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  -- Media rows cascade; the delete trigger above queues every Storage object for cleanup.
  return true;
end $delete_social_post$;

create or replace function public.share_social_post(
  p_actor_id uuid,
  p_post_id uuid,
  p_commentary text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $share_social_post$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
  v_original public.social_posts;
  v_content text := nullif(btrim(coalesce(p_commentary, '')), '');
  v_post public.social_posts;
begin
  perform public._require_active_social_user(v_uid);
  v_actor := private.require_social_actor(v_uid, p_actor_id, 'PUBLISH');
  v_original := private.require_visible_social_post(p_post_id);
  if v_original.shared_post_id is not null then
    raise exception 'SOCIAL_SHARE_NOT_ALLOWED' using errcode = 'PT422';
  end if;
  if v_content is not null and length(v_content) > 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  begin
    insert into public.social_posts(actor_id, author_profile_id, author_id, content, shared_post_id)
    values (
      v_actor.id,
      v_uid,
      case when exists (select 1 from public.graduate_profiles g where g.profile_id = v_uid) then v_uid end,
      v_content,
      v_original.id
    )
    returning * into v_post;
  exception when unique_violation then
    raise exception 'ALREADY_SHARED' using errcode = 'PT409';
  end;

  return jsonb_build_object(
    'share_post_id', v_post.id,
    'shared_post_id', v_original.id,
    'actor_id', v_actor.id,
    'actor_type', v_actor.actor_type,
    'created_at', v_post.created_at
  );
end $share_social_post$;

create or replace function public.unshare_social_post(p_share_post_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $unshare_social_post$
declare
  v_uid uuid := public._require_uid();
  v_post public.social_posts;
  v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_post from public.social_posts
   where id = p_share_post_id and shared_post_id is not null;
  if not found then raise exception 'SOCIAL_SHARE_NOT_FOUND' using errcode = 'PT404'; end if;
  if private.can_manage_social_actor(v_uid, v_post.actor_id) is not true then
    raise exception 'SOCIAL_SHARE_NOT_FOUND' using errcode = 'PT404';
  end if;
  perform private.require_social_actor(v_uid, v_post.actor_id, 'MANAGE');
  delete from public.social_posts where id = v_post.id returning id into v_deleted;
  if v_deleted is null then raise exception 'SOCIAL_SHARE_NOT_FOUND' using errcode = 'PT404'; end if;
  return true;
end $unshare_social_post$;

-- ---------------------------------------------------------------------------------------------------
-- 8. Comments and likes for every actor type (legacy wrappers keep their 0017 signatures).
-- ---------------------------------------------------------------------------------------------------
create or replace function public.get_social_post_comments_v2(
  p_post_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  post_id uuid,
  actor_id uuid,
  actor_type text,
  actor_name text,
  actor_avatar_url text,
  actor_verified boolean,
  content text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $get_social_post_comments_v2$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  if p_limit is null or p_limit < 1 or p_limit > 50
     or ((p_before_created_at is null) is distinct from (p_before_id is null)) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if private.social_post_is_readable(p_post_id) is not true then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;
  return query
  select c.id, c.post_id, c.actor_id, ac.actor_type, ac.display_name, ac.avatar_url, ac.verified,
         c.content, c.created_at, c.updated_at
    from public.social_post_comments c
    join private.social_actor_cards ac on ac.actor_id = c.actor_id
    join public.profiles p on p.id = c.author_profile_id and p.account_status = 'ACTIVE'
   where c.post_id = p_post_id
     and c.moderation_status = 'VISIBLE'
     and ac.is_active
     and (p_before_created_at is null or (c.created_at, c.id) > (p_before_created_at, p_before_id))
   order by c.created_at asc, c.id asc
   limit p_limit;
end $get_social_post_comments_v2$;

create or replace function public.get_social_post_comments(
  p_post_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  post_id uuid,
  author_name text,
  author_avatar_url text,
  content text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $get_social_post_comments_legacy$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  return query
  select c.id, c.post_id, c.actor_name, c.actor_avatar_url, c.content, c.created_at, c.updated_at
    from public.get_social_post_comments_v2(p_post_id, p_before_created_at, p_before_id, p_limit) c;
end $get_social_post_comments_legacy$;

create or replace function private.insert_social_comment(
  p_uid uuid,
  p_actor_id uuid,
  p_post_id uuid,
  p_content text
)
returns public.social_post_comments language plpgsql security definer set search_path = ''
as $insert_social_comment$
declare
  v_post public.social_posts;
  v_content text := nullif(btrim(coalesce(p_content, '')), '');
  v_comment public.social_post_comments;
begin
  v_post := private.require_visible_social_post(p_post_id);
  if v_content is null or length(v_content) > 2000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.social_post_comments(post_id, author_id, author_profile_id, actor_id, content)
  values (
    v_post.id,
    case when exists (select 1 from public.graduate_profiles g where g.profile_id = p_uid) then p_uid end,
    p_uid,
    p_actor_id,
    v_content
  )
  returning * into v_comment;
  return v_comment;
end $insert_social_comment$;
revoke all on function private.insert_social_comment(uuid, uuid, uuid, text) from public, anon, authenticated;

create or replace function public.add_social_comment_v2(
  p_post_id uuid,
  p_actor_id uuid,
  p_content text
)
returns jsonb language plpgsql security definer set search_path = ''
as $add_social_comment_v2$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
  v_comment public.social_post_comments;
begin
  perform public._require_active_social_user(v_uid);
  v_actor := private.require_social_actor(v_uid, p_actor_id, 'PUBLISH');
  v_comment := private.insert_social_comment(v_uid, v_actor.id, p_post_id, p_content);
  return jsonb_build_object(
    'comment_id', v_comment.id,
    'post_id', v_comment.post_id,
    'actor_id', v_comment.actor_id,
    'content', v_comment.content,
    'created_at', v_comment.created_at
  );
end $add_social_comment_v2$;

create or replace function public.add_social_comment(p_post_id uuid, p_content text)
returns public.social_post_comments language plpgsql security definer set search_path = ''
as $add_social_comment_legacy$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_actor from public.social_actors
   where actor_type = 'HUMAN' and profile_id = v_uid;
  if not found then raise exception 'SOCIAL_ACTOR_NOT_FOUND' using errcode = 'PT404'; end if;
  return private.insert_social_comment(v_uid, v_actor.id, p_post_id, p_content);
end $add_social_comment_legacy$;

create or replace function public.update_social_comment(p_comment_id uuid, p_content text)
returns public.social_post_comments language plpgsql security definer set search_path = ''
as $update_social_comment$
declare
  v_uid uuid := public._require_uid();
  v_comment public.social_post_comments;
  v_content text := nullif(btrim(coalesce(p_content, '')), '');
begin
  perform public._require_active_social_user(v_uid);
  select * into v_comment from public.social_post_comments
   where id = p_comment_id and author_profile_id = v_uid and moderation_status = 'VISIBLE'
     and private.social_post_is_readable(post_id)
   for update;
  if not found then raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404'; end if;
  perform private.require_social_actor(v_uid, v_comment.actor_id, 'MANAGE');
  if v_content is null or length(v_content) > 2000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.social_post_comments set content = v_content
   where id = v_comment.id returning * into v_comment;
  return v_comment;
end $update_social_comment$;

create or replace function public.update_social_comment_v2(p_comment_id uuid, p_content text)
returns jsonb language plpgsql security definer set search_path = ''
as $update_social_comment_v2$
declare
  v_uid uuid := public._require_uid();
  v_comment public.social_post_comments;
  v_content text := nullif(btrim(coalesce(p_content, '')), '');
begin
  perform public._require_active_social_user(v_uid);
  select * into v_comment from public.social_post_comments
   where id = p_comment_id and moderation_status = 'VISIBLE'
     and private.social_post_is_readable(post_id)
   for update;
  if not found then raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404'; end if;
  if private.can_manage_social_actor(v_uid, v_comment.actor_id) is not true then
    raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404';
  end if;
  perform private.require_social_actor(v_uid, v_comment.actor_id, 'MANAGE');
  if v_content is null or length(v_content) > 2000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.social_post_comments set content = v_content
   where id = v_comment.id returning * into v_comment;
  return jsonb_build_object('comment_id', v_comment.id, 'content', v_comment.content,
                            'edited_at', v_comment.updated_at);
end $update_social_comment_v2$;

create or replace function public.delete_social_comment(p_comment_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $delete_social_comment$
declare
  v_uid uuid := public._require_uid();
  v_comment public.social_post_comments;
  v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_comment from public.social_post_comments where id = p_comment_id;
  if not found then raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404'; end if;
  if private.can_manage_social_actor(v_uid, v_comment.actor_id) is not true then
    raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404';
  end if;
  perform private.require_social_actor(v_uid, v_comment.actor_id, 'MANAGE');
  delete from public.social_post_comments where id = v_comment.id returning id into v_deleted;
  if v_deleted is null then raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404'; end if;
  return true;
end $delete_social_comment$;

create or replace function private.insert_social_like(
  p_uid uuid,
  p_actor_id uuid,
  p_post_id uuid
)
returns boolean language plpgsql security definer set search_path = ''
as $insert_social_like$
declare v_post public.social_posts;
begin
  v_post := private.require_visible_social_post(p_post_id);
  begin
    insert into public.social_post_likes(post_id, actor_id, graduate_id)
    values (
      v_post.id,
      p_actor_id,
      case when exists (select 1 from public.graduate_profiles g where g.profile_id = p_uid) then p_uid end
    );
  exception when unique_violation then
    raise exception 'ALREADY_LIKED' using errcode = 'PT409';
  end;
  return true;
end $insert_social_like$;
revoke all on function private.insert_social_like(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.like_social_post_v2(p_post_id uuid, p_actor_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $like_social_post_v2$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
begin
  perform public._require_active_social_user(v_uid);
  v_actor := private.require_social_actor(v_uid, p_actor_id, 'PUBLISH');
  return private.insert_social_like(v_uid, v_actor.id, p_post_id);
end $like_social_post_v2$;

create or replace function public.like_social_post(p_post_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $like_social_post_legacy$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_actor from public.social_actors
   where actor_type = 'HUMAN' and profile_id = v_uid;
  if not found then raise exception 'SOCIAL_ACTOR_NOT_FOUND' using errcode = 'PT404'; end if;
  return private.insert_social_like(v_uid, v_actor.id, p_post_id);
end $like_social_post_legacy$;

create or replace function public.unlike_social_post_v2(p_post_id uuid, p_actor_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $unlike_social_post_v2$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
  v_post public.social_posts;
  v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);
  v_actor := private.require_social_actor(v_uid, p_actor_id, 'PUBLISH');
  v_post := private.require_visible_social_post(p_post_id);
  delete from public.social_post_likes
   where post_id = v_post.id and actor_id = v_actor.id
  returning post_id into v_deleted;
  if v_deleted is null then raise exception 'NOT_LIKED' using errcode = 'PT404'; end if;
  return true;
end $unlike_social_post_v2$;

create or replace function public.unlike_social_post(p_post_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $unlike_social_post_legacy$
declare
  v_uid uuid := public._require_uid();
  v_actor public.social_actors;
  v_post public.social_posts;
  v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_actor from public.social_actors
   where actor_type = 'HUMAN' and profile_id = v_uid;
  if not found then raise exception 'SOCIAL_ACTOR_NOT_FOUND' using errcode = 'PT404'; end if;
  v_post := private.require_visible_social_post(p_post_id);
  delete from public.social_post_likes
   where post_id = v_post.id and actor_id = v_actor.id
  returning post_id into v_deleted;
  if v_deleted is null then raise exception 'NOT_LIKED' using errcode = 'PT404'; end if;
  return true;
end $unlike_social_post_legacy$;

-- ---------------------------------------------------------------------------------------------------
-- 9. Rate limits: shares and media uploads get their own budget. A share is still an insert into
--    social_posts, so the trigger decides the bucket from shared_post_id and cannot be bypassed.
-- ---------------------------------------------------------------------------------------------------
insert into private.rate_limit_policies(action, capacity, refill_per_second) values
  ('SOCIAL_SHARE', 10, 10::numeric / 60),
  ('SOCIAL_MEDIA_UPLOAD', 30, 30::numeric / 60)
on conflict (action) do update set
  capacity = excluded.capacity,
  refill_per_second = excluded.refill_per_second,
  enabled = true,
  updated_at = now();

create or replace function private.enforce_social_content_rate_limit()
returns trigger language plpgsql security definer set search_path = ''
as $enforce_social_content_rate_limit_v2$
declare
  v_uid uuid;
  v_action text;
  v_retry integer;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return new;
  end if;

  if tg_table_name = 'social_posts' then
    v_action := case
      when tg_op = 'INSERT' then
        case when new.shared_post_id is not null then 'SOCIAL_SHARE' else 'SOCIAL_POST_CREATE' end
      else 'SOCIAL_POST_EDIT'
    end;
    if new.author_profile_id is distinct from v_uid then
      raise exception 'SOCIAL_AUTHOR_MISMATCH' using errcode = 'PT403';
    end if;
  elsif tg_table_name = 'social_post_comments' then
    v_action := case when tg_op = 'INSERT' then 'SOCIAL_COMMENT_CREATE' else 'SOCIAL_COMMENT_EDIT' end;
    if new.author_profile_id is distinct from v_uid then
      raise exception 'SOCIAL_AUTHOR_MISMATCH' using errcode = 'PT403';
    end if;
  elsif tg_table_name = 'social_post_likes' then
    v_action := 'SOCIAL_LIKE';
    if not exists (
      select 1 from public.social_actors a
       where a.id = new.actor_id
         and (a.profile_id = v_uid
              or exists (
                select 1 from public.company_memberships m
                 where m.company_id = a.company_id and m.user_id = v_uid and m.is_active
                   and m.role in ('OWNER','RECRUITER')
              ))
    ) then
      raise exception 'SOCIAL_AUTHOR_MISMATCH' using errcode = 'PT403';
    end if;
  else
    raise exception 'UNSUPPORTED_SOCIAL_RATE_LIMIT_TARGET' using errcode = 'PT500';
  end if;

  v_retry := private.consume_user_rate_limit(v_uid, v_action);
  if v_retry > 0 then
    raise exception 'RATE_LIMIT_EXCEEDED'
      using errcode = 'PT429', detail = 'retry_after_seconds=' || v_retry::text;
  end if;
  return new;
end $enforce_social_content_rate_limit_v2$;

-- ---------------------------------------------------------------------------------------------------
-- 10. Moderation integration: projections use the publishing human; REMOVE retires post media so a
--     removed post can never keep serving its images.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.get_social_moderation_queue(
  p_status text default 'OPEN',
  p_limit integer default 50
)
returns table (
  report_id uuid,
  target_type text,
  target_id uuid,
  category text,
  details text,
  report_status text,
  created_at timestamptz,
  reporter_id uuid,
  reporter_name text,
  target_author_id uuid,
  target_author_name text,
  content text,
  content_moderation_status text
)
language plpgsql stable security definer set search_path = ''
as $get_social_moderation_queue_v2$
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_status is null or p_status not in ('OPEN','RESOLVED','DISMISSED','ALL')
     or p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  return query
  select r.id, r.target_type, r.target_id, r.category, r.details, r.status, r.created_at,
         r.reporter_id, reporter.full_name,
         coalesce(p.author_profile_id, c.author_profile_id),
         author.full_name,
         coalesce(p.content, c.content, '[content no longer exists]'),
         coalesce(p.moderation_status, c.moderation_status, 'MISSING')
    from private.social_content_reports r
    left join public.social_posts p on r.target_type = 'POST' and p.id = r.target_id
    left join public.social_post_comments c on r.target_type = 'COMMENT' and c.id = r.target_id
    left join public.profiles reporter on reporter.id = r.reporter_id
    left join public.profiles author on author.id = coalesce(p.author_profile_id, c.author_profile_id)
   where p_status = 'ALL' or r.status = p_status
   order by case when r.status = 'OPEN' then 0 else 1 end, r.created_at asc
   limit p_limit;
end $get_social_moderation_queue_v2$;

create or replace function public.moderate_social_report(
  p_report_id uuid,
  p_action text,
  p_reason text
)
returns table (report_id uuid, status text, content_moderation_status text)
language plpgsql security definer set search_path = ''
as $moderate_social_report_v2$
declare
  v_uid uuid := auth.uid();
  v_report private.social_content_reports;
  v_author uuid;
  v_content_status text;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_report_id is null or p_action is null or p_action not in ('HIDE','REMOVE','DISMISS')
     or p_reason is null or length(btrim(p_reason)) not between 5 and 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select * into v_report from private.social_content_reports where id = p_report_id;
  if not found then raise exception 'SOCIAL_REPORT_NOT_FOUND' using errcode = 'PT404'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_report.target_type || ':' || v_report.target_id::text, 0)
  );
  select * into v_report from private.social_content_reports
   where id = p_report_id for update;
  if not found then raise exception 'SOCIAL_REPORT_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_report.status <> 'OPEN' then raise exception 'SOCIAL_REPORT_ALREADY_REVIEWED' using errcode = 'PT409'; end if;

  if p_action = 'DISMISS' then
    update private.social_content_reports
       set status = 'DISMISSED', reviewed_at = now(), reviewed_by = v_uid,
           resolution_note = btrim(p_reason)
     where id = v_report.id;
    insert into private.social_moderation_events(
      report_id, target_type, target_id, action, actor_user_id, reason
    ) values (
      v_report.id, v_report.target_type, v_report.target_id, 'DISMISS_REPORT', v_uid, btrim(p_reason)
    );
    return query select v_report.id, 'DISMISSED'::text, 'UNCHANGED'::text;
    return;
  end if;

  if v_report.target_type = 'POST' then
    update public.social_posts
       set moderation_status = case when p_action = 'HIDE' then 'HIDDEN' else 'REMOVED' end,
           moderated_at = now(), moderated_by = v_uid, moderation_reason = btrim(p_reason)
     where id = v_report.target_id
     returning author_profile_id, moderation_status into v_author, v_content_status;
  else
    update public.social_post_comments
       set moderation_status = case when p_action = 'HIDE' then 'HIDDEN' else 'REMOVED' end,
           moderated_at = now(), moderated_by = v_uid, moderation_reason = btrim(p_reason)
     where id = v_report.target_id
     returning author_profile_id, moderation_status into v_author, v_content_status;
  end if;

  v_content_status := coalesce(v_content_status, 'MISSING');

  -- REMOVE is permanent for images: retire them now and queue the Storage cleanup.
  if p_action = 'REMOVE' and v_report.target_type = 'POST' then
    update public.social_post_media m
       set post_id = null, status = 'RETIRED'
     where m.post_id = v_report.target_id and m.status = 'ATTACHED';
  end if;

  insert into private.social_moderation_events(
    report_id, target_type, target_id, target_author_id, action, actor_user_id, reason
  ) values (
    v_report.id, v_report.target_type, v_report.target_id, v_author, p_action, v_uid, btrim(p_reason)
  );

  update private.social_content_reports as reports
     set status = 'RESOLVED', reviewed_at = now(), reviewed_by = v_uid,
         resolution_note = btrim(p_reason)
   where reports.target_type = v_report.target_type
     and reports.target_id = v_report.target_id
     and reports.status = 'OPEN';

  if v_author is not null then
    insert into public.notifications(profile_id, title, body, type, related_entity_id)
    values (
      v_author, 'تم اتخاذ إجراء بخصوص محتوى منشورك',
      case when p_action = 'HIDE' then 'تم إخفاء المحتوى بعد مراجعته لمخالفة إرشادات المجتمع.'
           else 'تمت إزالة المحتوى من الظهور بعد مراجعته لمخالفة إرشادات المجتمع.' end,
      'SOCIAL_CONTENT_MODERATED', v_report.target_id
    );
  end if;

  return query select v_report.id, 'RESOLVED'::text, v_content_status;
end $moderate_social_report_v2$;

create or replace function public.restore_social_content(
  p_target_type text,
  p_target_id uuid,
  p_reason text
)
returns boolean language plpgsql security definer set search_path = ''
as $restore_social_content_v2$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
  v_updated boolean := false;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_target_type is null or p_target_type not in ('POST','COMMENT')
     or p_target_id is null
     or p_reason is null or length(btrim(p_reason)) not between 5 and 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_target_type || ':' || p_target_id::text, 0)
  );

  if p_target_type = 'POST' then
    update public.social_posts
       set moderation_status = 'VISIBLE', moderated_at = null, moderated_by = null, moderation_reason = null
     where id = p_target_id and moderation_status <> 'VISIBLE'
     returning author_profile_id into v_author;
    v_updated := found;
  else
    update public.social_post_comments
       set moderation_status = 'VISIBLE', moderated_at = null, moderated_by = null, moderation_reason = null
     where id = p_target_id and moderation_status <> 'VISIBLE'
     returning author_profile_id into v_author;
    v_updated := found;
  end if;
  if not v_updated then
    if (p_target_type = 'POST' and exists(select 1 from public.social_posts where id = p_target_id))
       or (p_target_type = 'COMMENT' and exists(select 1 from public.social_post_comments where id = p_target_id)) then
      raise exception 'SOCIAL_CONTENT_ALREADY_VISIBLE' using errcode = 'PT409';
    end if;
    raise exception 'SOCIAL_CONTENT_NOT_FOUND' using errcode = 'PT404';
  end if;

  insert into private.social_moderation_events(
    target_type, target_id, target_author_id, action, actor_user_id, reason
  ) values (p_target_type, p_target_id, v_author, 'RESTORE', v_uid, btrim(p_reason));

  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (v_author, 'تمت استعادة المحتوى', 'تمت مراجعة المحتوى واستعادته للظهور في المجتمع.',
          'SOCIAL_CONTENT_RESTORED', p_target_id);
  return true;
end $restore_social_content_v2$;

-- Self-reports are decided by the publishing human, including organization posts.
create or replace function public.create_social_content_report(
  p_target_type text,
  p_target_id uuid,
  p_category text,
  p_details text default null
)
returns table (report_id uuid, status text)
language plpgsql security definer set search_path = ''
as $create_social_content_report_v2$
declare
  v_uid uuid := public._require_uid();
  v_author uuid;
  v_retry integer;
  v_report_id uuid;
begin
  perform public._require_active_social_user(v_uid);
  if p_target_type is null or p_target_type not in ('POST','COMMENT')
     or p_target_id is null
     or p_category is null or p_category not in (
       'SPAM','HARASSMENT','HATE_OR_VIOLENCE','THREATS','SCAM','PRIVACY','INAPPROPRIATE','OTHER'
     )
     or (p_details is not null and length(p_details) > 1000) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  if p_target_type = 'POST' then
    select author_profile_id into v_author from public.social_posts
     where id = p_target_id and moderation_status = 'VISIBLE';
  else
    select author_profile_id into v_author from public.social_post_comments
     where id = p_target_id and moderation_status = 'VISIBLE';
  end if;
  if v_author is null then raise exception 'SOCIAL_CONTENT_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_author = v_uid then raise exception 'CANNOT_REPORT_OWN_CONTENT' using errcode = 'PT422'; end if;

  v_retry := private.consume_user_rate_limit(v_uid, 'SOCIAL_REPORT');
  if v_retry > 0 then
    raise exception 'RATE_LIMIT_EXCEEDED'
      using errcode = 'PT429', detail = 'retry_after_seconds=' || v_retry::text;
  end if;

  begin
    insert into private.social_content_reports(reporter_id, target_type, target_id, category, details)
    values (v_uid, p_target_type, p_target_id, p_category, nullif(btrim(coalesce(p_details,'')), ''))
    returning id into v_report_id;
  exception when unique_violation then
    raise exception 'ALREADY_REPORTED' using errcode = 'PT409';
  end;

  return query select v_report_id, 'OPEN'::text;
end $create_social_content_report_v2$;

-- ---------------------------------------------------------------------------------------------------
-- 11. Durable Storage cleanup worker RPCs (service role only).
-- ---------------------------------------------------------------------------------------------------
create or replace function public.claim_social_media_cleanup(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = ''
as $claim_social_media_cleanup$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
  v_items jsonb;
begin
  update private.social_media_cleanup_queue
     set status = 'FAILED',
         last_error = coalesce(last_error, 'WORKER_LEASE_EXPIRED'),
         claimed_at = null,
         updated_at = now()
   where status = 'PROCESSING'
     and (claimed_at is null or claimed_at < now() - interval '15 minutes');

  with picked as (
    select id from private.social_media_cleanup_queue
     where status in ('PENDING','FAILED') and attempts < 5
     order by created_at
     for update skip locked
     limit v_limit
  ), updated as (
    update private.social_media_cleanup_queue q
       set status = 'PROCESSING', attempts = q.attempts + 1, claimed_at = now(), updated_at = now()
      from picked p
     where q.id = p.id
    returning q.id, q.bucket_id, q.storage_path, q.attempts, q.reason
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id, 'bucket_id', u.bucket_id, 'storage_path', u.storage_path,
    'attempts', u.attempts, 'reason', u.reason) order by u.id), '[]'::jsonb)
  into v_items from updated u;
  return v_items;
end $claim_social_media_cleanup$;

create or replace function public.complete_social_media_cleanup(p_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $complete_social_media_cleanup$
declare v_rows integer;
begin
  update private.social_media_cleanup_queue
     set status = 'DONE', last_error = null, updated_at = now()
   where id = p_id and status = 'PROCESSING';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end $complete_social_media_cleanup$;

create or replace function public.fail_social_media_cleanup(p_id uuid, p_error text)
returns boolean language plpgsql security definer set search_path = ''
as $fail_social_media_cleanup$
declare v_rows integer;
begin
  update private.social_media_cleanup_queue
     set status = 'FAILED',
         last_error = left(coalesce(nullif(btrim(p_error), ''), 'UNKNOWN_CLEANUP_ERROR'), 500),
         claimed_at = null,
         updated_at = now()
   where id = p_id and status = 'PROCESSING';
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end $fail_social_media_cleanup$;

create or replace function public.get_social_media_cleanup_report()
returns jsonb language plpgsql stable security definer set search_path = ''
as $get_social_media_cleanup_report$
begin
  return jsonb_build_object(
    'pending', (select count(*) from private.social_media_cleanup_queue where status = 'PENDING'),
    'processing', (select count(*) from private.social_media_cleanup_queue where status = 'PROCESSING'),
    'failed', (select count(*) from private.social_media_cleanup_queue where status = 'FAILED'),
    'done', (select count(*) from private.social_media_cleanup_queue where status = 'DONE'),
    'exhausted', (select count(*) from private.social_media_cleanup_queue
                   where status = 'FAILED' and attempts >= 5),
    'oldest_pending_at', (select min(created_at) from private.social_media_cleanup_queue
                           where status in ('PENDING','FAILED'))
  );
end $get_social_media_cleanup_report$;

-- ---------------------------------------------------------------------------------------------------
-- 12. Explicit grants: every new client entry point is narrow; the worker RPCs stay service-role only.
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.get_social_feed_v2(timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.get_social_feed(timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.get_my_social_actors() from public, anon, authenticated;
revoke all on function public.register_social_media(uuid, text, text, integer, integer, integer, text) from public, anon, authenticated;
revoke all on function public.authorize_social_media(uuid[]) from public, anon, authenticated;
revoke all on function public.create_social_post_v2(uuid, text, uuid[], uuid) from public, anon, authenticated;
revoke all on function public.create_social_post(text) from public, anon, authenticated;
revoke all on function public.update_social_post_v2(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.update_social_post(uuid, text) from public, anon, authenticated;
revoke all on function public.delete_social_post(uuid) from public, anon, authenticated;
revoke all on function public.share_social_post(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.unshare_social_post(uuid) from public, anon, authenticated;
revoke all on function public.get_social_post_comments_v2(uuid, timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.get_social_post_comments(uuid, timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.add_social_comment_v2(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.add_social_comment(uuid, text) from public, anon, authenticated;
revoke all on function public.update_social_comment_v2(uuid, text) from public, anon, authenticated;
revoke all on function public.update_social_comment(uuid, text) from public, anon, authenticated;
revoke all on function public.delete_social_comment(uuid) from public, anon, authenticated;
revoke all on function public.like_social_post_v2(uuid, uuid) from public, anon, authenticated;
revoke all on function public.like_social_post(uuid) from public, anon, authenticated;
revoke all on function public.unlike_social_post_v2(uuid, uuid) from public, anon, authenticated;
revoke all on function public.unlike_social_post(uuid) from public, anon, authenticated;
revoke all on function public.get_social_moderation_queue(text, integer) from public, anon, authenticated;
revoke all on function public.moderate_social_report(uuid, text, text) from public, anon, authenticated;
revoke all on function public.restore_social_content(text, uuid, text) from public, anon, authenticated;
revoke all on function public.create_social_content_report(text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.claim_social_media_cleanup(integer) from public, anon, authenticated;
revoke all on function public.complete_social_media_cleanup(uuid) from public, anon, authenticated;
revoke all on function public.fail_social_media_cleanup(uuid, text) from public, anon, authenticated;
revoke all on function public.get_social_media_cleanup_report() from public, anon, authenticated;
revoke all on function public.consume_edge_rate_limit(uuid, text) from public, anon, authenticated;

grant execute on function public.get_social_feed_v2(timestamptz, uuid, integer),
  public.get_social_feed(timestamptz, uuid, integer),
  public.get_my_social_actors(),
  public.register_social_media(uuid, text, text, integer, integer, integer, text),
  public.authorize_social_media(uuid[]),
  public.create_social_post_v2(uuid, text, uuid[], uuid),
  public.create_social_post(text),
  public.update_social_post_v2(uuid, text, jsonb),
  public.update_social_post(uuid, text),
  public.delete_social_post(uuid),
  public.share_social_post(uuid, uuid, text),
  public.unshare_social_post(uuid),
  public.get_social_post_comments_v2(uuid, timestamptz, uuid, integer),
  public.get_social_post_comments(uuid, timestamptz, uuid, integer),
  public.add_social_comment_v2(uuid, uuid, text),
  public.add_social_comment(uuid, text),
  public.update_social_comment_v2(uuid, text),
  public.update_social_comment(uuid, text),
  public.delete_social_comment(uuid),
  public.like_social_post_v2(uuid, uuid),
  public.like_social_post(uuid),
  public.unlike_social_post_v2(uuid, uuid),
  public.unlike_social_post(uuid),
  public.get_social_moderation_queue(text, integer),
  public.moderate_social_report(uuid, text, text),
  public.restore_social_content(text, uuid, text),
  public.create_social_content_report(text, uuid, text, text)
  to authenticated;

grant execute on function public.claim_social_media_cleanup(integer),
  public.complete_social_media_cleanup(uuid),
  public.fail_social_media_cleanup(uuid, text),
  public.get_social_media_cleanup_report(),
  public.consume_edge_rate_limit(uuid, text)
  to service_role;

comment on table public.social_actors is
  'Server-managed publishing identities: one HUMAN actor per profile and one ORGANIZATION actor per company. Clients cannot create, modify or grant actors.';
comment on table public.social_post_media is
  'Image metadata for social posts. Bytes live in the private social-media bucket; the uploader is always the authenticated human, the actor is the publisher.';
comment on table private.social_media_cleanup_queue is
  'Durable, retryable cleanup ledger for private social-media Storage objects. Every path is a permanent tombstone. Service-role worker only.';
comment on function public.get_my_social_actors() is
  'Caller-scoped list of publishing identities: the personal human actor plus organizations where the caller holds an active OWNER/RECRUITER membership.';
comment on function public.create_social_post_v2(uuid, text, uuid[], uuid) is
  'Creates a text, image, mixed or shared post as an authorized actor. Empty posts are rejected; media must be the caller own pending uploads.';
comment on function public.share_social_post(uuid, uuid, text) is
  'Creates a share row that references the original visible post. One share per actor per original; ALREADY_SHARED on retry.';
comment on function public.authorize_social_media(uuid[]) is
  'Returns storage paths for media attached to posts the caller may view. Used by the signed-URL Edge Function; never returns inaccessible media.';
