-- 0018: Social Feed governance, immutable moderation audit and database-enforced abuse budgets.
-- All client content access remains RPC-only. Rate limiting lives in PostgreSQL so direct RPC
-- calls cannot bypass the limits enforced by the Edge Function handlers.

alter table public.social_posts
  add column moderation_status text not null default 'VISIBLE'
    check (moderation_status in ('VISIBLE','HIDDEN','REMOVED')),
  add column moderated_at timestamptz,
  add column moderated_by uuid references auth.users(id) on delete set null,
  add column moderation_reason text;

alter table public.social_post_comments
  add column moderation_status text not null default 'VISIBLE'
    check (moderation_status in ('VISIBLE','HIDDEN','REMOVED')),
  add column moderated_at timestamptz,
  add column moderated_by uuid references auth.users(id) on delete set null,
  add column moderation_reason text;

create index social_posts_visible_feed_idx
  on public.social_posts(created_at desc, id desc)
  where moderation_status = 'VISIBLE';
create index social_comments_visible_post_idx
  on public.social_post_comments(post_id, created_at, id)
  where moderation_status = 'VISIBLE';

-- Only a trusted operator/service role can change rate policies or inspect token buckets.
create table private.rate_limit_policies (
  action text primary key check (action ~ '^[A-Z][A-Z0-9_]{1,63}$'),
  capacity integer not null check (capacity between 1 and 10000),
  refill_per_second numeric(14,8) not null check (refill_per_second > 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
create table private.user_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null references private.rate_limit_policies(action) on delete cascade,
  tokens numeric(14,8) not null check (tokens >= 0),
  last_refill_at timestamptz not null,
  primary key (user_id, action)
);
create index user_rate_limits_refill_idx on private.user_rate_limits(last_refill_at);
alter table private.rate_limit_policies enable row level security;
alter table private.user_rate_limits enable row level security;

insert into private.rate_limit_policies(action, capacity, refill_per_second) values
  ('SOCIAL_POST_CREATE', 5, 5::numeric / 60),
  ('SOCIAL_POST_EDIT', 10, 10::numeric / 60),
  ('SOCIAL_COMMENT_CREATE', 12, 12::numeric / 60),
  ('SOCIAL_COMMENT_EDIT', 20, 20::numeric / 60),
  ('SOCIAL_LIKE', 30, 30::numeric / 60),
  ('SOCIAL_REPORT', 5, 5::numeric / 3600),
  ('CV_PARSE', 5, 5::numeric / 3600),
  ('RECOMMEND', 30, 30::numeric / 60),
  ('RECOMMEND_FORCE', 10, 10::numeric / 3600)
on conflict (action) do update set
  capacity = excluded.capacity,
  refill_per_second = excluded.refill_per_second,
  enabled = true,
  updated_at = now();

revoke all on private.rate_limit_policies, private.user_rate_limits from public, anon, authenticated;
grant select, insert, update, delete on private.rate_limit_policies, private.user_rate_limits to service_role;

create or replace function private.consume_user_rate_limit(p_user_id uuid, p_action text)
returns integer
language plpgsql security definer set search_path = ''
as $consume_user_rate_limit$
declare
  v_policy private.rate_limit_policies;
  v_tokens numeric(14,8);
  v_last_refill timestamptz;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_elapsed numeric(18,8);
  v_retry integer;
begin
  if p_user_id is null or p_action is null then
    raise exception 'INVALID_RATE_LIMIT_SUBJECT' using errcode = 'PT422';
  end if;

  select * into v_policy
    from private.rate_limit_policies
   where action = p_action and enabled;
  if not found then
    raise exception 'RATE_LIMIT_POLICY_NOT_FOUND' using errcode = 'PT500';
  end if;

  -- Serialize a single (user, action) bucket. This closes the parallel-request race.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_user_id::text || ':' || p_action, 0)
  );

  insert into private.user_rate_limits(user_id, action, tokens, last_refill_at)
  values (p_user_id, p_action, v_policy.capacity, v_now)
  on conflict (user_id, action) do nothing;

  select tokens, last_refill_at
    into v_tokens, v_last_refill
    from private.user_rate_limits
   where user_id = p_user_id and action = p_action
   for update;

  v_elapsed := greatest(0, extract(epoch from (v_now - v_last_refill)));
  v_tokens := least(
    v_policy.capacity::numeric,
    v_tokens + v_elapsed * v_policy.refill_per_second
  );

  if v_tokens < 1 then
    v_retry := greatest(1, ceil((1 - v_tokens) / v_policy.refill_per_second)::integer);
    update private.user_rate_limits
       set tokens = v_tokens, last_refill_at = v_now
     where user_id = p_user_id and action = p_action;
    return v_retry;
  end if;

  update private.user_rate_limits
     set tokens = v_tokens - 1, last_refill_at = v_now
   where user_id = p_user_id and action = p_action;
  return 0;
