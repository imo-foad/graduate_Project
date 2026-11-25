begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k=p_k $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users(id,aud,role,email,raw_user_meta_data)
  values(v,'authenticated','authenticated',p_key||'@tests.local',jsonb_build_object('full_name',p_key));
  insert into tests.ids values(p_key,v);
  return v;
end
$f$;
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',tests.id(p_key),'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
end
$f$;

do $$
begin
  perform tests.mk_user('a1');
  perform tests.mk_user('a2');
  perform tests.mk_user('a3');
  update public.profiles set avatar_url='https://images.example.test/a1.png' where id=tests.id('a1');
  update public.profiles set avatar_url='https://images.example.test/a2.png' where id=tests.id('a2');
  update public.graduate_profiles set hidden_fields=array['avatar_url'] where profile_id=tests.id('a2');
  update public.profiles set account_status='SUSPENDED' where id=tests.id('a3');
end
$$;

-- Client cannot bypass the RPC projection or forge posts, comments, or likes.
select ok(not has_table_privilege('authenticated','public.social_posts','SELECT'),'authenticated cannot query raw posts');
select ok(not has_table_privilege('authenticated','public.social_posts','INSERT'),'authenticated cannot insert raw posts');
select ok(not has_table_privilege('authenticated','public.social_posts','UPDATE'),'authenticated cannot update raw posts');
select ok(not has_table_privilege('authenticated','public.social_posts','DELETE'),'authenticated cannot delete raw posts');
select ok(not has_table_privilege('authenticated','public.social_post_comments','SELECT'),'authenticated cannot query raw comments');
select ok(not has_table_privilege('authenticated','public.social_post_likes','SELECT'),'authenticated cannot query raw likes');
select ok(not has_table_privilege('anon','public.social_posts','SELECT'),'anon cannot query posts');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind='r' and not c.relrowsecurity),0,'RLS remains enabled on every public table');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef
 and not exists(select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')),0,
 'all SECURITY DEFINER functions pin search_path');

-- A creates a post; B reads only the explicit public identity projection.
select tests.login('a1');
select is((public.create_social_post('  Hello from the alumni network  ')).content,'Hello from the alumni network','post content is trimmed and stored');
reset role;
select tests.login('a2');
select is((select author_name from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),'a1','feed reveals public display name');
select is((select author_avatar_url from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 'https://images.example.test/a1.png','feed reveals permitted avatar only');
select is((select likes_count from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),0::bigint,'new post starts with zero likes');
select is((select comments_count from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),0::bigint,'new post starts with zero comments');
select ok(not (select liked_by_me from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),'unliked feed flag is false');
select is(public.get_social_feed(null,null,1) is null,false,'feed pagination returns a row when one is available');
select is((select count(*)::int from public.get_social_feed(null,null,1)),1,'feed page limit is enforced');
select ok((select count(*)::int from public.get_social_feed(
 (select created_at from public.get_social_feed(null,null,1)),
 (select id from public.get_social_feed(null,null,1)),1)) <= 1,'cursor pagination accepts a complete cursor');
select throws_ok($q$select * from public.get_social_feed(now(),null,20)$q$,'PT422','INVALID_INPUT','partial feed cursor rejected');
select throws_ok($q$select * from public.get_social_feed(null,null,0)$q$,'PT422','INVALID_INPUT','zero feed limit rejected');
select throws_ok($q$select * from public.get_social_feed(null,null,51)$q$,'PT422','INVALID_INPUT','oversized feed limit rejected');
select ok(position('email' in pg_get_function_result('public.get_social_feed(timestamptz,uuid,integer)'::regprocedure))=0,
 'feed RPC result does not expose email or private profile fields');

-- B avatar preference is honored; author name remains the only other display identity field.
select is((public.create_social_post('B post')).content,'B post','second graduate creates own post');
select is((select author_avatar_url from public.get_social_feed(null,null,20) where content='B post'),null,
 'hidden avatar preference suppresses image in feed');

-- Comment ownership, editing, listing and deletion.
select is((public.add_social_comment(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 '  Nice to reconnect  '
)).content,'Nice to reconnect','graduate can comment on an active post');
select is((select author_name from public.get_social_post_comments(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20
)),'a2','comment projection contains display name');
select is((select author_avatar_url from public.get_social_post_comments(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20
)),null,'comment projection honors hidden avatar');
select is((public.update_social_comment(
 (select id from public.get_social_post_comments(
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20)),
 'Updated comment'
)).content,'Updated comment','comment author can edit own comment');
select tests.login('a1');
select throws_ok($q$select public.update_social_comment(
 (select id from public.get_social_post_comments(
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20)), 'Try to edit another user comment')$q$,
 'PT404','SOCIAL_COMMENT_NOT_FOUND','post owner cannot edit someone else comment');
select throws_ok($q$select public.delete_social_comment(
 (select id from public.get_social_post_comments(
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20)))$q$,
 'PT404','SOCIAL_COMMENT_NOT_FOUND','post owner cannot delete someone else comment');
reset role;
select tests.login('a2');
select lives_ok($q$select public.update_social_comment(
 (select id from public.get_social_post_comments(
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20)),repeat('x',2001))$q$,
 'placeholder');
