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
  update public.profiles set avatar_url='https://images.example.test/a3.png' where id=tests.id('a3');
  update public.graduate_profiles set hidden_fields=array['avatar_url'] where profile_id=tests.id('a2');
end
$$;

-- No raw PostgREST table access is granted.
select ok(not has_table_privilege('authenticated','public.social_posts','SELECT'),'authenticated cannot query raw posts');
select ok(not has_table_privilege('authenticated','public.social_posts','INSERT'),'authenticated cannot insert raw posts');
select ok(not has_table_privilege('authenticated','public.social_posts','UPDATE'),'authenticated cannot update raw posts');
select ok(not has_table_privilege('authenticated','public.social_posts','DELETE'),'authenticated cannot delete raw posts');
select ok(not has_table_privilege('authenticated','public.social_post_comments','SELECT'),'authenticated cannot query raw comments');
select ok(not has_table_privilege('authenticated','public.social_post_comments','INSERT'),'authenticated cannot insert raw comments');
select ok(not has_table_privilege('authenticated','public.social_post_likes','SELECT'),'authenticated cannot query raw likes');
select ok(not has_table_privilege('anon','public.social_posts','SELECT'),'anon cannot query posts');
select ok(has_function_privilege('authenticated','public.get_social_feed(timestamptz,uuid,integer)','EXECUTE'),'authenticated can call feed RPC');
select ok(has_function_privilege('authenticated','public.create_social_post(text)','EXECUTE'),'authenticated can create posts');
select ok(has_function_privilege('authenticated','public.add_social_comment(uuid,text)','EXECUTE'),'authenticated can comment');
select ok(has_function_privilege('authenticated','public.like_social_post(uuid)','EXECUTE'),'authenticated can like');
select ok(not has_function_privilege('anon','public.create_social_post(text)','EXECUTE'),'anon cannot create posts');
select ok(not has_function_privilege('authenticated','public._require_active_social_user(uuid)','EXECUTE'),'internal active-account guard is not client callable');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind='r' and not c.relrowsecurity),0,'RLS remains enabled on every public table');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef
 and not exists(select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')),0,
 'all SECURITY DEFINER functions pin search_path');

-- A creates a post; B sees only the declared display identity fields.
select tests.login('a1');
select is((public.create_social_post('  Hello from the alumni network  ')).content,
 'Hello from the alumni network','post content is trimmed and stored');
reset role;
select tests.login('a2');
select is((select author_name from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 'a1','feed reveals public display name');
select is((select author_avatar_url from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 'https://images.example.test/a1.png','feed reveals permitted avatar only');
select is((select likes_count from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 0::bigint,'new post starts with zero likes');
select is((select comments_count from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 0::bigint,'new post starts with zero comments');
select ok(not (select liked_by_me from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 'unliked feed flag is false');
select is((public.create_social_post('B post')).content,'B post','second graduate creates own post');
select is((select count(*)::int from public.get_social_feed(null,null,1)),1,'feed page limit is enforced');
select is((select count(*)::int from public.get_social_feed(
 (select created_at from public.get_social_feed(null,null,1)),
 (select id from public.get_social_feed(null,null,1)),1)),1,'keyset cursor returns the next feed page');
select throws_ok($q$select * from public.get_social_feed(now(),null,20)$q$,
 'PT422','INVALID_INPUT','partial feed cursor rejected');
select throws_ok($q$select * from public.get_social_feed(null,null,0)$q$,
 'PT422','INVALID_INPUT','zero feed limit rejected');
select throws_ok($q$select * from public.get_social_feed(null,null,51)$q$,
 'PT422','INVALID_INPUT','oversized feed limit rejected');
select ok(position('email' in pg_get_function_result('public.get_social_feed(timestamptz,uuid,integer)'::regprocedure))=0,
 'feed RPC result does not expose email or other private profile fields');

-- A hidden-avatar preference is honored; A2 still has a display name.
select is((select author_avatar_url from public.get_social_feed(null,null,20) where content='B post'),null,
 'hidden avatar preference suppresses image in feed');

-- Comments: create, read, edit, authorization, deletion and validation.
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
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20)),
 'Try to edit another user comment')$q$,
 'PT404','SOCIAL_COMMENT_NOT_FOUND','post owner cannot edit someone else comment');
select throws_ok($q$select public.delete_social_comment(
 (select id from public.get_social_post_comments(
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20)))$q$,
 'PT404','SOCIAL_COMMENT_NOT_FOUND','post owner cannot delete someone else comment');
reset role;
select tests.login('a2');
select throws_ok($q$select public.update_social_comment(
 (select id from public.get_social_post_comments(
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20)),
 repeat('x',2001))$q$,
 'PT422','INVALID_INPUT','comment length maximum enforced');
select throws_ok($q$select public.add_social_comment(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),'  ')$q$,
 'PT422','INVALID_INPUT','blank comment rejected');
select throws_ok($q$select public.get_social_post_comments(gen_random_uuid(),null,null,20)$q$,
 'PT404','SOCIAL_POST_NOT_FOUND','comments for unknown post rejected');
select throws_ok($q$select public.get_social_post_comments(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),now(),null,20)$q$,
 'PT422','INVALID_INPUT','partial comment cursor rejected');