end
$consume_user_rate_limit$;
revoke all on function private.consume_user_rate_limit(uuid, text) from public, anon, authenticated;
grant execute on function private.consume_user_rate_limit(uuid, text) to service_role;

-- Edge Functions use a service-role client only after independently verifying the caller's JWT.
-- The user id is never accepted from an Android/client request.
create or replace function public.consume_edge_rate_limit(p_user_id uuid, p_action text)
returns integer
language plpgsql security definer set search_path = ''
as $consume_edge_rate_limit$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  return private.consume_user_rate_limit(p_user_id, p_action);
end
$consume_edge_rate_limit$;
revoke all on function public.consume_edge_rate_limit(uuid, text) from public, anon, authenticated;
grant execute on function public.consume_edge_rate_limit(uuid, text) to service_role;

-- Trigger enforcement is deliberately below the RPC layer: even a future write RPC must
-- pass the same budget. Trusted service-role maintenance (without an end-user JWT) is exempt.
create or replace function private.enforce_social_content_rate_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $enforce_social_content_rate_limit$
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
    v_action := case when tg_op = 'INSERT' then 'SOCIAL_POST_CREATE' else 'SOCIAL_POST_EDIT' end;
    if new.author_id is distinct from v_uid then
      raise exception 'SOCIAL_AUTHOR_MISMATCH' using errcode = 'PT403';
    end if;
  elsif tg_table_name = 'social_post_comments' then
    v_action := case when tg_op = 'INSERT' then 'SOCIAL_COMMENT_CREATE' else 'SOCIAL_COMMENT_EDIT' end;
    if new.author_id is distinct from v_uid then
      raise exception 'SOCIAL_AUTHOR_MISMATCH' using errcode = 'PT403';
    end if;
  elsif tg_table_name = 'social_post_likes' then
    v_action := 'SOCIAL_LIKE';
    if new.graduate_id is distinct from v_uid then
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
end
$enforce_social_content_rate_limit$;
revoke all on function private.enforce_social_content_rate_limit() from public, anon, authenticated;

create trigger social_posts_rate_limit
  before insert or update of content on public.social_posts
  for each row execute function private.enforce_social_content_rate_limit();
create trigger social_comments_rate_limit
  before insert or update of content on public.social_post_comments
  for each row execute function private.enforce_social_content_rate_limit();
create trigger social_likes_rate_limit
  before insert on public.social_post_likes
  for each row execute function private.enforce_social_content_rate_limit();

-- Reports and the moderation ledger live in the non-exposed private schema. A report keeps
-- target_type/target_id rather than a cascading FK so the audit survives a user's own deletion.
create table private.social_content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  target_type text not null check (target_type in ('POST','COMMENT')),
  target_id uuid not null,
  category text not null check (category in (
    'SPAM','HARASSMENT','HATE_OR_VIOLENCE','THREATS','SCAM','PRIVACY','INAPPROPRIATE','OTHER'
  )),
  details text,
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED','DISMISSED')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  resolution_note text,
  check (details is null or length(details) <= 1000)
);
create unique index social_content_reports_one_open_per_reporter_target
  on private.social_content_reports(reporter_id, target_type, target_id)
  where status = 'OPEN';
create index social_content_reports_queue_idx
  on private.social_content_reports(status, created_at desc);
create index social_content_reports_target_idx
  on private.social_content_reports(target_type, target_id, status);

