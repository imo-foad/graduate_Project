begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select, insert on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$
  select v from tests.ids where k=p_k
$f$;
create function tests.mk_user(p_key text, p_confirmed boolean default true) returns uuid
language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
  values(
    v,'authenticated','authenticated',p_key||'@tests.local',
    case when p_confirmed then now() else null end,
    jsonb_build_object('full_name',p_key,'role','PLATFORM_ADMIN','is_admin',true)
  );
  insert into tests.ids values(p_key,v);
  return v;
end
$f$;
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',tests.id(p_key),'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
end
$f$;

do $$
begin
  perform tests.mk_user('admin');
  perform tests.mk_user('admin2');
  perform tests.mk_user('graduate');
  perform tests.mk_user('invitee',false);
  perform tests.mk_user('new_owner');
  perform tests.mk_user('outsider');
end
$$;

-- User metadata is untrusted. It cannot create administrator authority.
select tests.login('outsider');
select throws_ok($q$select public.assert_platform_admin()$q$,
  'PT403','ADMIN_REQUIRED','ordinary user with forged role metadata is not an admin');
select ok(not has_table_privilege('authenticated','private.platform_admin_audit','SELECT'),
  'authenticated cannot read platform admin audit');
select ok(not has_table_privilege('authenticated','private.graduate_invitations','SELECT'),
  'authenticated cannot read invitations table');
select ok(not has_table_privilege('authenticated','private.account_deletion_requests','SELECT'),
  'authenticated cannot read deletion requests');
select ok(not has_function_privilege('authenticated','public.bootstrap_first_platform_admin(uuid,text)','EXECUTE'),
  'authenticated cannot bootstrap the first admin');
select ok(not has_function_privilege('authenticated','public.finalize_graduate_invitation(uuid,uuid,boolean,text)','EXECUTE'),
  'authenticated cannot finalize invitations');
select ok(not has_function_privilege('authenticated','public.get_approved_account_deletion(uuid)','EXECUTE'),
  'authenticated cannot access deletion worker claim');
reset role;

-- Only a confirmed account can become the first administrator. Bootstrap is serialized and one-time.
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
select throws_ok($q$select public.bootstrap_first_platform_admin(tests.id('invitee'),'approved identity check')$q$,
  'PT422','ADMIN_TARGET_NOT_VERIFIED','unconfirmed Auth identity cannot bootstrap as first admin');
select is(public.bootstrap_first_platform_admin(tests.id('admin'),'operator ticket SEC-001'),
  true,'service-role bootstrap creates the first platform admin');
select throws_ok($q$select public.bootstrap_first_platform_admin(tests.id('admin2'),'second operator ticket')$q$,
  'PT409','ADMIN_ALREADY_BOOTSTRAPPED','first-admin bootstrap cannot add another admin');
select throws_ok($q$select public.finalize_graduate_invitation(gen_random_uuid(),null,false,'AUTH_INVITE_REJECTED')$q$,
  'PT404','INVITATION_NOT_FOUND','service role cannot finalize a nonexistent invitation');
reset role;

select tests.login('admin');
select is(public.assert_platform_admin(),true,'confirmed first administrator passes active admin guard');
select is((select count(*)::int from private.platform_admins where user_id=tests.id('admin') and is_active),1,
  'bootstrap writes the private admin membership');
select ok(exists(select 1 from private.platform_admin_audit
  where action='BOOTSTRAP_FIRST_ADMIN' and target_user_id=tests.id('admin')),
  'bootstrap writes an immutable audit event');

-- Grant/revoke requires a current active administrator and preserves at least one active administrator.
select is(public.set_platform_admin_access(tests.id('admin2'),true,'Secondary administrator approved'),
  true,'active admin can promote a verified account');
select throws_ok($q$select public.set_platform_admin_access(tests.id('invitee'),true,'Unconfirmed admin attempt')$q$,
  'PT422','ADMIN_TARGET_NOT_VERIFIED','unconfirmed user cannot be promoted to admin');
select is(public.set_platform_admin_access(tests.id('admin2'),false,'Access no longer required'),
  true,'active admin can revoke a secondary admin');
select throws_ok($q$select public.set_platform_admin_access(tests.id('admin'),false,'Remove last admin')$q$,
  'PT409','LAST_ACTIVE_ADMIN','last active administrator cannot be revoked');
