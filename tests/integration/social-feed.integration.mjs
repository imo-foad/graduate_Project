// Social Feed v2 HTTP integration against the disposable LOCAL Supabase stack only.
//
// Exercises the real gateway: Auth (password grant), PostgREST RPCs, private Storage objects and the
// social-media-upload Edge Function. Synthetic accounts only; every fixture is created here and removed
// at the end. Non-local targets are refused before the first Auth/Storage/psql call.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { assertLocalDbUrl } from "../../scripts/assert-local-db.mjs";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "local Supabase social-feed environment is incomplete");
const api = new URL(base);
assert.ok(api.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(api.hostname) &&
  api.port === "54321", "refusing social-feed integration outside the disposable local Supabase API");

const DB_URL = process.env.DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
assertLocalDbUrl(DB_URL); // throws for any non-local target

let passed = 0;
const pass = (name, condition = true, diagnostic) => {
  if (!condition && diagnostic !== undefined) console.error("DIAGNOSTIC " + name + ": " + JSON.stringify(diagnostic));
  assert.equal(Boolean(condition), true, name);
  passed++;
  console.log("PASS " + name);
};
function sql(statement) {
  return execFileSync("psql", ["-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", DB_URL, "-c", statement], {
    encoding: "utf8",
  }).trim();
}

const headers = (token, extra = {}) => ({
  apikey: anon,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...extra,
});
async function readResponse(res) {
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* binary or empty body */ }
  return { status: res.status, ok: res.ok, text, json };
}
async function request(path, init = {}) {
  const res = await fetch(base + path, { ...init, signal: init.signal ?? AbortSignal.timeout(60_000) });
  return readResponse(res);
}
async function rpc(token, fn, body) {
  return request("/rest/v1/rpc/" + fn, {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: JSON.stringify(body ?? {}),
  });
}
const errorCode = (response) => response.json?.message ?? response.json?.error ?? response.text?.slice(0, 200) ?? "";

// --- synthetic identities -------------------------------------------------------------------------
const run = randomUUID().slice(0, 8);
const createdUsers = [];
const createdCompanies = [];
async function createUser(label) {
  const email = `social.${label}.${run}@alumni.test`;
  const response = await request("/auth/v1/admin/users", {
    method: "POST",
    headers: headers(service, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  assert.equal(response.status, 200, "create synthetic auth user " + label + ": " + response.text.slice(0, 200));
  const id = response.json.id;
  createdUsers.push(id);
  sql(`insert into public.profiles (id, full_name, email, account_status) values ('${id}', 'Synthetic ${label}', '${email}', 'ACTIVE')`);
  return { id, email, label };
}
async function login(user) {
  const response = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email: user.email, password }),
  });
  assert.equal(response.status, 200, "password grant " + user.email + ": " + response.text.slice(0, 200));
  return { ...user, token: response.json.access_token };
}

const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==",
  "base64",
);
const encodePath = (path) => path.split("/").map(encodeURIComponent).join("/");
const objectUrl = (path) => "/storage/v1/object/social-media/" + encodePath(path);
async function uploadImage(user, path) {
  return request(objectUrl(path), {
    method: "POST",
    headers: headers(user.token, { "Content-Type": "image/png", "x-upsert": "false" }),
    body: PNG,
  });
}
async function downloadImage(token, path) {
  const res = await fetch(base + objectUrl(path), { headers: headers(token), signal: AbortSignal.timeout(60_000) });
  const body = Buffer.from(await res.arrayBuffer());
  return { status: res.status, size: body.length };
}
async function uploadViaFunction(user, actorId, altText = "synthetic diagram", bytes = PNG, mime = "image/png") {
  const form = new FormData();
  form.set("file", new Blob([bytes], { type: mime }), "synthetic.png");
  form.set("actor_id", actorId);
  form.set("alt_text", altText);
  const res = await fetch(base + "/functions/v1/social-media-upload", {
    method: "POST",
    headers: headers(user.token),
    body: form,
    signal: AbortSignal.timeout(60_000),
  });
  return readResponse(res);
}
async function registerMedia(user, actorId, path, altText = "synthetic diagram") {
  return rpc(user.token, "register_social_media", {
    p_actor_id: actorId,
    p_storage_path: path,
    p_mime_type: "image/png",
    p_size_bytes: PNG.length,
    p_width: 1,
    p_height: 1,
    p_alt_text: altText,
  });
}
async function feed(token, limit = 50) {
  const response = await rpc(token, "get_social_feed_v2", { p_limit: limit });
  assert.equal(response.status, 200, "feed read: " + response.text.slice(0, 200));
  assert.ok(Array.isArray(response.json), "feed returns an array");
  return response.json;
}
const findPost = (items, id) => items.find((item) => item.id === id) ?? null;
async function personalActor(user) {
  const response = await rpc(user.token, "get_my_social_actors");
  assert.equal(response.status, 200, "get_my_social_actors: " + response.text.slice(0, 200));
  const personal = (response.json ?? []).find((actor) => actor.actor_type === "HUMAN");
  assert.ok(personal?.actor_id, "a personal HUMAN actor exists for " + user.label);
  return personal;
}
const orgActor = (actors) => (actors ?? []).find((actor) => actor.actor_type === "ORGANIZATION") ?? null;

