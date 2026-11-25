import {
  parseCompetitionProviderConfigs,
  sendCompetitionApplicationToProvider,
  CompetitionProviderError,
} from "./competition-provider.ts";

type ClaimedDelivery = {
  outbox_id: string;
  application_id: string;
  provider_key: string | null;
  external_opportunity_id: string | null;
  attempt_number: number;
  idempotency_key: string;
  request_payload: Record<string, unknown>;
  cv_storage_path: string | null;
};

type DeliveryResult = {
  application_id: string;
  status: "SUBMITTED_EXTERNALLY" | "PENDING_DELIVERY" | "DELIVERY_FAILED" | "BLOCKED";
  delivery_status: "DELIVERED" | "PENDING" | "FAILED" | "BLOCKED";
  provider_application_reference?: string;
  error_code?: string;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const safeErrorCode = (value: string) =>
  /^[A-Z0-9_]{1,64}$/.test(value) ? value : "PROVIDER_ADAPTER_ERROR";

export async function deliverCompetitionApplications(
  admin: any,
  options: { applicationId?: string | null; limit?: number } = {},
): Promise<DeliveryResult[]> {
  const applicationId = options.applicationId ?? null;
  const limit = options.limit ?? 10;
  if (applicationId !== null && !UUID.test(applicationId)) {
    throw new Error("INVALID_APPLICATION_ID");
  }
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) {
    throw new Error("INVALID_DELIVERY_BATCH_SIZE");
  }

  let configs: ReturnType<typeof parseCompetitionProviderConfigs> = {};
  let configurationInvalid = false;
  try {
    configs = parseCompetitionProviderConfigs(Deno.env.get("COMPETITION_PROVIDERS_JSON"));
  } catch {
    configurationInvalid = true;
  }

  const { data, error: claimError } = await admin.rpc("claim_competition_delivery", {
    p_application_id: applicationId,
    p_limit: limit,
  });
  if (claimError) throw new Error("COMPETITION_DELIVERY_CLAIM_FAILED");
  const claimed = (Array.isArray(data) ? data : data ? [data] : []) as ClaimedDelivery[];
  const results: DeliveryResult[] = [];

  for (const item of claimed) {
    const providerKey = item.provider_key ?? "";
    if (configurationInvalid || !providerKey || !item.external_opportunity_id || !configs[providerKey]) {
      const code = configurationInvalid ? "PROVIDER_CONFIGURATION_INVALID"
        : !providerKey || !item.external_opportunity_id
        ? "PROVIDER_MAPPING_MISSING"
        : "PROVIDER_NOT_CONFIGURED";
      const { error: blockError } = await admin.rpc("block_competition_delivery", {
        p_outbox_id: item.outbox_id,
        p_error_code: code,
      });
      if (blockError) {
        results.push({
          application_id: item.application_id,
          status: "PENDING_DELIVERY",
          delivery_status: "BLOCKED",
          error_code: "DELIVERY_STATE_UPDATE_FAILED",
        });
      } else {
        results.push({
          application_id: item.application_id,
          status: "PENDING_DELIVERY",
          delivery_status: "BLOCKED",
          error_code: code,
        });
      }
      continue;
    }

    try {
      const payload = { ...item.request_payload };
      let cvDownloadUrl: string | null = null;
      if (item.cv_storage_path) {
        const graduateId = typeof payload.graduate_id === "string" ? payload.graduate_id : "";
        if (!UUID.test(graduateId) ||
            !item.cv_storage_path.startsWith(graduateId + "/") ||
            item.cv_storage_path.includes("..")) {
          throw new CompetitionProviderError("CV_STORAGE_PATH_INVALID", false);
        }
        const { data: signed, error: signError } = await admin.storage
          .from("cv-documents")
          .createSignedUrl(item.cv_storage_path, 600);
        if (signError || !signed?.signedUrl) {
          throw new CompetitionProviderError("CV_SIGNED_URL_FAILED", true);
        }
        cvDownloadUrl = signed.signedUrl;
      } else if (payload.cv_document_id) {
        throw new CompetitionProviderError("CV_STORAGE_OBJECT_MISSING", false);
      }

      payload.cv_download_url = cvDownloadUrl;
      // Internal database identifiers are not disclosed to the external competition provider.
      delete payload.graduate_id;
      delete payload.cv_document_id;
      const ack = await sendCompetitionApplicationToProvider(
        configs[providerKey],
        item.idempotency_key,
        payload,
      );
      const { data: completed, error: completeError } = await admin.rpc(
        "complete_competition_delivery",
        {
          p_outbox_id: item.outbox_id,
          p_provider_reference: ack.application_reference,
          p_http_status: ack.http_status,
          p_request_id: ack.request_id,
        },
      );
      if (completeError) {
        if (completeError.message?.includes("COMPETITION_PROVIDER_REFERENCE_CONFLICT")) {
          throw new CompetitionProviderError("PROVIDER_REFERENCE_CONFLICT", false, ack.http_status);
        }
        // Provider may have accepted the idempotent request. Keep this retryable; the same
        // Idempotency-Key will be reused and a compliant provider returns the same reference.
        throw new CompetitionProviderError("DELIVERY_ACK_PERSIST_FAILED", true, ack.http_status);
      }
      results.push({
        application_id: item.application_id,
        status: "SUBMITTED_EXTERNALLY",
        delivery_status: "DELIVERED",
        provider_application_reference:
          completed?.provider_application_reference ?? ack.application_reference,
      });
    } catch (error) {
      const providerError = error instanceof CompetitionProviderError
        ? error
        : new CompetitionProviderError("PROVIDER_ADAPTER_ERROR", true);
      const { data: failureState, error: failureError } = await admin.rpc(
        "fail_competition_delivery",
        {
          p_outbox_id: item.outbox_id,
          p_error_code: safeErrorCode(providerError.code),
          p_http_status: providerError.httpStatus,
          p_retryable: providerError.retryable,
          p_retry_after_seconds: providerError.retryAfterSeconds,
        },
      );
      if (failureError) {
        results.push({
          application_id: item.application_id,
          status: "PENDING_DELIVERY",
          delivery_status: "PENDING",
          error_code: "DELIVERY_STATE_UPDATE_FAILED",
        });
      } else if (failureState === "FAILED") {
        results.push({
          application_id: item.application_id,
          status: "DELIVERY_FAILED",
          delivery_status: "FAILED",
          error_code: safeErrorCode(providerError.code),
        });
      } else {
        results.push({
          application_id: item.application_id,
          status: "PENDING_DELIVERY",
          delivery_status: "PENDING",
          error_code: safeErrorCode(providerError.code),
        });
      }
    }
  }
  return results;
}
