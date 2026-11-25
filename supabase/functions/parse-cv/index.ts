// POST /functions/v1/parse-cv { "cv_document_id": "<uuid>" }
// Reads only the authenticated graduate's private CV. Extracted skills remain suggestions
// until that same graduate explicitly calls confirm_cv_suggestions.
import { createClient } from "@supabase/supabase-js";
import { hasActiveAccount, isBannedAuthError } from "../_shared/account-status.ts";
import { extractSkillsFromText, validateExtraction } from "../_shared/cv-extract.ts";
import { extractStructuredCvData } from "../_shared/cv-structured-extract.ts";
import { CvFileError, extractCvText } from "../_shared/cv-file-parser.ts";

const json = (body: unknown, status = 200, extraHeaders: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extraHeaders },
  });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_FILE_BYTES = 5 * 1024 * 1024;

function statusFor(code: string): number {
  if (code === "CV_DOCUMENT_NOT_FOUND") return 404;
  if (code === "CV_ALREADY_PROCESSING" || code === "CV_ALREADY_PARSED") return 409;
  if (code === "CV_DOWNLOAD_FAILED") return 502;
  if (code === "CV_DOCUMENT_TOO_LARGE") return 413;
  if ([
    "CV_FILE_TYPE_MISMATCH", "CV_SIZE_MISMATCH", "CV_INVALID_FILE",
    "CV_NO_TEXT_FOUND", "CV_TOO_MANY_PAGES", "INVALID_CV_SUGGESTIONS",
    "CV_SKILL_NOT_FOUND",
  ].includes(code)) return 422;
  return 500;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);

  const authorization = req.headers.get("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    if (isBannedAuthError(authError)) return json({ error: "ACCOUNT_UNAVAILABLE" }, 403);
    return json({ error: "UNAUTHENTICATED" }, 401);
  }
  if (!(await hasActiveAccount(userClient, user.id))) {
    return json({ error: "ACCOUNT_UNAVAILABLE" }, 403);
  }

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object" || Array.isArray(body)
      || Object.keys(body).length !== 1 || !("cv_document_id" in body)
      || typeof body.cv_document_id !== "string" || !UUID.test(body.cv_document_id)) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  let processingStarted = false;
  const cvDocumentId = body.cv_document_id as string;
  try {
    const { data: document, error: readError } = await userClient
      .from("cv_documents")
      .select("id,graduate_id,storage_path,file_type,size_bytes,parse_status,parsed_at")
      .eq("id", cvDocumentId)
      .maybeSingle();
    if (readError) return json({ error: "CV_LOOKUP_FAILED" }, 500);
    if (!document || document.graduate_id !== user.id) return json({ error: "CV_DOCUMENT_NOT_FOUND" }, 404);
    if (document.size_bytes < 1 || document.size_bytes > MAX_FILE_BYTES) {
      return json({ error: "CV_DOCUMENT_TOO_LARGE" }, 413);
    }
    if (document.file_type !== "pdf" && document.file_type !== "docx") {
      return json({ error: "CV_FILE_TYPE_MISMATCH" }, 422);
    }
    if (!document.storage_path.startsWith(user.id + "/")
        || document.storage_path.includes("..")) {
      return json({ error: "CV_DOCUMENT_NOT_FOUND" }, 404);
    }

    const { data: claimed, error: claimError } = await admin
      .from("cv_documents")
      .update({ parse_status: "PROCESSING", error_message: null, parsed_at: null })
      .eq("id", cvDocumentId)
      .eq("graduate_id", user.id)
      .in("parse_status", ["PENDING", "FAILED"])
      .select("id")
      .maybeSingle();
    if (claimError) return json({ error: "CV_PROCESSING_CLAIM_FAILED" }, 500);
    if (!claimed) {
      const current = await userClient.from("cv_documents")
        .select("parse_status").eq("id", cvDocumentId).maybeSingle();
      const code = current.data?.parse_status === "PROCESSING"
        ? "CV_ALREADY_PROCESSING"
        : current.data?.parse_status === "DONE" ? "CV_ALREADY_PARSED" : "CV_DOCUMENT_NOT_FOUND";
      return json({ error: code }, code === "CV_DOCUMENT_NOT_FOUND" ? 404 : 409);
    }
    processingStarted = true;

    // The claim is acquired before charging quota: duplicate/concurrent requests that
    // do no parsing work are rejected by the state machine and do not burn a token.
    const { data: retryAfter, error: rateLimitError } = await admin.rpc("consume_edge_rate_limit", {
      p_user_id: user.id,
      p_action: "CV_PARSE",
    });
    if (rateLimitError) {
      await admin.from("cv_documents")
        .update({ parse_status: document.parse_status, error_message: null, parsed_at: null })
        .eq("id", cvDocumentId).eq("graduate_id", user.id).eq("parse_status", "PROCESSING");
      processingStarted = false;
      return json({ error: "RATE_LIMIT_UNAVAILABLE" }, 503);
    }
    const retrySeconds = Math.max(0, Number(retryAfter ?? 0));
    if (retrySeconds > 0) {
      await admin.from("cv_documents")
        .update({ parse_status: document.parse_status, error_message: null, parsed_at: document.parsed_at })
        .eq("id", cvDocumentId).eq("graduate_id", user.id).eq("parse_status", "PROCESSING");
      processingStarted = false;
      return json(
        { error: "RATE_LIMIT_EXCEEDED", retry_after_seconds: retrySeconds },
        429,
        { "Retry-After": String(retrySeconds) },
      );
    }

    const { data: file, error: downloadError } = await userClient.storage
      .from("cv-documents")
      .download(document.storage_path);
    if (downloadError || !file) throw new CvFileError("CV_DOWNLOAD_FAILED");

    const bytes = new Uint8Array(await file.arrayBuffer());
    if (bytes.length !== document.size_bytes) throw new CvFileError("CV_SIZE_MISMATCH");
    if (bytes.length > MAX_FILE_BYTES) throw new CvFileError("CV_DOCUMENT_TOO_LARGE");

    const text = await extractCvText(bytes, document.file_type);
    const { data: skills, error: skillsError } = await userClient
      .from("skills")
      .select("id,canonical_name,aliases");
    if (skillsError || !skills) throw new Error("SKILL_DICTIONARY_FAILED");

    const dictionary = skills.map((skill) => ({
      id: skill.id,
      canonical_name: skill.canonical_name,
      aliases: Array.isArray(skill.aliases) ? skill.aliases : [],
    }));
    const extracted = extractSkillsFromText(text, dictionary);
    const allowedSkillIds = new Set(dictionary.map((skill) => skill.id));
    const validated = validateExtraction({
      skills: extracted.map((item) => ({ skill_id: item.skill_id })),
    }, allowedSkillIds);
    if (validated.errors.length > 0) throw new Error("EXTRACTION_VALIDATION_FAILED");

    const structured = extractStructuredCvData(text);
    const suggestions = [
      ...extracted.map((item) => ({
        kind: "SKILL",
        payload: { skill_id: item.skill_id, matched_term: item.matched_term },
      })),
      ...structured.experiences.map((item) => ({ kind: "EXPERIENCE", payload: item })),
      ...structured.certifications.map((item) => ({ kind: "CERTIFICATION", payload: item })),
      ...structured.courses.map((item) => ({ kind: "COURSE", payload: item })),
    ].slice(0, 200);
    const { data: savedCount, error: saveError } = await admin.rpc("complete_cv_parse", {
      p_cv_document_id: cvDocumentId,
      p_graduate_id: user.id,
      p_suggestions: suggestions,
    });
    if (saveError) throw new Error("CV_FINALIZATION_FAILED");
    processingStarted = false;

    return json({
      cv_document_id: cvDocumentId,
      status: "DONE",
      suggestions_count: Number(savedCount ?? 0),
      suggestion_counts: {
        skills: extracted.length,
        experience: structured.experiences.length,
        certifications: structured.certifications.length,
        courses: structured.courses.length,
      },
      suggestions,
      confirmation_required: true,
      review_rpc: "review_cv_suggestions",
      extraction_mode: "local_dictionary_and_section_rules",
    });
  } catch (error) {
    const code = error instanceof CvFileError
      ? error.code
      : error instanceof Error && error.message.startsWith("CV_")
        ? error.message : "CV_PROCESSING_FAILED";
    if (processingStarted) {
      await admin.from("cv_documents")
        .update({ parse_status: "FAILED", error_message: code, parsed_at: null })
        .eq("id", cvDocumentId)
        .eq("graduate_id", user.id)
        .eq("parse_status", "PROCESSING");
    }
    return json({ error: code }, statusFor(code));
  }
});