async function main() {
  const student = await login(await createUser("student"));
  const graduate = await login(await createUser("graduate"));
  const faculty = await login(await createUser("faculty"));
  const outsider = await login(await createUser("outsider"));
  const owner = await login(await createUser("owner"));
  const recruiter = await login(await createUser("recruiter"));
  const viewer = await login(await createUser("viewer"));

  // Students and faculty exist without any graduate profile; the personal actor still works.
  const companyId = randomUUID();
  createdCompanies.push(companyId);
  sql(`insert into public.companies (id, name, verification_status, created_by) values ('${companyId}', 'Synthetic Social Co ${run}', 'VERIFIED', '${owner.id}')`);
  sql(`insert into public.company_memberships (company_id, user_id, role) values
        ('${companyId}', '${owner.id}', 'OWNER'),
        ('${companyId}', '${recruiter.id}', 'RECRUITER'),
        ('${companyId}', '${viewer.id}', 'VIEWER')`);

  // --- Scenario A: student personal publishing, text then image, then delete ----------------------
  pass("student has no graduate profile", sql(`select count(*) from public.graduate_profiles where graduate_id = '${student.id}'`) === "0");
  const studentActor = await personalActor(student);
  pass("student personal actor can publish", studentActor.can_publish === true);

  const created = await rpc(student.token, "create_social_post_v2", {
    p_actor_id: studentActor.actor_id,
    p_content: "Synthetic student post " + run,
  });
  assert.equal(created.status, 200, "student text post: " + created.text.slice(0, 300));
  pass("student text post created", Boolean(created.json?.post_id));
  pass("created post reports HUMAN actor", created.json.actor_type === "HUMAN");
  pass("text post appears in the feed", findPost(await feed(student.token), created.json.post_id)?.content === "Synthetic student post " + run);

  const edited = await rpc(student.token, "update_social_post_v2", {
    p_post_id: created.json.post_id, p_content: "Synthetic student post edited " + run,
  });
  pass("student can edit own post", edited.status === 200 && edited.json.content === "Synthetic student post edited " + run);
  pass("student cannot publish as another human actor",
    (await rpc(student.token, "create_social_post_v2", { p_actor_id: (await personalActor(graduate)).actor_id, p_content: "impersonation" })).status === 404);

  pass("anonymous image upload is rejected", (await request("/functions/v1/social-media-upload", { method: "POST", body: new FormData() })).status === 401);
  const uploaded = await uploadViaFunction(student, studentActor.actor_id);
  pass("student uploads a signature-validated image through the Edge Function",
    uploaded.status === 201 && Boolean(uploaded.json.media_id) && uploaded.json.status === "PENDING", uploaded.text);
  const studentPath = uploaded.json.storage_path;
  pass("uploaded object stays in the caller's namespace", studentPath.startsWith(student.id + "/"));
  const media = { json: { media_id: uploaded.json.media_id } };
  const imagePost = await rpc(student.token, "create_social_post_v2", {
    p_actor_id: studentActor.actor_id, p_content: "Synthetic student image post", p_media_ids: [media.json.media_id],
  });
  pass("image post created with one image", imagePost.status === 200 && imagePost.json.media.length === 1, imagePost.text);
  const imageFeedItem = findPost(await feed(graduate.token), imagePost.json.post_id);
  pass("feed exposes ordered media metadata", imageFeedItem?.media?.length === 1 && imageFeedItem.media[0].media_id === media.json.media_id);
  const delivery = await rpc(graduate.token, "authorize_social_media", { p_media_ids: [media.json.media_id] });
  pass("visible post media is authorized for an active reader", delivery.status === 200 && delivery.json.length === 1);
  pass("authorized reader downloads the image", (await downloadImage(graduate.token, studentPath)).status === 200);
  pass("a user cannot attach foreign media",
    (await rpc(outsider.token, "create_social_post_v2", { p_actor_id: (await personalActor(outsider)).actor_id, p_content: "steal", p_media_ids: [media.json.media_id] })).status >= 400);

  pass("student deletes own post", (await rpc(student.token, "delete_social_post", { p_post_id: imagePost.json.post_id })).status === 200);
  pass("deleted post leaves the feed", findPost(await feed(graduate.token), imagePost.json.post_id) === null);
  pass("deleted post image becomes unreadable", (await downloadImage(graduate.token, studentPath)).status >= 400);
  const queued = sql(`select status from private.social_media_cleanup_queue q join public.social_post_media m on m.id = q.media_id where m.storage_path = '${studentPath}'`).trim();
  pass("deleted post media is queued for Storage cleanup", queued === "" ? sql(`select count(*) from private.social_media_cleanup_queue where storage_path = '${studentPath}'`) === "1" : true);
  const claim = await rpc(service, "claim_social_media_cleanup", { p_limit: 10 });
  pass("service role claims cleanup work", claim.status === 200 && claim.json.length >= 1, claim.text);
  const claimed = claim.json.find((item) => item.storage_path === studentPath);
  if (claimed) {
    await request(objectUrl(studentPath), { method: "DELETE", headers: headers(service) });
    pass("cleanup completion is recorded after the object is removed",
      (await rpc(service, "complete_social_media_cleanup", { p_id: claimed.id })).status === 200);
  } else {
    pass("cleanup claim includes the deleted post image", false, claim.json);
  }
  pass("client cannot claim cleanup work", (await rpc(graduate.token, "claim_social_media_cleanup", { p_limit: 1 })).status >= 400);

  // --- Scenario B: graduate multi-image lifecycle, comments, likes and shares ----------------------
  const gradActor = await personalActor(graduate);
  const paths = [];
  const mediaIds = [];
  for (let index = 0; index < 2; index += 1) {
    const registered = await uploadViaFunction(graduate, gradActor.actor_id, "alt " + index);
    assert.equal(registered.status, 201, "graduate image upload: " + registered.text);
    assert.ok(registered.json.storage_path.startsWith(graduate.id + "/"));
    paths.push(registered.json.storage_path);
    mediaIds.push(registered.json.media_id);
  }
  const gradPost = await rpc(graduate.token, "create_social_post_v2", {
    p_actor_id: gradActor.actor_id, p_content: "Synthetic graduate multi-image post", p_media_ids: mediaIds,
  });
  pass("graduate creates a two-image post", gradPost.status === 200 && gradPost.json.media.length === 2, gradPost.text);
  const reordered = await rpc(graduate.token, "update_social_post_v2", {
    p_post_id: gradPost.json.post_id,
    p_media: [{ media_id: mediaIds[1], alt_text: "second" }, { media_id: mediaIds[0], alt_text: "first" }],
  });
  pass("images can be reordered", reordered.status === 200 && reordered.json.media[0].media_id === mediaIds[1]);
  const trimmed = await rpc(graduate.token, "update_social_post_v2", {
    p_post_id: gradPost.json.post_id, p_media: [{ media_id: mediaIds[1] }],
  });
  pass("an image can be removed from a post", trimmed.status === 200 && trimmed.json.media.length === 1);
  pass("student cannot edit another actor's post",
    (await rpc(student.token, "update_social_post_v2", { p_post_id: gradPost.json.post_id, p_content: "hijack" })).status === 404);

  const comment = await rpc(graduate.token, "add_social_comment_v2", {
    p_post_id: gradPost.json.post_id, p_actor_id: gradActor.actor_id, p_content: "Synthetic comment",
  });
  pass("graduate comments as their actor", comment.status === 200 && Boolean(comment.json.comment_id), comment.text);
  pass("comment edit is owner-only",
    (await rpc(outsider.token, "update_social_comment_v2", { p_comment_id: comment.json.comment_id, p_content: "x" })).status === 404);
  pass("graduate edits own comment",
    (await rpc(graduate.token, "update_social_comment_v2", { p_comment_id: comment.json.comment_id, p_content: "Synthetic comment edited" })).status === 200);
  const comments = await rpc(student.token, "get_social_post_comments_v2", { p_post_id: gradPost.json.post_id });
  pass("comments are readable with actor attribution", comments.status === 200 && comments.json[0]?.actor_type === "HUMAN");
  pass("graduate deletes own comment", (await rpc(graduate.token, "delete_social_comment", { p_comment_id: comment.json.comment_id })).status === 200);

  const like = await rpc(graduate.token, "like_social_post_v2", { p_post_id: gradPost.json.post_id, p_actor_id: gradActor.actor_id });
  pass("graduate likes the post", like.status === 200 && like.json === true, like.text);
  pass("duplicate like is rejected", (await rpc(graduate.token, "like_social_post_v2", { p_post_id: gradPost.json.post_id, p_actor_id: gradActor.actor_id })).status === 409);
  pass("unlike removes the like",
    (await rpc(graduate.token, "unlike_social_post_v2", { p_post_id: gradPost.json.post_id, p_actor_id: gradActor.actor_id })).status === 200);

  // --- Scenario F: share / repost lifecycle, duplicates and moderation cascading ------------------
  const share = await rpc(graduate.token, "share_social_post", { p_actor_id: gradActor.actor_id, p_post_id: gradPost.json.post_id });
  pass("graduate shares the post", share.status === 200 && share.json.shared_post_id === gradPost.json.post_id, share.text);
  const duplicateShare = await rpc(graduate.token, "share_social_post", { p_actor_id: gradActor.actor_id, p_post_id: gradPost.json.post_id });
  pass("duplicate share is rejected", duplicateShare.status === 409 && duplicateShare.json?.message === "ALREADY_SHARED", duplicateShare.text);
  const sharedFeed = findPost(await feed(student.token), share.json.share_post_id);
  pass("share projects the original author and content", sharedFeed?.shared_post?.id === gradPost.json.post_id &&
    sharedFeed.shared_post.actor_type === "HUMAN" && sharedFeed.shared_post.media.length === 1);
  pass("share count is projected on the original", findPost(await feed(student.token), gradPost.json.post_id)?.shares_count >= 1);
  const outsiderShare = await rpc(outsider.token, "share_social_post", {
    p_actor_id: (await personalActor(outsider)).actor_id, p_post_id: gradPost.json.post_id, p_commentary: "Synthetic commentary",
  });
  pass("share with commentary is supported", outsiderShare.status === 200);
  pass("a share cannot be removed by another user",
    (await rpc(graduate.token, "unshare_social_post", { p_share_post_id: outsiderShare.json.share_post_id })).status === 404);
  pass("owner removes their own share",
    (await rpc(graduate.token, "unshare_social_post", { p_share_post_id: share.json.share_post_id })).status === 200);
  pass("removed share leaves the feed", findPost(await feed(student.token), share.json.share_post_id) === null);

  // --- Scenario C: faculty publishing without a graduate profile ----------------------------------
  pass("faculty has no graduate profile", sql(`select count(*) from public.graduate_profiles where graduate_id = '${faculty.id}'`) === "0");
  const facultyActor = await personalActor(faculty);
  const facultyPost = await rpc(faculty.token, "create_social_post_v2", { p_actor_id: facultyActor.actor_id, p_content: "Synthetic faculty post" });
  pass("faculty publishes as themselves", facultyPost.status === 200);
  const facultyFeed = findPost(await feed(student.token), facultyPost.json.post_id);
  pass("faculty post is readable by other active users", Boolean(facultyFeed));
  pass("faculty projection hides private profile fields",
    !("email" in (facultyFeed ?? {})) && !("phone" in (facultyFeed ?? {})) && !("author_profile_id" in (facultyFeed ?? {})));

  // --- Scenario D: company OWNER / RECRUITER / VIEWER and revocation ------------------------------
  const ownerActors = (await rpc(owner.token, "get_my_social_actors")).json;
  const companyActor = orgActor(ownerActors);
  pass("company OWNER sees the organization actor", companyActor?.can_publish === true && companyActor.organization_verified === true, ownerActors);
  const companyPost = await rpc(owner.token, "create_social_post_v2", { p_actor_id: companyActor.actor_id, p_content: "Synthetic company post" });
  pass("OWNER publishes as the company", companyPost.status === 200 && companyPost.json.actor_type === "ORGANIZATION", companyPost.text);
  pass("feed identifies the company publisher", findPost(await feed(student.token), companyPost.json.post_id)?.actor_verified === true);
  pass("RECRUITER publishes as the company",
    (await rpc(recruiter.token, "create_social_post_v2", { p_actor_id: companyActor.actor_id, p_content: "Synthetic recruiter post" })).status === 200);
  const viewerActors = (await rpc(viewer.token, "get_my_social_actors")).json;
  const viewerActor = (viewerActors ?? []).find((actor) => actor.actor_type === "HUMAN");
  pass("VIEWER sees the organization as read-only", orgActor(viewerActors)?.can_publish === false);
  const viewerPublish = await rpc(viewer.token, "create_social_post_v2", { p_actor_id: companyActor.actor_id, p_content: "Synthetic viewer post" });
  pass("VIEWER cannot publish as the company",
    viewerPublish.status === 403 && viewerPublish.json?.message === "SOCIAL_ACTOR_NOT_AUTHORIZED", viewerPublish.text);
  sql(`delete from public.company_memberships where company_id = '${companyId}' and user_id = '${recruiter.id}'`);
  pass("revoked RECRUITER can no longer publish for the company",
    (await rpc(recruiter.token, "create_social_post_v2", { p_actor_id: companyActor.actor_id, p_content: "Synthetic revoked post" })).status >= 403);
  sql(`update public.companies set verification_status = 'SUSPENDED' where id = '${companyId}'`);
  pass("suspended company cannot publish",
    (await rpc(owner.token, "create_social_post_v2", { p_actor_id: companyActor.actor_id, p_content: "Synthetic suspended post" })).status === 403);
  pass("suspended company content is hidden from the feed", findPost(await feed(student.token), companyPost.json.post_id) === null);
  sql(`update public.companies set verification_status = 'VERIFIED' where id = '${companyId}'`);
  pass("verified company content is restored", findPost(await feed(student.token), companyPost.json.post_id) !== null);

  // --- Scenario G: impersonation, direct writes and Storage isolation ----------------------------
  pass("faculty cannot publish as a company without membership",
    (await rpc(faculty.token, "create_social_post_v2", { p_actor_id: companyActor.actor_id, p_content: "Synthetic fake" })).status >= 403);
  pass("client-supplied actor identifiers cannot be forged",
    (await rpc(student.token, "create_social_post_v2", { p_actor_id: randomUUID(), p_content: "Synthetic forged" })).status === 404);
  pass("direct PostgREST reads of raw social tables are denied",
    (await request("/rest/v1/social_posts?select=id", { headers: headers(student.token) })).status >= 400);
  pass("direct PostgREST writes of raw social tables are denied",
    (await request("/rest/v1/social_posts", {
      method: "POST",
      headers: headers(student.token, { "Content-Type": "application/json" }),
      body: JSON.stringify({ author_profile_id: student.id, content: "direct" }),
    })).status >= 400);
  pass("Storage rejects an upload into another user's namespace",
    (await uploadImage(student, `${graduate.id}/ci-${randomUUID()}.png`)).status >= 400);
  pass("Storage rejects an unowned object read",
    (await downloadImage(student.token, `${owner.id}/ci-${randomUUID()}.png`)).status >= 400);

  // --- Scenario H: reports, moderation and image retraction --------------------------------------
  const report = await rpc(student.token, "create_social_content_report", {
    p_target_type: "POST", p_target_id: gradPost.json.post_id, p_category: "HARASSMENT", p_details: "Synthetic report",
  });
  pass("active user reports a post", report.status === 200, report.text);
  pass("duplicate report is rejected",
    (await rpc(student.token, "create_social_content_report", {
      p_target_type: "POST", p_target_id: gradPost.json.post_id, p_category: "HARASSMENT",
    })).status === 409);
  pass("reports are not readable through the raw table",
    (await request("/rest/v1/social_content_reports?select=id", { headers: headers(student.token) })).status >= 400);
  pass("non-moderator cannot read the moderation queue",
    (await rpc(student.token, "get_social_moderation_queue", {})).status >= 400);
  sql(`insert into private.platform_admins (user_id) values ('${faculty.id}') on conflict do nothing`);
  const queue = await rpc(faculty.token, "get_social_moderation_queue", { p_status: "OPEN", p_limit: 50 });
  pass("moderator reads the open report queue", queue.status === 200 && queue.json.some((row) => row.report_id === report.json[0].report_id), queue.text);
  const hide = await rpc(faculty.token, "moderate_social_report", {
    p_report_id: report.json[0].report_id, p_action: "HIDE", p_reason: "Synthetic moderation reason",
  });
  pass("moderator hides the reported post",
    hide.status === 200 && hide.json[0]?.content_moderation_status === "HIDDEN", hide.text);
  pass("hidden post disappears from the feed", findPost(await feed(student.token), gradPost.json.post_id) === null);
  pass("shares of a hidden post disappear too", findPost(await feed(student.token), outsiderShare.json.share_post_id) === null);
  const hiddenPath = paths[1];
  pass("hidden post image is no longer downloadable", (await downloadImage(student.token, hiddenPath)).status >= 400);
  pass("author cannot bypass hiding by an edit",
    (await rpc(graduate.token, "update_social_post_v2", { p_post_id: gradPost.json.post_id, p_content: "bypass" })).status >= 400);
  const restore = await rpc(faculty.token, "restore_social_content", {
    p_target_type: "POST", p_target_id: gradPost.json.post_id, p_reason: "Synthetic restore reason",
  });
  pass("moderator restores the content", restore.status === 200);
  pass("restored post is readable again", findPost(await feed(student.token), gradPost.json.post_id) !== null);
  pass("restored image is downloadable again", (await downloadImage(student.token, hiddenPath)).status === 200);
  const audit = sql(`select count(*) from private.social_moderation_events where target_id = '${gradPost.json.post_id}'`);
  pass("moderation audit history is preserved", Number(audit) >= 2);

  // --- Scenario I: media validation and suspended accounts ---------------------------------------
  const invalidBytes = Buffer.from("<!doctype html><script>alert(1)</script>");
  const invalidUpload = await uploadViaFunction(student, studentActor.actor_id, "invalid", invalidBytes, "image/png");
  pass("HTML bytes labelled as PNG are rejected by the Edge Function",
    invalidUpload.status === 422 && invalidUpload.json?.error === "SOCIAL_MEDIA_INVALID", invalidUpload.text);
  const mismatchedUpload = await uploadViaFunction(student, studentActor.actor_id, "mismatch", PNG, "image/jpeg");
  pass("a declared MIME mismatch is rejected", mismatchedUpload.status === 422, mismatchedUpload.text);
  const emptyRegistration = await rpc(student.token, "register_social_media", {
    p_actor_id: studentActor.actor_id, p_storage_path: `${student.id}/ci-${randomUUID()}.png`,
    p_mime_type: "image/png", p_size_bytes: 0, p_width: 1, p_height: 1,
  });
  pass("metadata without a real uploaded object is rejected", emptyRegistration.status >= 400);
  const foreignRegistration = await registerMedia(student, studentActor.actor_id, `${graduate.id}/ci-${randomUUID()}.png`);
  pass("metadata cannot reference another user's namespace", foreignRegistration.status >= 400);
  sql(`update public.profiles set account_status = 'SUSPENDED' where id = '${viewer.id}'`);
  pass("suspended account cannot publish",
    (await rpc(viewer.token, "create_social_post_v2", { p_actor_id: viewerActor.actor_id, p_content: "Synthetic suspended" })).status === 403);
  pass("suspended account cannot like",
    (await rpc(viewer.token, "like_social_post_v2", { p_post_id: gradPost.json.post_id, p_actor_id: viewerActor.actor_id })).status === 403);
  sql(`update public.profiles set account_status = 'ACTIVE' where id = '${viewer.id}'`);

  console.log(`SOCIAL FEED HTTP INTEGRATION PASSED (${passed} assertions)`);
}

async function cleanup() {
  for (const id of createdCompanies) {
    try { sql(`delete from public.companies where id = '${id}'`); } catch { /* best effort */ }
  }
  for (const id of createdUsers) {
    try { sql(`delete from auth.users where id = '${id}'`); } catch { /* best effort */ }
  }
}

try {
  await main();
} finally {
  await cleanup();
}
