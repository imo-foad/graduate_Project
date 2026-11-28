begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k = p_k $f$;
create function tests.put(p_k text, p_v uuid) returns uuid language plpgsql security definer set search_path = '' as $f$
begin
  delete from tests.ids where k = p_k;
  insert into tests.ids values (p_k, p_v);
  return p_v;
end $f$;
create function tests.put(p_k text, p_v text) returns uuid language plpgsql security definer set search_path = '' as $f$
begin
  delete from tests.ids where k = p_k;
  insert into tests.ids values (p_k, p_v::uuid);
  return p_v::uuid;
end $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $f$;
create function tests.human_actor(p_key text) returns uuid language sql stable security definer set search_path = ''
as $f$ select id from public.social_actors where actor_type = 'HUMAN' and profile_id = tests.id(p_key) $f$;
create function tests.company_actor(p_name text) returns uuid language sql stable security definer set search_path = ''
as $f$
  select a.id from public.social_actors a join public.companies c on c.id = a.company_id
   where a.actor_type = 'ORGANIZATION' and c.name = p_name
$f$;
create function tests.storage_fixture(p_uid uuid, p_name text, p_mime text, p_size integer) returns text
language plpgsql security definer set search_path = '' as $f$
declare v_path text := p_uid::text || '/' || p_name;
begin
  insert into storage.objects (bucket_id, name, owner, metadata)
  values ('social-media', v_path, p_uid, jsonb_build_object('mimetype', p_mime, 'size', p_size));
  return v_path;
end $f$;

-- ---------------------------------------------------------------------------------------------------
-- Fixtures: a student and a faculty member with NO graduate profile, a graduate, company members and
-- a platform administrator. Accounts, companies and Storage objects are synthetic local fixtures.
-- ---------------------------------------------------------------------------------------------------
do $$
declare v_owner uuid; v_verified uuid; v_pending uuid; v_suspended uuid;
begin
  perform tests.mk_user('student');
  perform tests.mk_user('faculty');
  perform tests.mk_user('grad');
  perform tests.mk_user('other');
  perform tests.mk_user('admin');
  perform tests.mk_user('owner');
  perform tests.mk_user('recruiter');
  perform tests.mk_user('viewer');
  perform tests.mk_user('outsider');

  -- A student/faculty account is not a graduate: remove the legacy trigger-provisioned career row.
  delete from public.graduate_profiles where profile_id in (tests.id('student'), tests.id('faculty'));
  insert into private.platform_admins(user_id, is_active) values (tests.id('admin'), true);

  v_owner := tests.id('owner');
  insert into public.companies(name, verification_status, created_by)
  values ('Verified Co', 'VERIFIED', v_owner) returning id into v_verified;
  insert into public.companies(name, verification_status, created_by)
  values ('Pending Co', 'PENDING_REVIEW', v_owner) returning id into v_pending;
  insert into public.companies(name, verification_status, created_by)
  values ('Suspended Co', 'SUSPENDED', v_owner) returning id into v_suspended;
  insert into public.company_memberships(company_id, user_id, role) values
    (v_verified, tests.id('owner'), 'OWNER'),
    (v_verified, tests.id('recruiter'), 'RECRUITER'),
    (v_verified, tests.id('viewer'), 'VIEWER'),
    (v_pending, tests.id('owner'), 'OWNER'),
    (v_suspended, tests.id('owner'), 'OWNER');
end $$;

select tests.storage_fixture(tests.id('student'), 'photo-a.png', 'image/png', 1200);
select tests.storage_fixture(tests.id('student'), 'photo-b.jpg', 'image/jpeg', 2400);
select tests.storage_fixture(tests.id('student'), 'photo-c.webp', 'image/webp', 3600);
select tests.storage_fixture(tests.id('grad'), 'grad-1.png', 'image/png', 5000);
select tests.storage_fixture(tests.id('grad'), 'grad-2.png', 'image/png', 5000);
select tests.storage_fixture(tests.id('grad'), 'moderated.png', 'image/png', 7000);
select tests.storage_fixture(tests.id('owner'), 'company.png', 'image/png', 8000);
select tests.storage_fixture(tests.id('other'), 'other.png', 'image/png', 9000);

-- ---------------------------------------------------------------------------------------------------
-- 1. Surface area: raw tables stay closed, every new client entry point is explicit.
-- ---------------------------------------------------------------------------------------------------
select ok(not has_table_privilege('authenticated', 'public.social_actors', 'SELECT'),
  'authenticated cannot read raw social actors');
select ok(not has_table_privilege('authenticated', 'public.social_actors', 'INSERT'),
  'authenticated cannot create social actors');
select ok(not has_table_privilege('authenticated', 'public.social_post_media', 'SELECT'),
  'authenticated cannot read raw media metadata');
select ok(not has_table_privilege('authenticated', 'public.social_post_media', 'INSERT'),
  'authenticated cannot insert media metadata directly');
select ok(not has_table_privilege('authenticated', 'private.social_media_cleanup_queue', 'SELECT'),
  'authenticated cannot read the media cleanup ledger');