select throws_ok($q$select public.get_social_post_comments(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,51)$q$,
 'PT422','INVALID_INPUT','oversized comment page rejected');
select is(public.delete_social_comment(
 (select id from public.get_social_post_comments(
  (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),null,null,20))),
 true,'comment author can delete own comment');
select is((select comments_count from public.get_social_feed(null,null,20)
 where content='Hello from the alumni network'),0::bigint,'comment count updates after deletion');
select is((public.add_social_comment(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'),
 'Cascade comment')).content,'Cascade comment','comment can be added again for cascade test');

-- Likes are private edges: clients see counts and their own liked_by_me flag only.
select is(public.like_social_post(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network')),
 true,'graduate can like a post');
select throws_ok($q$select public.like_social_post(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'))$q$,
 'PT409','ALREADY_LIKED','duplicate like rejected');
select ok((select liked_by_me from public.get_social_feed(null,null,20)
 where content='Hello from the alumni network'),'liker sees liked_by_me true');
select is((select likes_count from public.get_social_feed(null,null,20)
 where content='Hello from the alumni network'),1::bigint,'feed reports likes count without exposing liker list');
select tests.login('a1');
select is(public.like_social_post(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network')),
 true,'post author can like own post');
select is((select likes_count from public.get_social_feed(null,null,20)
 where content='Hello from the alumni network'),2::bigint,'like count aggregates multiple graduates');
select is(public.unlike_social_post(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network')),
 true,'graduate can unlike a post');
select throws_ok($q$select public.unlike_social_post(
 (select id from public.get_social_feed(null,null,20) where content='Hello from the alumni network'))$q$,
 'PT404','NOT_LIKED','unlike without an existing like rejected');
reset role;

-- Suspended authors disappear from feed; suspended accounts cannot use feed RPCs.
select tests.login('a3');
select is((public.create_social_post('Post later hidden by suspension')).content,
 'Post later hidden by suspension','active account can create before suspension');
reset role;
update public.profiles set account_status='SUSPENDED' where id=tests.id('a3');
select tests.login('a2');
select ok(not exists(select 1 from public.get_social_feed(null,null,50)
 where content='Post later hidden by suspension'),'suspended author is hidden from feed');
select tests.login('a3');
select throws_ok($q$select * from public.get_social_feed(null,null,20)$q$,
 'PT403','ACCOUNT_UNAVAILABLE','suspended user cannot read feed');
select throws_ok($q$select public.create_social_post('blocked')$q$,
 'PT403','ACCOUNT_UNAVAILABLE','suspended user cannot create posts');
reset role;

-- Post ownership, validations and cascade cleanup.
select tests.login('a2');
select throws_ok($q$select public.update_social_post(
 (select id from public.get_social_feed(null,null,50) where content='Hello from the alumni network'),'hacked')$q$,
 'PT404','SOCIAL_POST_NOT_FOUND','another graduate cannot edit post');
select throws_ok($q$select public.delete_social_post(
 (select id from public.get_social_feed(null,null,50) where content='Hello from the alumni network'))$q$,
 'PT404','SOCIAL_POST_NOT_FOUND','another graduate cannot delete post');
select throws_ok($q$select public.create_social_post('  ')$q$,
 'PT422','INVALID_INPUT','blank post rejected');
select throws_ok($q$select public.create_social_post(repeat('x',5001))$q$,
 'PT422','INVALID_INPUT','post content maximum enforced');
select throws_ok($q$select public.update_social_post(
 (select id from public.get_social_feed(null,null,50) where content='B post'),'  ')$q$,
 'PT422','INVALID_INPUT','blank post update rejected');
select is((public.update_social_post(
 (select id from public.get_social_feed(null,null,50) where content='B post'),'B post edited')).content,
 'B post edited','author can edit own post');
select tests.login('a1');
select is((public.update_social_post(
 (select id from public.get_social_feed(null,null,50) where content='Hello from the alumni network'),
 'Updated alumni announcement')).content,
 'Updated alumni announcement','post owner can update own content');
select ok(exists(select 1 from public.get_social_feed(null,null,50)
 where content='Updated alumni announcement'),'updated content is reflected in feed');
select is(public.delete_social_post(
 (select id from public.get_social_feed(null,null,50) where content='Updated alumni announcement')),
 true,'post owner can delete own post');
reset role;
select is((select count(*)::int from public.social_posts where content='Updated alumni announcement'),0,'deleted post is removed');
select is((select count(*)::int from public.social_post_comments where content='Cascade comment'),0,'deleting post cascades comments');
select is((select count(*)::int from public.social_post_likes),0,'deleting post cascades likes');

-- Anonymous role and unauthenticated calls are denied.
select set_config('request.jwt.claims','',true);
select throws_ok($q$select * from public.get_social_feed(null,null,20)$q$,
 'PT401','UNAUTHENTICATED','missing JWT cannot read feed');
reset role;
select set_config('role','anon',true);
select throws_ok($q$select public.create_social_post('anonymous')$q$,
 '42501',null,'anon cannot call social post RPC');
select throws_ok($q$select * from public.get_social_feed(null,null,20)$q$,
 '42501',null,'anon cannot call social feed RPC');
select throws_ok($q$select count(*) from public.social_posts$q$,
 '42501',null,'anon cannot query social tables');
reset role;
select * from finish();
rollback;
