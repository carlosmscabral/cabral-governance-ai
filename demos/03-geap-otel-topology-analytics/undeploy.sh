#!/usr/bin/env bash
# ==============================================================================
# Complete Teardown Script — Zero Residuals
# Demo 03: End-to-End Multi-Agent OTel, Live Topology & BigQuery Agent Analytics
# ==============================================================================

set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"

log_banner "Desprovisionamento Completo (Zero Residuals): Demo 03 Observabilidade"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)

# 1. Remove App Hub Application & Registered Services
log_step "1. Removendo Aplicação App Hub (${APPHUB_APP_ID})..."
if gcloud apphub applications describe "${APPHUB_APP_ID}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    for svc_id in $(gcloud apphub applications services list --application="${APPHUB_APP_ID}" --location="${REGION}" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null || true); do
        gcloud apphub applications services delete "${svc_id}" --quiet &>/dev/null || true
    done
    for wl_id in $(gcloud apphub applications workloads list --application="${APPHUB_APP_ID}" --location="${REGION}" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null || true); do
        gcloud apphub applications workloads delete "${wl_id}" --quiet &>/dev/null || true
    done
    gcloud apphub applications delete "${APPHUB_APP_ID}" --location="${REGION}" --project="${PROJECT_ID}" --quiet || true
    log_success "App Hub '${APPHUB_APP_ID}' removido."
else
    log_info "App Hub '${APPHUB_APP_ID}' já estava ausente."
fi

# 2. Delete Vertex AI Reasoning Engine(s) matching RE_DISPLAY_NAME
log_step "2. Removendo Vertex AI Reasoning Engine (${RE_DISPLAY_NAME})..."
RE_IDS=()
if [[ -f "${STATE_DIR}/agent_info.json" ]]; then
    SAVED_ID=$(jq -r '.engine_id // empty' "${STATE_DIR}/agent_info.json" 2>/dev/null || true)
    [[ -n "${SAVED_ID}" ]] && RE_IDS+=("${SAVED_ID}")
fi
if [[ -n "${TOKEN}" ]]; then
    DISCOVERED_IDS=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" | \
        jq -r '.reasoningEngines[]? | select(.displayName=="'"${RE_DISPLAY_NAME}"'") | .name' | awk -F'/' '{print $NF}' || true)
    for id in ${DISCOVERED_IDS}; do
        RE_IDS+=("${id}")
    done
fi

UNIQUE_RE_IDS=$(printf "%s\n" "${RE_IDS[@]:-}" | sort -u | sed '/^$/d' || true)
for engine_id in ${UNIQUE_RE_IDS}; do
    log_info "Excluindo Reasoning Engine ID '${engine_id}' (force=true)..."
    curl -s -X DELETE \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${engine_id}?force=true" >/dev/null || true

    if [[ -n "${ORG_ID}" ]]; then
        RE_SPIFFE="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${engine_id}"
        for role in "roles/aiplatform.user" "roles/telemetry.writer" "roles/telemetry.tracesWriter" "roles/telemetry.metricsWriter" "roles/cloudtrace.agent" "roles/logging.logWriter" "roles/monitoring.metricWriter" "roles/bigquery.dataEditor" "roles/bigquery.jobUser" "roles/browser"; do
            gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member="${RE_SPIFFE}" --role="${role}" --quiet &>/dev/null || true
        done
    fi
done

# 3. Delete Cloud Run Services (Node 2 A2A + Node 3 FastMCP) & SPIFFE bindings
log_step "3. Removendo Serviços Cloud Run (${A2A_SERVICE_NAME} & ${MCP_SERVICE_NAME})..."
for svc in "${A2A_SERVICE_NAME}" "${MCP_SERVICE_NAME}"; do
    if gcloud run services describe "${svc}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud run services delete "${svc}" --region="${REGION}" --project="${PROJECT_ID}" --quiet || true
        log_success "Cloud Run '${svc}' removido."
    else
        log_info "Cloud Run '${svc}' já estava ausente."
    fi
done

if [[ -n "${ORG_ID}" ]]; then
    A2A_SPIFFE="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/run/projects/${PROJECT_NUMBER}/locations/${REGION}/services/${A2A_SERVICE_NAME}"
    for role in "roles/aiplatform.user" "roles/telemetry.writer" "roles/telemetry.tracesWriter" "roles/telemetry.metricsWriter" "roles/cloudtrace.agent" "roles/logging.logWriter" "roles/monitoring.metricWriter" "roles/browser"; do
        gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member="${A2A_SPIFFE}" --role="${role}" --quiet &>/dev/null || true
    done
fi

# 4. Delete Service Accounts & IAM Bindings
log_step "4. Removendo Service Accounts dedicadas (${MCP_RUNTIME_SA_NAME} & ${CR_INVOKER_SA_NAME})..."
for role in "roles/telemetry.writer" "roles/telemetry.tracesWriter" "roles/cloudtrace.agent" "roles/logging.logWriter" "roles/monitoring.metricWriter" "roles/browser"; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member="serviceAccount:${MCP_RUNTIME_SA}" --role="${role}" --quiet &>/dev/null || true
done

for sa in "${MCP_RUNTIME_SA}" "${CR_INVOKER_SA}"; do
    if gcloud iam service-accounts describe "${sa}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud iam service-accounts delete "${sa}" --project="${PROJECT_ID}" --quiet || true
        log_success "Service Account '${sa}' removida."
    fi
done

# 5. Delete Linked Trace Dataset & BigQuery Dataset
log_step "5. Removendo Linked Dataset de Trace e Dataset BigQuery '${BQ_DATASET}'..."
TRACE_OBS_DATASET=$(gcloud observability buckets datasets list --bucket="_Trace" --location="global" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null | head -n 1 | awk -F'/' '{print $NF}' || true)
if [[ -n "${TRACE_OBS_DATASET}" ]]; then
    gcloud observability buckets datasets links delete "${BQ_TRACES_LINKED_DATASET}" \
        --bucket="_Trace" \
        --dataset="${TRACE_OBS_DATASET}" \
        --location="global" \
        --project="${PROJECT_ID}" \
        --quiet &>/dev/null || true
fi

if bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${BQ_DATASET}" &>/dev/null; then
    bq --project_id="${PROJECT_ID}" rm -r -f -d "${PROJECT_ID}:${BQ_DATASET}" || true
    log_success "Dataset BigQuery '${BQ_DATASET}' removido."
fi

# 6. Delete GCS Buckets & Local State
log_step "6. Removendo Buckets GCS e estado local (.state)..."
for bkt in "${STAGING_BUCKET}" "${TELEMETRY_BUCKET}"; do
    if gcloud storage buckets describe "gs://${bkt}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud storage rm --recursive "gs://${bkt}" --quiet &>/dev/null || true
    fi
done

rm -rf "${STATE_DIR}"
log_banner "Teardown Concluído (Zero Residuals)!"