select ok((select relrowsecurity from pg_class where oid = 'public.social_actors'::regclass),
  'social actors table has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.social_post_media'::regclass),
  'social media table has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'private.social_media_cleanup_queue'::regclass),
  'media cleanup ledger has RLS enabled');
select ok(has_function_privilege('authenticated', 'public.get_social_feed_v2(timestamptz,uuid,integer)', 'EXECUTE'),
  'authenticated can call the v2 feed');
select ok(has_function_privilege('authenticated', 'public.create_social_post_v2(uuid,text,uuid[],uuid)', 'EXECUTE'),
  'authenticated can create v2 posts');
select ok(has_function_privilege('authenticated', 'public.share_social_post(uuid,uuid,text)', 'EXECUTE'),
  'authenticated can share posts');
select ok(has_function_privilege('authenticated', 'public.get_my_social_actors()', 'EXECUTE'),
  'authenticated can list own publishing identities');
select ok(has_function_privilege('authenticated', 'public.register_social_media(uuid,text,text,integer,integer,integer,text)', 'EXECUTE'),
  'authenticated can register uploaded media');
select ok(has_function_privilege('authenticated', 'public.authorize_social_media(uuid[])', 'EXECUTE'),
  'authenticated can request authorized media paths');
select ok(not has_function_privilege('authenticated', 'public.claim_social_media_cleanup(integer)', 'EXECUTE'),
  'authenticated cannot claim media cleanup work');
select ok(not has_function_privilege('authenticated', 'public.complete_social_media_cleanup(uuid)', 'EXECUTE'),
  'authenticated cannot complete media cleanup work');
select ok(has_function_privilege('service_role', 'public.claim_social_media_cleanup(integer)', 'EXECUTE'),
  'service role can claim media cleanup work');
select ok(not has_function_privilege('anon', 'public.get_social_feed_v2(timestamptz,uuid,integer)', 'EXECUTE'),
  'anon cannot call the v2 feed');
select ok(not has_function_privilege('anon', 'public.create_social_post_v2(uuid,text,uuid[],uuid)', 'EXECUTE'),
  'anon cannot create posts');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosecdef
              and p.proname in ('get_social_feed_v2','create_social_post_v2','update_social_post_v2',
                                'delete_social_post','share_social_post','unshare_social_post',
                                'register_social_media','authorize_social_media','get_my_social_actors',
                                'add_social_comment_v2','like_social_post_v2','unlike_social_post_v2',
                                'claim_social_media_cleanup','complete_social_media_cleanup',
                                'fail_social_media_cleanup','get_social_media_cleanup_report')
              and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')), 0,
  'every new SECURITY DEFINER RPC pins search_path');
select is((select count(*)::int from private.rate_limit_policies where action in ('SOCIAL_SHARE','SOCIAL_MEDIA_UPLOAD')), 2,
  'share and media upload actions have their own rate-limit budgets');
select is((select public from storage.buckets where id = 'social-media'), false,
  'the social-media bucket is private');
select is((select file_size_limit from storage.buckets where id = 'social-media'), 5242880::bigint,
  'the social-media bucket enforces a 5 MB object limit');

-- ---------------------------------------------------------------------------------------------------
-- 2. Human actors: student and faculty publish without any graduate profile.
-- ---------------------------------------------------------------------------------------------------
select is((select count(*)::int from public.graduate_profiles where profile_id = tests.id('student')), 0,
  'fixture student genuinely has no graduate profile');
select is((select count(*)::int from public.graduate_profiles where profile_id = tests.id('faculty')), 0,
  'fixture faculty member genuinely has no graduate profile');
select is((select count(*)::int from public.social_actors where profile_id = tests.id('student')), 1,
  'exactly one human actor is provisioned per profile');

select tests.login('student');
select is((select count(*)::int from public.get_my_social_actors()), 1,
  'a student sees only their personal publishing identity');
select is((select actor_type from public.get_my_social_actors()), 'HUMAN',
  'the personal identity is a HUMAN actor');
select is((select display_name from public.get_my_social_actors()), 'student',
  'the personal actor projects the profile display name');
select ok((select can_publish from public.get_my_social_actors()), 'the personal actor can publish');

select is((public.create_social_post_v2(tests.human_actor('student'), '  Hello as a student  '))->>'content',
  'Hello as a student', 'a student publishes a text-only post');
select tests.put('student_post', ((select id from public.get_social_feed_v2() where content = 'Hello as a student')));
select is((select actor_type from public.get_social_feed_v2() where id = tests.id('student_post')), 'HUMAN',
  'the feed projects the human actor type');
select ok(not (select actor_verified from public.get_social_feed_v2() where id = tests.id('student_post')),
  'a personal actor is not marked as a verified organization');
select is((select media from public.get_social_feed_v2() where id = tests.id('student_post'))::text, '[]',
  'a text-only post has an empty media array');
select throws_ok($q$select public.create_social_post_v2(tests.human_actor('student'), '   ')$q$,
  'PT422', 'INVALID_INPUT', 'a whitespace-only post without media or share is rejected');