reset role;

-- The invitation process requires a current platform admin and records explicit manual verification.
select tests.login('outsider');
select throws_ok($q$select * from public.create_graduate_invitation(
 'new.grad@tests.local','New Graduate','Registrar record checked and identity verified')$q$,
 'PT403','ADMIN_REQUIRED','ordinary graduate cannot send invitations');
reset role;
select tests.login('admin');
select throws_ok($q$select * from public.create_graduate_invitation(
 'bad-email','New Graduate','Registrar record checked and identity verified')$q$,
 'PT422','INVALID_INPUT','invalid email is rejected');
select throws_ok($q$select * from public.create_graduate_invitation(
 'new.grad@tests.local','N','Registrar record checked and identity verified')$q$,
 'PT422','INVALID_INPUT','invalid display name is rejected');
select is((select status from public.create_graduate_invitation(
 'new.grad@tests.local','New Graduate','Registrar record checked and identity verified')),
 'INVITING','admin may create an audited graduate invitation');
select throws_ok($q$select * from public.create_graduate_invitation(
 'NEW.GRAD@TESTS.LOCAL','Duplicate Graduate','Another verified identity')$q$,
 'PT409','INVITATION_ALREADY_ACTIVE','normalized email cannot have duplicate active invitations');
select is((select count(*)::int from public.list_graduate_invitations('INVITING',50)),1,
 'admins can list invitations and their manual verification record');
reset role;

-- Auth invitation completion is service-role-only and email must match the stored claim.
insert into tests.ids(k,v)
select 'invitation_id', id from private.graduate_invitations where email='new.grad@tests.local';
select throws_ok($q$select public.finalize_graduate_invitation(
 tests.id('invitation_id'),tests.id('invitee'),true,null)$q$,
 'PT403','SERVICE_ROLE_REQUIRED','authenticated user cannot finalize an Auth invitation');
reset role;
insert into tests.ids(k,v) values ('invited_user',gen_random_uuid());
insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values(tests.id('invited_user'), 'authenticated','authenticated','new.grad@tests.local',null,
       '{"full_name":"New Graduate","role":"ADMIN","is_admin":true}'::jsonb);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
select is(public.finalize_graduate_invitation(
 tests.id('invitation_id'),tests.id('invited_user'),true,null),
 'PENDING','service role links the Auth-created user to the invitation');
reset role;
update auth.users set email_confirmed_at=now() where id=tests.id('invited_user');
select is((select status from private.graduate_invitations where id=tests.id('invitation_id')),
 'ACCEPTED','Auth email confirmation moves the invitation to ACCEPTED');
select ok(not exists(select 1 from private.platform_admins where user_id=tests.id('invited_user')),
 'forged Auth user metadata does not grant platform admin');
select ok(exists(select 1 from private.platform_admin_audit
 where action='GRADUATE_INVITATION_ACCEPTED' and target_user_id=tests.id('invited_user')),
 'invitation acceptance is audited');
 
-- Suspensions are enforced by both the common RPC guard and restrictive RLS policies.
select set_config('request.jwt.claims',
 jsonb_build_object('sub',tests.id('admin'),'role','service_role')::text,true);
set local role service_role;
select is(public.set_graduate_account_status_for_admin(
 tests.id('admin'),tests.id('graduate'),'SUSPENDED','Policy review found suspicious account activity'),
 true,'trusted admin service path can suspend a graduate');
reset role;
select tests.login('graduate');
select throws_ok($q$select public._require_uid()$q$,
 'PT403','ACCOUNT_UNAVAILABLE','suspended graduate cannot use authenticated RPCs');
select is((select count(*)::int from public.profiles where id=tests.id('graduate')),0,
 'restrictive RLS policy hides all public rows from a suspended graduate');
reset role;
select set_config('request.jwt.claims',
 jsonb_build_object('sub',tests.id('admin'),'role','service_role')::text,true);
set local role service_role;
select is(public.set_graduate_account_status_for_admin(
 tests.id('admin'),tests.id('graduate'),'ACTIVE','Suspension appeal reviewed and access restored'),
 true,'trusted admin service path can reactivate a graduate');