create table private.social_moderation_events (
  id uuid primary key default gen_random_uuid(),
  report_id uuid references private.social_content_reports(id) on delete set null,
  target_type text not null check (target_type in ('POST','COMMENT')),
  target_id uuid not null,
  target_author_id uuid,
  action text not null check (action in (
    'HIDE','REMOVE','RESTORE','DISMISS_REPORT','RESOLVE_MISSING_TARGET'
  )),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 5 and 1000),
  occurred_at timestamptz not null default now()
);
create index social_moderation_events_target_idx
  on private.social_moderation_events(target_type, target_id, occurred_at desc);

alter table private.social_content_reports enable row level security;
alter table private.social_moderation_events enable row level security;
revoke all on private.social_content_reports, private.social_moderation_events from public, anon, authenticated;
grant select, insert, update, delete on private.social_content_reports, private.social_moderation_events to service_role;

create or replace function private.reject_moderation_audit_mutation()
returns trigger
language plpgsql set search_path = ''
as $reject_moderation_audit_mutation$
begin
  raise exception 'MODERATION_AUDIT_IMMUTABLE' using errcode = 'PT403';
end
$reject_moderation_audit_mutation$;
revoke all on function private.reject_moderation_audit_mutation() from public, anon, authenticated;
create trigger social_moderation_events_immutable
  before update or delete on private.social_moderation_events
  for each row execute function private.reject_moderation_audit_mutation();

-- Return only VISIBLE posts and comments to graduates. Counts also exclude moderated comments.
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
as $get_social_feed$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  if p_limit is null or p_limit < 1 or p_limit > 50
     or ((p_before_created_at is null) is distinct from (p_before_id is null)) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  return query
  select sp.id,
         pr.full_name,
         case when coalesce('avatar_url' = any(gp.hidden_fields), false) then null else pr.avatar_url end,
         sp.content,
         sp.created_at,
         sp.updated_at,
         (select count(*) from public.social_post_likes l where l.post_id = sp.id),
         (select count(*) from public.social_post_comments c
           where c.post_id = sp.id and c.moderation_status = 'VISIBLE'),
         exists (select 1 from public.social_post_likes mine
                 where mine.post_id = sp.id and mine.graduate_id = v_uid)
    from public.social_posts sp
    join public.profiles pr on pr.id = sp.author_id and pr.account_status = 'ACTIVE'
    join public.graduate_profiles gp on gp.profile_id = sp.author_id
   where sp.moderation_status = 'VISIBLE'
     and (p_before_created_at is null
       or (sp.created_at, sp.id) < (p_before_created_at, p_before_id))
   order by sp.created_at desc, sp.id desc
   limit p_limit;
end
$get_social_feed$;

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
as $get_social_post_comments$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  if p_limit is null or p_limit < 1 or p_limit > 50
     or ((p_before_created_at is null) is distinct from (p_before_id is null)) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (
    select 1 from public.social_posts sp
    join public.profiles owner_profile on owner_profile.id = sp.author_id and owner_profile.account_status = 'ACTIVE'
    where sp.id = p_post_id and sp.moderation_status = 'VISIBLE'
  ) then
    raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404';
  end if;

  return query
  select c.id, c.post_id, pr.full_name,
         case when coalesce('avatar_url' = any(gp.hidden_fields), false) then null else pr.avatar_url end,
         c.content, c.created_at, c.updated_at
    from public.social_post_comments c
    join public.profiles pr on pr.id = c.author_id and pr.account_status = 'ACTIVE'
    join public.graduate_profiles gp on gp.profile_id = c.author_id
   where c.post_id = p_post_id
     and c.moderation_status = 'VISIBLE'
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
  perform public._require_active_social_user(v_uid);
  select sp.id into v_post_id
    from public.social_posts sp
    join public.profiles pr on pr.id = sp.author_id and pr.account_status = 'ACTIVE'
   where sp.id = p_post_id and sp.moderation_status = 'VISIBLE'
   for update of sp;
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