select throws_ok($q$select public.create_social_post_v2(tests.human_actor('student'), repeat('x', 5001))$q$,
  'PT422', 'INVALID_INPUT', 'post text length is capped at 5000 characters');
select throws_ok($q$select public.create_social_post_v2(tests.human_actor('grad'), 'impersonation')$q$,
  'PT403', 'SOCIAL_ACTOR_NOT_AUTHORIZED', 'a user cannot publish as another human actor');

select tests.login('faculty');
select is((select actor_type from public.get_my_social_actors()), 'HUMAN',
  'a faculty-only account receives a personal actor');
select is(public.create_social_post_v2(tests.human_actor('faculty'), 'Faculty office hours')->>'content',
  'Faculty office hours', 'a faculty member publishes without a graduate profile');

-- ---------------------------------------------------------------------------------------------------
-- 3. Media registration and validation.
-- ---------------------------------------------------------------------------------------------------
reset role;
select tests.login('student');
select tests.put('media_a', (public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-a.png', 'image/png', 1200, 800, 600, 'A diagram on a whiteboard'))->>'media_id')::uuid;
reset role;
select is((select status from public.social_post_media where id = tests.id('media_a')), 'PENDING',
  'a registered upload starts as pending metadata');
select is((select alt_text from public.social_post_media where id = tests.id('media_a')), 'A diagram on a whiteboard',
  'alt text is stored with the pending upload');
select tests.login('student');
select throws_ok($q$select public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('grad')::text || '/grad-1.png', 'image/png', 5000, 100, 100, null)$q$,
  'PT403', 'SOCIAL_MEDIA_NOT_OWNED', 'a user cannot register media in another user namespace');
select throws_ok($q$select public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-b.jpg', 'image/png', 2400, 100, 100, null)$q$,
  'PT422', 'SOCIAL_MEDIA_INVALID', 'declared MIME must match the uploaded object metadata');
select throws_ok($q$select public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-b.jpg', 'image/jpeg', 9999, 100, 100, null)$q$,
  'PT422', 'SOCIAL_MEDIA_INVALID', 'declared size must match the uploaded object metadata');
select throws_ok($q$select public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-b.jpg', 'image/jpeg', 5242881, 100, 100, null)$q$,
  'PT422', 'SOCIAL_MEDIA_TOO_LARGE', 'images above 5 MB are rejected');
select throws_ok($q$select public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-b.jpg', 'image/svg+xml', 2400, 100, 100, null)$q$,
  'PT422', 'SOCIAL_MEDIA_INVALID', 'SVG and other non-raster types are rejected');
select throws_ok($q$select public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-b.jpg', 'image/jpeg', 2400, 8000, 8000, null)$q$,
  'PT422', 'SOCIAL_MEDIA_INVALID', 'the pixel budget is enforced');
select throws_ok($q$select public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/never-uploaded.png', 'image/png', 100, 10, 10, null)$q$,
  'PT422', 'SOCIAL_MEDIA_UPLOAD_MISSING', 'an object that was never uploaded cannot be registered');

-- ---------------------------------------------------------------------------------------------------
-- 4. Image posts: attach, order, re-order, remove and durable cleanup.
-- ---------------------------------------------------------------------------------------------------
select tests.put('media_b', (public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-b.jpg', 'image/jpeg', 2400, 100, 100, 'Second image'))->>'media_id')::uuid;
select tests.put('media_c', (public.register_social_media(
  (select actor_id from public.get_my_social_actors()),
  tests.id('student')::text || '/photo-c.webp', 'image/webp', 3600, 100, 100, null))->>'media_id')::uuid;

select throws_ok($q$select public.create_social_post_v2(
  (select actor_id from public.get_my_social_actors()), null,
  array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        gen_random_uuid()], null)$q$,
  'PT422', 'SOCIAL_MEDIA_LIMIT_EXCEEDED', 'a post cannot carry more than ten images');

-- An image-only post is valid and returns ordered media.
select tests.put('image_post', (public.create_social_post_v2(
  (select actor_id from public.get_my_social_actors()), null,
  array[tests.id('media_b'), tests.id('media_a')], null))->>'post_id')::uuid;
reset role;
select is((select content from public.social_posts where id = tests.id('image_post')), null::text,
  'an image-only post stores no text');
select is((select jsonb_array_length(media) from public.get_social_feed_v2() where id = tests.id('image_post')), 2,
  'the feed returns both attached images');
select is((select media -> 0 ->> 'media_id' from public.get_social_feed_v2() where id = tests.id('image_post')),
  tests.id('media_b')::text, 'image order follows the attach order');
select is((select media -> 1 ->> 'alt_text' from public.get_social_feed_v2() where id = tests.id('image_post')),
  'A diagram on a whiteboard', 'alt text is projected with the image');
select is((select status from public.social_post_media where id = tests.id('media_a')), 'ATTACHED',
  'attached media is marked ATTACHED');
select tests.login('student');
select throws_ok($q$select public.create_social_post_v2(
  (select actor_id from public.get_my_social_actors()), 'reuse', array[tests.id('media_a')], null)$q$,
  'PT409', 'SOCIAL_MEDIA_NOT_ATTACHABLE', 'media already attached to another post cannot be reused');

select tests.login('other');
select throws_ok($q$select public.update_social_post_v2(tests.id('image_post'), 'hijacked')$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'another user cannot edit the post');
select is((select count(*)::int from public.authorize_social_media(array[tests.id('media_a')])), 1,
  'any authenticated viewer may request media for a visible post');
select tests.login('student');
select tests.put('reorder', (public.update_social_post_v2(
  tests.id('image_post'), 'Now with a caption',
  jsonb_build_array(jsonb_build_object('media_id', tests.id('media_a'), 'alt_text', 'First now'),
                    jsonb_build_object('media_id', tests.id('media_b'))))->>'post_id')::uuid);
select is((select media -> 0 ->> 'media_id' from public.get_social_feed_v2() where id = tests.id('image_post')),
  tests.id('media_a')::text, 'images can be reordered');
select is((select media -> 0 ->> 'alt_text' from public.get_social_feed_v2() where id = tests.id('image_post')),
  'First now', 'alt text can be updated during an edit');
select is((select content from public.get_social_feed_v2() where id = tests.id('image_post')),
  'Now with a caption', 'post text can be edited alongside media');
reset role;
select is((select status from public.social_post_media where id = tests.id('media_c')), 'PENDING',
  'an unattached pending upload is untouched by an edit');
select is((select count(*)::int from private.social_media_cleanup_queue where media_id = tests.id('media_c')), 0,
  'unused pending media is not queued for deletion');

select tests.login('student');
select is((public.update_social_post_v2(
  tests.id('image_post'), 'Now with a caption',
  jsonb_build_array(jsonb_build_object('media_id', tests.id('media_a'))))->>'post_id')::uuid,
  tests.id('image_post'), 'an edit can remove an image');
reset role;
select is((select status from public.social_post_media where id = tests.id('media_b')), 'RETIRED',
  'removed media is retired');
reset role;
select is((select status from private.social_media_cleanup_queue where media_id = tests.id('media_b')), 'PENDING',
  'removing an image queues its Storage cleanup');
select is((select reason from private.social_media_cleanup_queue where media_id = tests.id('media_b')), 'MEDIA_RETIRED',
  'the cleanup reason records a media retirement');

-- ---------------------------------------------------------------------------------------------------
-- 5. Shares: attribution, duplicates, re-share rules and ownership.
-- ---------------------------------------------------------------------------------------------------
reset role;
select tests.login('grad');
select tests.put('grad_media_1', (public.register_social_media(
  tests.human_actor('grad'), tests.id('grad')::text || '/grad-1.png', 'image/png', 5000, 640, 480, 'Graduate photo one'))->>'media_id')::uuid;
select tests.put('grad_media_2', (public.register_social_media(
  tests.human_actor('grad'), tests.id('grad')::text || '/grad-2.png', 'image/png', 5000, 640, 480, null))->>'media_id')::uuid;
select tests.put('grad_post', (public.create_social_post_v2(
  tests.human_actor('grad'), 'Graduate announcement', null, null))->>'post_id')::uuid;
select tests.put('grad_image_post', (public.create_social_post_v2(
  tests.human_actor('grad'), 'Graduate photo post',
  array[tests.id('grad_media_1'), tests.id('grad_media_2')], null))->>'post_id')::uuid;

select tests.login('student');
select tests.put('student_share', (public.share_social_post(
  tests.human_actor('student'), tests.id('grad_post'), null))->>'share_post_id')::uuid;
select is((select shared_post ->> 'actor_name' from public.get_social_feed_v2()
           where id = tests.id('student_share')), 'grad',
  'a share shows the original author');
select is((select actor_name from public.get_social_feed_v2() where id = tests.id('student_share')), 'student',
  'a share shows the sharing actor');
select is((select shared_post ->> 'id' from public.get_social_feed_v2() where id = tests.id('student_share')),
  tests.id('grad_post')::text, 'a share references the original post using the documented id field');
select throws_ok($q$select public.share_social_post(tests.human_actor('student'), tests.id('grad_post'), null)$q$,
  'PT409', 'ALREADY_SHARED', 'one actor cannot share the same post twice');

select tests.login('faculty');
select is((public.share_social_post(tests.human_actor('faculty'), tests.id('grad_post'), '  Worth reading  '))->>'shared_post_id',
  tests.id('grad_post')::text, 'a share with commentary is accepted');
select throws_ok($q$select public.share_social_post(
  tests.human_actor('faculty'), tests.id('student_share'), null)$q$,
  'PT422', 'SOCIAL_SHARE_NOT_ALLOWED', 'a share of a share is rejected');
select throws_ok($q$select public.share_social_post(tests.human_actor('faculty'), gen_random_uuid(), null)$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'sharing an unknown post is rejected');

select tests.login('student');
select is((select shares_count from public.get_social_feed_v2() where id = tests.id('grad_post')), 2::bigint,
  'the original post counts both shares');
select ok((select shared_by_me from public.get_social_feed_v2() where id = tests.id('grad_post')),
  'the caller sees their own share state');
select is(public.unshare_social_post(tests.id('student_share')), true, 'a sharer can undo their own share');
select is((select shares_count from public.get_social_feed_v2() where id = tests.id('grad_post')), 1::bigint,
  'undoing a share updates the count');
reset role;
select is((select count(*)::int from public.social_posts where id = tests.id('student_share')), 0,
  'an undone share row is deleted');
select tests.put('faculty_share', (select id from public.social_posts
   where shared_post_id = tests.id('grad_post') and actor_id = tests.human_actor('faculty')));

select tests.login('student');
select throws_ok($q$select public.unshare_social_post(tests.id('faculty_share'))$q$,
  'PT404', 'SOCIAL_SHARE_NOT_FOUND', 'another user cannot undo someone else share');
select throws_ok($q$select public.delete_social_post(tests.id('faculty_share'))$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'another user cannot delete someone else share');

-- ---------------------------------------------------------------------------------------------------
-- 6. Organization publishing: OWNER, RECRUITER, VIEWER, revoked membership, status gates.
-- ---------------------------------------------------------------------------------------------------
reset role;
select tests.login('owner');
select is((select count(*)::int from public.get_my_social_actors() where actor_type = 'ORGANIZATION'), 3,
  'the owner sees every organization they belong to');
select ok((select can_publish from public.get_my_social_actors() where display_name = 'Verified Co'),
  'a verified OWNER membership can publish');
select ok(not (select can_publish from public.get_my_social_actors() where display_name = 'Pending Co'),
  'an unverified company cannot publish');
select is((select membership_role from public.get_my_social_actors() where display_name = 'Verified Co'), 'OWNER',
  'the actor list exposes the caller membership role');
select tests.put('company_post', (public.create_social_post_v2(
  tests.company_actor('Verified Co'), 'We are hiring graduates', null, null))->>'post_id')::uuid;
select is((select actor_type from public.get_social_feed_v2() where id = tests.id('company_post')), 'ORGANIZATION',
  'the feed identifies the company as publisher');
select ok((select actor_verified from public.get_social_feed_v2() where id = tests.id('company_post')),
  'a verified company is marked verified');
select is(public.create_social_post_v2(tests.human_actor('owner'), 'Personal note from the owner')->>'actor_type',
  'HUMAN', 'the same human can also publish as themselves');
select is((public.update_social_post_v2(tests.id('company_post'), 'We are hiring graduates this quarter'))->>'content',
  'We are hiring graduates this quarter', 'an OWNER can edit company content');
select throws_ok($q$select public.create_social_post_v2(
  tests.company_actor('Pending Co'), 'unverified publication')$q$,
  'PT403', 'ORGANIZATION_NOT_VERIFIED', 'an unverified company cannot publish');
select throws_ok($q$select public.create_social_post_v2(
  tests.company_actor('Suspended Co'), 'suspended publication')$q$,
  'PT403', 'ORGANIZATION_SUSPENDED', 'a suspended company cannot publish');

select tests.login('recruiter');
select ok((select can_publish from public.get_my_social_actors() where display_name = 'Verified Co'),
  'an active RECRUITER can publish for the company');
select is(public.create_social_post_v2(
  tests.company_actor('Verified Co'), 'Recruiter announcement')->>'actor_id',
  tests.company_actor('Verified Co')::text, 'the recruiter publishes through the company actor');
reset role;
select tests.put('recruiter_post', (select id from public.social_posts where content = 'Recruiter announcement'));

select tests.login('viewer');
select is((select membership_role from public.get_my_social_actors() where display_name = 'Verified Co'), 'VIEWER',
  'a VIEWER is listed for read-only visibility');
select ok(not (select can_publish from public.get_my_social_actors() where display_name = 'Verified Co'),
  'a VIEWER cannot publish');
select throws_ok($q$select public.create_social_post_v2(
  tests.company_actor('Verified Co'), 'viewer publication')$q$,
  'PT403', 'SOCIAL_ACTOR_NOT_AUTHORIZED', 'a VIEWER cannot publish as the company');
select throws_ok($q$select public.update_social_post_v2(tests.id('company_post'), 'viewer edit')$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'a VIEWER cannot edit company content');
select throws_ok($q$select public.delete_social_post(tests.id('company_post'))$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'a VIEWER cannot delete company content');

select tests.login('outsider');
select throws_ok($q$select public.create_social_post_v2(
  tests.company_actor('Verified Co'), 'outsider publication')$q$,
  'PT403', 'SOCIAL_ACTOR_NOT_AUTHORIZED', 'a non-member cannot publish as the company');

-- Revoked membership loses publishing and management rights immediately.
reset role;
update public.company_memberships set is_active = false
 where company_id = (select id from public.companies where name = 'Verified Co')
   and user_id = tests.id('recruiter');
select tests.login('recruiter');
select throws_ok($q$select public.create_social_post_v2(
  tests.company_actor('Verified Co'), 'after revocation')$q$,
  'PT403', 'SOCIAL_ACTOR_NOT_AUTHORIZED', 'a revoked recruiter cannot publish');
select throws_ok($q$select public.update_social_post_v2(tests.id('recruiter_post'), 'revoked edit')$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'a revoked recruiter cannot manage company content');
reset role;
update public.company_memberships set is_active = true
 where company_id = (select id from public.companies where name = 'Verified Co')
   and user_id = tests.id('recruiter');

-- Company suspension hides existing company posts and blocks new ones.
update public.companies set verification_status = 'SUSPENDED' where name = 'Verified Co';
select tests.login('student');
select ok(not exists (select 1 from public.get_social_feed_v2() where id = tests.id('company_post')),
  'suspending a company hides its posts from the feed');
select tests.login('owner');
select throws_ok($q$select public.create_social_post_v2(
  tests.company_actor('Verified Co'), 'after suspension')$q$,
  'PT403', 'ORGANIZATION_SUSPENDED', 'a suspended company cannot publish');
reset role;
update public.companies set verification_status = 'VERIFIED' where name = 'Verified Co';

-- ---------------------------------------------------------------------------------------------------
-- 7. Comments and likes across actor types.
-- ---------------------------------------------------------------------------------------------------
select tests.login('student');
select is((public.add_social_comment_v2(
  tests.id('grad_post'), tests.human_actor('student'), '  Student comment  '))->>'content',
  'Student comment', 'a student comments as themselves');
select is((public.add_social_comment_v2(
  tests.id('grad_post'), tests.human_actor('student'), 'second'))->>'content',
  'second', 'a second comment is accepted');
reset role;
select tests.put('student_comment', (select id from public.social_post_comments where content = 'Student comment'));

select tests.login('owner');
select is((public.add_social_comment_v2(
  tests.id('grad_post'), tests.company_actor('Verified Co'), 'Company reply'))->>'actor_id',
  tests.company_actor('Verified Co')::text, 'an organization OWNER can comment as the company');
reset role;
select is((select actor_type from public.social_post_comments c
            join private.social_actor_cards ac on ac.actor_id = c.actor_id
           where c.content = 'Company reply'), 'ORGANIZATION', 'the comment keeps its organization actor');

select tests.login('viewer');
select throws_ok($q$select public.add_social_comment_v2(
  tests.id('grad_post'), tests.company_actor('Verified Co'), 'viewer reply')$q$,
  'PT403', 'SOCIAL_ACTOR_NOT_AUTHORIZED', 'a VIEWER cannot comment as the company');

select tests.login('other');
select throws_ok($q$select public.update_social_comment(tests.id('student_comment'), 'hijacked')$q$,
  'PT404', 'SOCIAL_COMMENT_NOT_FOUND', 'another user cannot edit a comment');
select throws_ok($q$select public.delete_social_comment(tests.id('student_comment'))$q$,
  'PT404', 'SOCIAL_COMMENT_NOT_FOUND', 'another user cannot delete a comment');

select tests.login('student');
select is((public.update_social_comment_v2(tests.id('student_comment'), 'Edited comment'))->>'content',
  'Edited comment', 'a comment author can edit their comment');
select is(public.like_social_post_v2(tests.id('grad_post'), tests.human_actor('student')), true,
  'a student can like a post as themselves');
select throws_ok($q$select public.like_social_post_v2(tests.id('grad_post'), tests.human_actor('student'))$q$,
  'PT409', 'ALREADY_LIKED', 'a duplicate like is rejected');
reset role;
select tests.login('owner');
select is(public.like_social_post_v2(tests.id('grad_post'), tests.company_actor('Verified Co')), true,
  'a company can like a post through its actor');
select is((select likes_count from public.get_social_feed_v2() where id = tests.id('grad_post')), 2::bigint,
  'likes from different actors are counted separately');
select is(public.unlike_social_post_v2(tests.id('grad_post'), tests.company_actor('Verified Co')), true,
  'a company can undo its own like');
select tests.login('viewer');
select throws_ok($q$select public.like_social_post_v2(tests.id('grad_post'), tests.company_actor('Verified Co'))$q$,
  'PT403', 'SOCIAL_ACTOR_NOT_AUTHORIZED', 'a VIEWER cannot like as the company');
select tests.login('student');
select is(public.delete_social_comment(tests.id('student_comment')), true, 'a comment author can delete their comment');

-- ---------------------------------------------------------------------------------------------------
-- 8. Moderation: hidden originals suppress shares and media; REMOVE retires images permanently.
-- ---------------------------------------------------------------------------------------------------
reset role;
select tests.login('other');
select is((select status from public.create_social_content_report(
  'POST', tests.id('grad_image_post'), 'SPAM', 'Synthetic moderation fixture')), 'OPEN',
  'a user can report another user post');
reset role;
select tests.login('admin');
select is((select content_moderation_status from public.moderate_social_report(
  (select report_id from public.get_social_moderation_queue('OPEN', 50)
    where target_id = tests.id('grad_image_post')),
  'HIDE', 'Synthetic hide decision')), 'HIDDEN', 'a platform admin hides the reported post');
select is((select count(*)::int from public.authorize_social_media(array[tests.id('grad_media_1')])), 0,
  'hidden posts no longer authorize their images');
select tests.login('student');
select throws_ok($q$select public.add_social_comment(
  tests.id('grad_image_post'), 'comment on hidden post')$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'commenting on a hidden post is rejected');
select throws_ok($q$select public.share_social_post(tests.human_actor('student'), tests.id('grad_image_post'), null)$q$,
  'PT404', 'SOCIAL_POST_NOT_FOUND', 'a hidden post cannot be shared');
select tests.login('admin');
select is(public.restore_social_content('POST', tests.id('grad_image_post'), 'Synthetic restore decision'), true,
  'a platform admin can restore hidden content');
select tests.login('student');
select is((select count(*)::int from public.authorize_social_media(array[tests.id('grad_media_1')])), 1,
  'restored posts authorize their images again');

reset role;
select tests.login('other');
select is((select status from public.create_social_content_report(
  'POST', tests.id('grad_image_post'), 'HARASSMENT', 'Second synthetic report')), 'OPEN',
  'a fresh report can be filed after a restore');
reset role;
select tests.login('admin');
select is((select content_moderation_status from public.moderate_social_report(
  (select report_id from public.get_social_moderation_queue('OPEN', 50)
    where target_id = tests.id('grad_image_post')),
  'REMOVE', 'Synthetic removal decision')), 'REMOVED', 'a platform admin removes the post');
reset role;
select is((select count(*)::int from public.social_post_media
            where id in (tests.id('grad_media_1'), tests.id('grad_media_2')) and status = 'ATTACHED'), 0,
  'removal retires every image of the post');
select is((select count(*)::int from private.social_media_cleanup_queue
            where media_id in (tests.id('grad_media_1'), tests.id('grad_media_2')) and status = 'PENDING'), 2,
  'removal queues durable cleanup for every image');
select is((select action from private.social_moderation_events
            where target_id = tests.id('grad_image_post') and action = 'REMOVE'), 'REMOVE',
  'the immutable moderation audit records the removal');

-- ---------------------------------------------------------------------------------------------------
-- 9. Post deletion: media cleanup is queued, shares cascade, historical rows survive.
-- ---------------------------------------------------------------------------------------------------
select tests.login('student');
select is(public.delete_social_post(tests.id('image_post')), true, 'a post author can delete their own post');
reset role;
select is((select count(*)::int from public.social_posts where id = tests.id('image_post')), 0,
  'the deleted post is gone');
reset role;
select is((select status from private.social_media_cleanup_queue
            where media_id = tests.id('media_a')), 'PENDING',
  'deleting a post queues its remaining image for cleanup');
select is((select count(*)::int from private.social_media_cleanup_queue
            where storage_path like tests.id('student')::text || '/photo-%'), 2,
  'each retired image produces exactly one cleanup row');
-- A cleanup path is a permanent tombstone: it can never be registered again.
select tests.login('student');
select throws_ok($q$select public.register_social_media(
  tests.human_actor('student'), tests.id('student')::text || '/photo-a.png', 'image/png', 1200, 800, 600, null)$q$,
  'PT409', 'SOCIAL_MEDIA_RETIRED', 'a queued Storage path is permanently retired');

-- Deleting the original post cascades shares rather than leaving orphan commentary.
reset role;
select tests.login('grad');
select is(public.delete_social_post(tests.id('grad_post')), true, 'the original author can delete their post');
reset role;
select is((select count(*)::int from public.social_posts where shared_post_id = tests.id('grad_post')), 0,
  'deleting an original removes its shares');

-- ---------------------------------------------------------------------------------------------------
-- 10. Legacy RPC compatibility: existing clients keep their signatures and behaviour.
-- ---------------------------------------------------------------------------------------------------
select tests.login('grad');
select is((public.create_social_post('  Legacy client post  ')).content, 'Legacy client post',
  'the legacy create_social_post RPC still works');
reset role;
select tests.put('legacy_post', (select id from public.social_posts where content = 'Legacy client post'));
select is((select author_id from public.social_posts where id = tests.id('legacy_post')), tests.id('grad'),
  'a legacy graduate post keeps its historical author reference');
select is((select actor_id from public.social_posts where id = tests.id('legacy_post')), tests.human_actor('grad'),
  'a legacy post is mapped to the graduate human actor');
select tests.login('grad');
select is((select author_name from public.get_social_feed() where id = tests.id('legacy_post')), 'grad',
  'the legacy feed projection still returns display names');
select is((select count(*)::int from public.get_social_feed()), (select count(*)::int from public.get_social_feed_v2()),
  'the legacy feed returns the same number of visible rows as the v2 feed');
select is((public.add_social_comment(tests.id('legacy_post'), 'Legacy comment')).content,
  'Legacy comment', 'the legacy comment RPC still works');
select is(public.like_social_post(tests.id('legacy_post')), true,
  'the legacy like RPC still works');
select is(public.unlike_social_post(tests.id('legacy_post')), true,
  'the legacy unlike RPC still works');
select is((public.update_social_post(tests.id('legacy_post'), 'Legacy edited')).content,
  'Legacy edited', 'the legacy edit RPC still works');
select throws_ok($q$select public.create_social_post('')$q$,
  'PT422', 'INVALID_INPUT', 'the legacy RPC still rejects empty content');

-- ---------------------------------------------------------------------------------------------------
-- 11. Suspended accounts lose every social action.
-- ---------------------------------------------------------------------------------------------------
reset role;
update public.profiles set account_status = 'SUSPENDED' where id = tests.id('student');
select tests.login('student');
select throws_ok($q$select * from public.get_social_feed_v2()$q$,
  'PT403', 'ACCOUNT_UNAVAILABLE', 'a suspended user cannot read the feed');
select throws_ok($q$select public.create_social_post_v2(tests.human_actor('student'), 'suspended post')$q$,
  'PT403', 'ACCOUNT_UNAVAILABLE', 'a suspended user cannot publish');
select throws_ok($q$select public.like_social_post_v2(tests.id('company_post'), tests.human_actor('student'))$q$,
  'PT403', 'ACCOUNT_UNAVAILABLE', 'a suspended user cannot like');
select throws_ok($q$select public.share_social_post(tests.human_actor('student'), tests.id('company_post'), null)$q$,
  'PT403', 'ACCOUNT_UNAVAILABLE', 'a suspended user cannot share');
select throws_ok($q$select public.get_my_social_actors()$q$,
  'PT403', 'ACCOUNT_UNAVAILABLE', 'a suspended user cannot list publishing identities');
select tests.login('faculty');
select ok(not exists (select 1 from public.get_social_feed_v2() where content = 'Hello as a student'),
  'a suspended author is hidden from the feed');
reset role;
update public.profiles set account_status = 'ACTIVE' where id = tests.id('student');

-- ---------------------------------------------------------------------------------------------------
-- 12. Privacy of the feed projection and of the raw Storage object.
-- ---------------------------------------------------------------------------------------------------
select is(position('email' in pg_get_function_result('public.get_social_feed_v2(timestamptz,uuid,integer)'::regprocedure)), 0,
  'the v2 feed projection never exposes email');
select is(position('phone' in pg_get_function_result('public.get_social_feed_v2(timestamptz,uuid,integer)'::regprocedure)), 0,
  'the v2 feed projection never exposes phone');
select is(position('author_id' in pg_get_function_result('public.get_social_feed_v2(timestamptz,uuid,integer)'::regprocedure)), 0,
  'the v2 feed projection never exposes the publishing human id');
select tests.login('grad');
select is((select author_name from public.get_social_feed() where content = 'We are hiring graduates this quarter'),
  'Verified Co', 'an organization post is projected by its company name');

-- The private bucket only lets the uploader read raw objects; other viewers use the signed-URL flow.
reset role;
update public.graduate_profiles set hidden_fields = array['avatar_url'] where profile_id = tests.id('faculty');
select tests.login('faculty');
select is((select avatar_url from public.get_my_social_actors() where actor_type = 'HUMAN'), null::text,
  'a hidden avatar preference is honored in the actor list');
select tests.login('grad');
select is((select count(*)::int from storage.objects
            where bucket_id = 'social-media' and name like tests.id('student')::text || '/%'), 0,
  'another user cannot read the raw object row');
select tests.login('student');
select is((select count(*)::int from storage.objects
            where bucket_id = 'social-media' and name like tests.id('student')::text || '/%'), 3,
  'the uploader can see their own objects');

-- ---------------------------------------------------------------------------------------------------
-- 13. Cleanup worker: service-role only, idempotent and bounded.
-- ---------------------------------------------------------------------------------------------------
reset role;
select tests.login('admin');
select throws_ok($q$select public.claim_social_media_cleanup(10)$q$,
  '42501', null, 'authenticated clients cannot claim cleanup work');
reset role;
select set_config('request.jwt.claims',
  jsonb_build_object('sub', tests.id('admin'), 'role', 'service_role')::text, true);
set local role service_role;
select ok(jsonb_array_length(public.claim_social_media_cleanup(50)) >= 2, 'the worker claims queued cleanup rows');
select is((select status from private.social_media_cleanup_queue where media_id = tests.id('media_a')), 'PROCESSING',
  'a claimed row is leased as PROCESSING');
select is((select public.complete_social_media_cleanup(id) from private.social_media_cleanup_queue
            where media_id = tests.id('media_a')), true, 'the worker completes a cleanup row');
select is((select public.complete_social_media_cleanup(id) from private.social_media_cleanup_queue
            where media_id = tests.id('media_a')), false, 'completion is idempotent');
select is((select status from private.social_media_cleanup_queue where media_id = tests.id('media_a')), 'DONE',
  'completed cleanup is recorded as DONE');
select is(jsonb_typeof(public.get_social_media_cleanup_report()), 'object',
  'the reconciliation report is service-role readable');
reset role;

select * from finish();
rollback;