reset role;
select tests.login('graduate');
select is((select count(*)::int from public.profiles where id=tests.id('graduate')),1,
 'reactivated graduate can read own profile again');
reset role;

-- Deletion is requested by the owner, reviewed by an admin, and only then claimed by service role.
select tests.login('graduate');
insert into tests.ids(k,v) values ('company_id',(public.create_company('Graduate-Owned Company')).id);
reset role;
insert into tests.ids(k,v)
values ('deletion_request_1',public.request_account_deletion('Please erase my account and CV data'));
select is((select count(*)::int from public.profiles where id=tests.id('graduate')),0,
 'a pending deletion request immediately blocks profile reads');
reset role;
select tests.login('admin');
select is((select status from public.review_account_deletion_request(
 (select request_id from public.get_account_deletion_queue('REQUESTED',50)
  where user_id=tests.id('graduate')),
 'REJECT','Identity and retention review did not support deletion')),
 'REJECTED','admin can reject a deletion request and provide a reason');
reset role;
select tests.login('graduate');
insert into tests.ids(k,v)
values ('deletion_request_2',public.request_account_deletion('I confirm my data deletion request'));
reset role;

-- An untransferred company creator/OWNER cannot be deleted.
select tests.login('admin');
select is((select status from public.review_account_deletion_request(
 tests.id('deletion_request_2'),'APPROVE','User identity and retention review complete')),
 'APPROVED','admin can approve deletion after identity review');
reset role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
select throws_ok($q$select public.get_approved_account_deletion(tests.id('deletion_request_2'))$q$,
 'PT409','COMPANY_OWNERSHIP_TRANSFER_REQUIRED','account deletion refuses to remove an active company owner');
reset role;

-- Ownership and company creator are transferred before deleting the old owner.
select tests.login('admin');
select is(public.transfer_company_creator(
 tests.id('company_id'),tests.id('new_owner'),'Transfer ownership before data erasure'),
 true,'platform admin can transfer company creator and OWNER membership');
select is((select created_by from public.companies where id=tests.id('company_id')),
 tests.id('new_owner'),'company creator is reassigned to the active new owner');
select is((select role from public.company_memberships
 where company_id=tests.id('company_id') and user_id=tests.id('new_owner') and is_active),
 'OWNER','ownership transfer activates the new OWNER');
select throws_ok($q$select public.transfer_company_creator(
 tests.id('company_id'),tests.id('invitee'),'Unconfirmed ownership must not transfer')$q$,
 'PT404','USER_NOT_FOUND','unconfirmed invite cannot become company owner');
reset role;

select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
select is(public.get_approved_account_deletion(tests.id('deletion_request_2')),
 tests.id('graduate'),'service worker claims an approved deletion after ownership transfer');
select ok(public.release_account_deletion_claim(tests.id('deletion_request_2')),
 'service worker can release a failed deletion claim for retry');
select is((select status from private.account_deletion_requests where id=tests.id('deletion_request_2')),
 'APPROVED','failed deletion remains approved for controlled retry');
select is(public.get_approved_account_deletion(tests.id('deletion_request_2')),
 tests.id('graduate'),'service worker can safely reclaim deletion on retry');
reset role;

-- The actual Auth delete hook finalizes the request and preserves the immutable audit.
delete from auth.users where id=tests.id('graduate');
select is((select status from private.account_deletion_requests
 where id=(select id from private.account_deletion_requests order by requested_at desc limit 1)),
 'COMPLETED','Auth deletion finalizes the approved request');
select is((select count(*)::int from public.profiles where id=tests.id('graduate')),
 0,'Auth deletion cascades the graduate profile and personal records');
select ok(exists(select 1 from private.platform_admin_audit
 where action='ACCOUNT_DELETED' and target_user_id=tests.id('graduate')),
 'account deletion is recorded in the admin audit');

-- Admin audit cannot be changed or removed by a privileged SQL caller.
select throws_ok($q$update private.platform_admin_audit set details='{}'::jsonb where true$q$,
 'PT403','PLATFORM_ADMIN_AUDIT_IMMUTABLE','platform admin audit cannot be edited');
select throws_ok($q$delete from private.platform_admin_audit$q$,
 'PT403','PLATFORM_ADMIN_AUDIT_IMMUTABLE','platform admin audit cannot be deleted');

select * from finish();
rollback;