create or replace function public.like_social_post(p_post_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $like_social_post$
declare v_uid uuid := public._require_uid(); v_post_id uuid;
begin
  perform public._require_active_social_user(v_uid);
  select sp.id into v_post_id
    from public.social_posts sp
    join public.profiles pr on pr.id = sp.author_id and pr.account_status = 'ACTIVE'
   where sp.id = p_post_id and sp.moderation_status = 'VISIBLE'
   for update of sp;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  begin
    insert into public.social_post_likes(post_id, graduate_id) values (v_post_id, v_uid);
  exception when unique_violation then
    raise exception 'ALREADY_LIKED' using errcode = 'PT409';
  end;
  return true;
end
$like_social_post$;

revoke all on function public.get_social_feed(timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.get_social_post_comments(uuid, timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.add_social_comment(uuid, text) from public, anon, authenticated;
revoke all on function public.like_social_post(uuid) from public, anon, authenticated;
grant execute on function public.get_social_feed(timestamptz, uuid, integer),
  public.get_social_post_comments(uuid, timestamptz, uuid, integer),
  public.add_social_comment(uuid, text),
  public.like_social_post(uuid) to authenticated;

create or replace function public.create_social_content_report(
  p_target_type text,
  p_target_id uuid,
  p_category text,
  p_details text default null
)
returns table (report_id uuid, status text)
language plpgsql security definer set search_path = ''
as $create_social_content_report$
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
    select author_id into v_author from public.social_posts
     where id = p_target_id and moderation_status = 'VISIBLE';
  else
    select author_id into v_author from public.social_post_comments
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
end
$create_social_content_report$;

create or replace function public.get_my_social_reports(p_limit integer default 50)
returns table (
  report_id uuid,
  target_type text,
  status text,
  category text,
  created_at timestamptz,
  reviewed_at timestamptz,
  resolution_note text
)
language plpgsql stable security definer set search_path = ''
as $get_my_social_reports$
declare v_uid uuid := public._require_uid();
begin
  perform public._require_active_social_user(v_uid);
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  return query
  select r.id, r.target_type, r.status, r.category, r.created_at, r.reviewed_at, r.resolution_note
    from private.social_content_reports r
   where r.reporter_id = v_uid
   order by r.created_at desc
   limit p_limit;
end
$get_my_social_reports$;

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
as $get_social_moderation_queue$
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
         coalesce(p.author_id, c.author_id), author.full_name,
         coalesce(p.content, c.content, '[content no longer exists]'),
         coalesce(p.moderation_status, c.moderation_status, 'MISSING')
    from private.social_content_reports r
    left join public.social_posts p on r.target_type = 'POST' and p.id = r.target_id
    left join public.social_post_comments c on r.target_type = 'COMMENT' and c.id = r.target_id
    left join public.profiles reporter on reporter.id = r.reporter_id
    left join public.profiles author on author.id = coalesce(p.author_id, c.author_id)
   where p_status = 'ALL' or r.status = p_status
   order by case when r.status = 'OPEN' then 0 else 1 end, r.created_at asc
   limit p_limit;
end
$get_social_moderation_queue$;

create or replace function public.moderate_social_report(
  p_report_id uuid,
  p_action text,
  p_reason text
)
returns table (report_id uuid, status text, content_moderation_status text)
language plpgsql security definer set search_path = ''
as $moderate_social_report$
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
     returning author_id, moderation_status into v_author, v_content_status;
  else
    update public.social_post_comments
       set moderation_status = case when p_action = 'HIDE' then 'HIDDEN' else 'REMOVED' end,
           moderated_at = now(), moderated_by = v_uid, moderation_reason = btrim(p_reason)
     where id = v_report.target_id
     returning author_id, moderation_status into v_author, v_content_status;
  end if;

  if not found then v_content_status := 'MISSING'; end if;

  insert into private.social_moderation_events(
    report_id, target_type, target_id, target_author_id, action, actor_user_id, reason
  ) values (
    v_report.id, v_report.target_type, v_report.target_id, v_author, p_action, v_uid, btrim(p_reason)
  );

  update private.social_content_reports
     set status = 'RESOLVED', reviewed_at = now(), reviewed_by = v_uid,
         resolution_note = btrim(p_reason)
   where target_type = v_report.target_type and target_id = v_report.target_id and status = 'OPEN';

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
end
$moderate_social_report$;

create or replace function public.restore_social_content(
  p_target_type text,
  p_target_id uuid,
  p_reason text
)
returns boolean
language plpgsql security definer set search_path = ''
as $restore_social_content$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_target_type is null or p_target_type not in ('POST','COMMENT')
     or p_target_id is null
     or p_reason is null or length(btrim(p_reason)) not between 5 and 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  if p_target_type = 'POST' then
    update public.social_posts
       set moderation_status = 'VISIBLE', moderated_at = null, moderated_by = null, moderation_reason = null
     where id = p_target_id and moderation_status <> 'VISIBLE'
     returning author_id into v_author;
  else
    update public.social_post_comments
       set moderation_status = 'VISIBLE', moderated_at = null, moderated_by = null, moderation_reason = null
     where id = p_target_id and moderation_status <> 'VISIBLE'
     returning author_id into v_author;
  end if;
  if not found then
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
end
$restore_social_content$;

create or replace function public.get_social_moderation_history(
  p_target_type text,
  p_target_id uuid,
  p_limit integer default 50
)
returns table (
  event_id uuid,
  action text,
  actor_user_id uuid,
  reason text,
  occurred_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $get_social_moderation_history$
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_target_type is null or p_target_type not in ('POST','COMMENT')
     or p_target_id is null or p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  return query
  select e.id, e.action, e.actor_user_id, e.reason, e.occurred_at
    from private.social_moderation_events e
   where e.target_type = p_target_type and e.target_id = p_target_id
   order by e.occurred_at desc
   limit p_limit;
end
$get_social_moderation_history$;

-- A moderated item cannot be edited by its author while hidden/removed. Otherwise the
-- author could replace the reviewed payload and later have that unreviewed revision restored.
create or replace function public.update_social_post(p_post_id uuid, p_content text)
returns public.social_posts
language plpgsql security definer set search_path = ''
as $update_social_post$
declare v_uid uuid := public._require_uid(); v_content text; v_post public.social_posts;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_post from public.social_posts
   where id = p_post_id and author_id = v_uid and moderation_status = 'VISIBLE'
   for update;
  if not found then raise exception 'SOCIAL_POST_NOT_FOUND' using errcode = 'PT404'; end if;
  v_content := btrim(coalesce(p_content, ''));
  if length(v_content) not between 1 and 5000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.social_posts set content = v_content where id = v_post.id returning * into v_post;
  return v_post;
end
$update_social_post$;

create or replace function public.update_social_comment(p_comment_id uuid, p_content text)
returns public.social_post_comments
language plpgsql security definer set search_path = ''
as $update_social_comment$
declare v_uid uuid := public._require_uid(); v_content text; v_comment public.social_post_comments;
begin
  perform public._require_active_social_user(v_uid);
  select * into v_comment from public.social_post_comments
   where id = p_comment_id and author_id = v_uid and moderation_status = 'VISIBLE'
     and exists (
       select 1 from public.social_posts p
        where p.id = public.social_post_comments.post_id and p.moderation_status = 'VISIBLE'
     )
   for update;
  if not found then raise exception 'SOCIAL_COMMENT_NOT_FOUND' using errcode = 'PT404'; end if;
  v_content := btrim(coalesce(p_content, ''));
  if length(v_content) not between 1 and 2000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.social_post_comments set content = v_content
   where id = v_comment.id returning * into v_comment;
  return v_comment;
end
$update_social_comment$;

revoke all on function public.create_social_content_report(text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.get_my_social_reports(integer) from public, anon, authenticated;
revoke all on function public.get_social_moderation_queue(text, integer) from public, anon, authenticated;
revoke all on function public.moderate_social_report(uuid, text, text) from public, anon, authenticated;
revoke all on function public.restore_social_content(text, uuid, text) from public, anon, authenticated;
revoke all on function public.get_social_moderation_history(text, uuid, integer) from public, anon, authenticated;
grant execute on function public.create_social_content_report(text, uuid, text, text),
  public.get_my_social_reports(integer) to authenticated;
grant execute on function public.get_social_moderation_queue(text, integer),
  public.moderate_social_report(uuid, text, text),
  public.restore_social_content(text, uuid, text),
  public.get_social_moderation_history(text, uuid, integer) to authenticated;

comment on table private.social_content_reports is
  'Private abuse reports. Visible only through caller-scoped report RPCs and platform-admin moderation RPCs.';
comment on table private.social_moderation_events is
  'Append-only audit log of social moderation actions; update and delete are rejected by a trigger.';
comment on function public.consume_edge_rate_limit(uuid, text) is
  'Service-role-only per-user token-bucket enforcement for authenticated Edge Function work.';
