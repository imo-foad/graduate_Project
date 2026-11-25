-- 0017: authenticated Social Feed. Profile privacy is unchanged; the feed projects name + permitted avatar only.

create table public.social_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.graduate_profiles(profile_id) on delete cascade,
  content text not null check (length(btrim(content)) between 1 and 5000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index social_posts_feed_idx on public.social_posts(created_at desc, id desc);
create index social_posts_author_idx on public.social_posts(author_id, created_at desc);

create table public.social_post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.social_posts(id) on delete cascade,
  author_id uuid not null references public.graduate_profiles(profile_id) on delete cascade,
  content text not null check (length(btrim(content)) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index social_post_comments_post_idx on public.social_post_comments(post_id, created_at, id);
create index social_post_comments_author_idx on public.social_post_comments(author_id, created_at desc);

create table public.social_post_likes (
  post_id uuid not null references public.social_posts(id) on delete cascade,
  graduate_id uuid not null references public.graduate_profiles(profile_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, graduate_id)
);
create index social_post_likes_graduate_idx on public.social_post_likes(graduate_id, created_at desc);

create trigger social_posts_updated_at
  before update on public.social_posts for each row execute function public.set_updated_at();
create trigger social_post_comments_updated_at
  before update on public.social_post_comments for each row execute function public.set_updated_at();

alter table public.social_posts enable row level security;
alter table public.social_post_comments enable row level security;
alter table public.social_post_likes enable row level security;

-- No direct table grants or policies. All client access is through the narrow RPC projection below.
revoke all on public.social_posts, public.social_post_comments, public.social_post_likes from public, anon, authenticated;

create or replace function public._require_active_social_user(p_uid uuid)
returns uuid language plpgsql stable security definer set search_path = ''
as $require_active_social_user$
begin
  if p_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'PT401';
  end if;
  if not exists (
    select 1 from public.profiles p where p.id = p_uid and p.account_status = 'ACTIVE'
  ) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = 'PT403';
  end if;
  return p_uid;
end
$require_active_social_user$;
revoke all on function public._require_active_social_user(uuid) from public, anon, authenticated;

create or replace function public.get_social_feed(
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  author_id uuid,
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
as $get_social_feed$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);  if p_limit is null or p_limit < 1 or p_limit > 50
     or ((p_before_created_at is null) is distinct from (p_before_id is null)) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  return query
  select sp.id,
         sp.author_id,
         pr.full_name,
         case when coalesce('avatar_url' = any(gp.hidden_fields), false) then null else pr.avatar_url end,
         sp.content,
         sp.created_at,
         sp.updated_at,
         (select count(*) from public.social_post_likes l where l.post_id = sp.id),
         (select count(*) from public.social_post_comments c where c.post_id = sp.id),
         exists (select 1 from public.social_post_likes mine
                 where mine.post_id = sp.id and mine.graduate_id = v_uid)
    from public.social_posts sp
    join public.profiles pr on pr.id = sp.author_id and pr.account_status = 'ACTIVE'
    join public.graduate_profiles gp on gp.profile_id = sp.author_id
   where p_before_created_at is null
      or (sp.created_at, sp.id) < (p_before_created_at, p_before_id)
   order by sp.created_at desc, sp.id desc
   limit p_limit;
end
$get_social_feed$;

create or replace function public.create_social_post(p_content text)
returns public.social_posts
language plpgsql security definer set search_path = ''
as $create_social_post$
declare v_uid uuid := public._require_uid(); v_content text; v_post public.social_posts;
begin
  perform public._require_active_social_user(v_uid);  v_content := btrim(coalesce(p_content, ''));
  if length(v_content) not between 1 and 5000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.social_posts(author_id, content) values (v_uid, v_content) returning * into v_post;
  return v_post;
end
$create_social_post$;

create or replace function public.update_social_post(p_post_id uuid, p_content text)
returns public.social_posts
language plpgsql security definer set search_path = ''
as $update_social_post$
declare v_uid uuid := public._require_uid(); v_content text; v_post public.social_posts;
begin
  perform public._require_active_social_user(v_uid);  select * into v_post from public.social_posts
   where id = p_post_id and author_id = v_uid for update;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  v_content := btrim(coalesce(p_content, ''));
  if length(v_content) not between 1 and 5000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.social_posts set content = v_content where id = v_post.id returning * into v_post;
  return v_post;
end
$update_social_post$;

create or replace function public.delete_social_post(p_post_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $delete_social_post$
declare v_uid uuid := public._require_uid(); v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);  delete from public.social_posts where id = p_post_id and author_id = v_uid returning id into v_deleted;
  if v_deleted is null then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  return true;
end
$delete_social_post$;

create or replace function public.get_social_post_comments(
  p_post_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  post_id uuid,
  author_id uuid,
  author_name text,
  author_avatar_url text,
  content text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $get_social_post_comments$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);  if p_limit is null or p_limit < 1 or p_limit > 50
     or ((p_before_created_at is null) is distinct from (p_before_id is null)) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (
    select 1 from public.social_posts sp
    join public.profiles owner_profile on owner_profile.id = sp.author_id and owner_profile.account_status = 'ACTIVE'
    where sp.id = p_post_id
  ) then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;

  return query
  select c.id, c.post_id, c.author_id, pr.full_name,
         case when coalesce('avatar_url' = any(gp.hidden_fields), false) then null else pr.avatar_url end,
         c.content, c.created_at, c.updated_at
    from public.social_post_comments c
    join public.profiles pr on pr.id = c.author_id and pr.account_status = 'ACTIVE'
    join public.graduate_profiles gp on gp.profile_id = c.author_id
   where c.post_id = p_post_id
     and (p_before_created_at is null or (c.created_at, c.id) > (p_before_created_at, p_before_id))
   order by c.created_at asc, c.id asc
   limit p_limit;
end
$get_social_post_comments$;

create or replace function public.add_social_comment(p_post_id uuid, p_content text)
returns public.social_post_comments
language plpgsql security definer set search_path = ''
as $add_social_comment$
declare v_uid uuid := public._require_uid(); v_post_id uuid; v_content text; v_comment public.social_post_comments;
begin
  perform public._require_active_social_user(v_uid);  select sp.id into v_post_id
    from public.social_posts sp
    join public.profiles pr on pr.id = sp.author_id and pr.account_status = 'ACTIVE'
   where sp.id = p_post_id for update of sp;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  v_content := btrim(coalesce(p_content, ''));
  if length(v_content) not between 1 and 2000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.social_post_comments(post_id, author_id, content)
  values (v_post_id, v_uid, v_content) returning * into v_comment;
  return v_comment;
end
$add_social_comment$;

create or replace function public.update_social_comment(p_comment_id uuid, p_content text)
returns public.social_post_comments
language plpgsql security definer set search_path = ''
as $update_social_comment$
declare v_uid uuid := public._require_uid(); v_content text; v_comment public.social_post_comments;
begin
  perform public._require_active_social_user(v_uid);  select * into v_comment from public.social_post_comments
   where id = p_comment_id and author_id = v_uid for update;
  if not found then raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404'; end if;
  v_content := btrim(coalesce(p_content, ''));
  if length(v_content) not between 1 and 2000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.social_post_comments set content = v_content where id = v_comment.id returning * into v_comment;
  return v_comment;
end
$update_social_comment$;

create or replace function public.delete_social_comment(p_comment_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $delete_social_comment$
declare v_uid uuid := public._require_uid(); v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);  delete from public.social_post_comments where id = p_comment_id and author_id = v_uid returning id into v_deleted;
  if v_deleted is null then raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404'; end if;
  return true;
end
$delete_social_comment$;

create or replace function public.like_social_post(p_post_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $like_social_post$
declare v_uid uuid := public._require_uid(); v_post_id uuid;
begin
  perform public._require_active_social_user(v_uid);  select sp.id into v_post_id
    from public.social_posts sp
    join public.profiles pr on pr.id = sp.author_id and pr.account_status = 'ACTIVE'
   where sp.id = p_post_id for update of sp;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  begin
    insert into public.social_post_likes(post_id, graduate_id) values (v_post_id, v_uid);
  exception when unique_violation then
    raise exception 'ALREADY_LIKED' using errcode = 'PT409';
  end;
  return true;
end
$like_social_post$;

create or replace function public.unlike_social_post(p_post_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $unlike_social_post$
declare v_uid uuid := public._require_uid(); v_post_id uuid; v_deleted uuid;
begin
  perform public._require_active_social_user(v_uid);  select sp.id into v_post_id
    from public.social_posts sp
    join public.profiles pr on pr.id = sp.author_id and pr.account_status = 'ACTIVE'
   where sp.id = p_post_id for update of sp;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  delete from public.social_post_likes where post_id = v_post_id and graduate_id = v_uid returning post_id into v_deleted;
  if v_deleted is null then raise exception 'NOT_LIKED' using errcode = 'PT404'; end if;
  return true;
end
$unlike_social_post$;

revoke all on function public.get_social_feed(timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.create_social_post(text) from public, anon, authenticated;
revoke all on function public.update_social_post(uuid, text) from public, anon, authenticated;
revoke all on function public.delete_social_post(uuid) from public, anon, authenticated;
revoke all on function public.get_social_post_comments(uuid, timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.add_social_comment(uuid, text) from public, anon, authenticated;
revoke all on function public.update_social_comment(uuid, text) from public, anon, authenticated;
revoke all on function public.delete_social_comment(uuid) from public, anon, authenticated;
revoke all on function public.like_social_post(uuid) from public, anon, authenticated;
revoke all on function public.unlike_social_post(uuid) from public, anon, authenticated;

grant execute on function public.get_social_feed(timestamptz, uuid, integer),
  public.create_social_post(text),
  public.update_social_post(uuid, text),
  public.delete_social_post(uuid),
  public.get_social_post_comments(uuid, timestamptz, uuid, integer),
  public.add_social_comment(uuid, text),
  public.update_social_comment(uuid, text),
  public.delete_social_comment(uuid),
  public.like_social_post(uuid),
  public.unlike_social_post(uuid) to authenticated;

comment on table public.social_posts is
  'Authenticated Social Feed posts. All reads/writes are mediated by owner-scoped RPCs; no profile table is made public.';
comment on table public.social_post_comments is
  'Authenticated Social Feed comments. Authors can only edit/delete their own comments.';
comment on table public.social_post_likes is
  'Private like edges. The feed reveals a count and caller-specific liked_by_me flag, never the liker list.';
