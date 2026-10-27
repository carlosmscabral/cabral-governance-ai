#!/usr/bin/env bash
# ==============================================================================
# Master Teardown & Zero-Residual Cleanup Script
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
# ==============================================================================

set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Iniciando Desprovisionamento Completo Demo 02 (Zero-Residuals)"

TOKEN=$(gcloud auth print-access-token)

# ------------------------------------------------------------------------------
# 1. Delete Vertex AI Reasoning Engine & Clear SPIFFE IAM Bindings
# ------------------------------------------------------------------------------
log_step "1. Removendo Reasoning Engine '${RE_DISPLAY_NAME}' do Vertex AI..."

AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
RE_ENGINE_ID=""
AGENT_SPIFFE=""
if [[ -f "${AGENT_INFO_FILE}" ]]; then
    RE_ENGINE_ID=$(jq -r '.engine_id // empty' "${AGENT_INFO_FILE}")
    AGENT_SPIFFE=$(jq -r '.agent_identity // empty' "${AGENT_INFO_FILE}")
fi

if [[ -z "${RE_ENGINE_ID}" ]]; then
    RE_ENGINE_ID=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" | \
        jq -r '.reasoningEngines[]? | select(.displayName=="'"${RE_DISPLAY_NAME}"'") | .name' | awk -F'/' '{print $NF}' | head -n 1 || true)
fi

if [[ -n "${RE_ENGINE_ID}" ]]; then
    log_info "Deletando Reasoning Engine '${RE_ENGINE_ID}'..."
    curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}?force=true" >/dev/null || true

    if [[ -z "${AGENT_SPIFFE}" ]]; then
        ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --filter="type:organization" --format="value(id)" 2>/dev/null || true)
        if [[ -n "${ORG_ID}" ]]; then
            AGENT_SPIFFE="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}"
        else
            AGENT_SPIFFE="principal://agents.global.project-${PROJECT_NUMBER}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}"
        fi
    fi

    for role in \
        "roles/aiplatform.user" \
        "roles/agentregistry.viewer" \
        "roles/cloudtrace.agent" \
        "roles/telemetry.writer" \
        "roles/logging.logWriter" \
        "roles/monitoring.metricWriter" \
        "roles/browser"; do
        gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
            --member="${AGENT_SPIFFE}" \
            --role="${role}" \
            --condition=None \
            --quiet &>/dev/null || true
    done
    log_success "Reasoning Engine e bindings SPIFFE removidos."
else
    log_info "Nenhum Reasoning Engine ativo encontrado."
fi

# ------------------------------------------------------------------------------
# 2. Clear IAP Egress Policies & Remove Agent Registry Services
# ------------------------------------------------------------------------------
log_step "2. Limpando políticas IAP e removendo serviços do Agent Registry..."

EMPTY_IAP_FILE="${STATE_DIR}/iap-empty.json"
mkdir -p "${STATE_DIR}"

# Clear MCP Server IAP policy & delete service
MCP_REG_ID=$(gcloud agent-registry services describe "${MCP_REGISTRY_SERVICE_NAME}" \
    --project="${PROJECT_ID}" --location="${REGION}" \
    --format="value(registryResource.basename())" 2>/dev/null || true)
if [[ -n "${MCP_REG_ID}" ]]; then
    ETAG=$(gcloud beta iap web get-iam-policy --project="${PROJECT_ID}" --region="${REGION}" --resource-type=agent-registry --mcp-server="${MCP_REG_ID}" --format="value(etag)" 2>/dev/null || true)
    if [[ -n "${ETAG}" ]]; then
        printf '{"bindings": [], "etag": "%s"}\n' "${ETAG}" > "${EMPTY_IAP_FILE}"
        gcloud beta iap web set-iam-policy "${EMPTY_IAP_FILE}" \
            --project="${PROJECT_ID}" --region="${REGION}" \
            --resource-type=agent-registry --mcp-server="${MCP_REG_ID}" --quiet &>/dev/null || true
    fi
    gcloud agent-registry services delete "${MCP_REGISTRY_SERVICE_NAME}" \
        --project="${PROJECT_ID}" --location="${REGION}" --quiet || true
    log_success "Serviço MCP '${MCP_REGISTRY_SERVICE_NAME}' removido do Agent Registry."
fi

# Clear Core GAPI Endpoint IAP policy & delete service
GAPI_REG_ID=$(gcloud agent-registry services describe "${GAPI_SERVICE_NAME}" \
    --project="${PROJECT_ID}" --location="${REGION}" \
    --format="value(registryResource.basename())" 2>/dev/null || true)
if [[ -n "${GAPI_REG_ID}" ]]; then
    ETAG=$(gcloud beta iap web get-iam-policy --project="${PROJECT_ID}" --region="${REGION}" --resource-type=agent-registry --endpoint="${GAPI_REG_ID}" --format="value(etag)" 2>/dev/null || true)
    if [[ -n "${ETAG}" ]]; then
        printf '{"bindings": [], "etag": "%s"}\n' "${ETAG}" > "${EMPTY_IAP_FILE}"
        gcloud beta iap web set-iam-policy "${EMPTY_IAP_FILE}" \
            --project="${PROJECT_ID}" --region="${REGION}" \
            --resource-type=agent-registry --endpoint="${GAPI_REG_ID}" --quiet &>/dev/null || true
    fi
    gcloud agent-registry services delete "${GAPI_SERVICE_NAME}" \
        --project="${PROJECT_ID}" --location="${REGION}" --quiet || true
    log_success "Serviço '${GAPI_SERVICE_NAME}' removido do Agent Registry."
fi

# ------------------------------------------------------------------------------
# 3. Delete Network Security AuthzPolicy, IAP Service Extensions & Agent Gateway
# ------------------------------------------------------------------------------
log_step "3. Deletando AuthzPolicy, Service Extensions IAP e Agent Gateway Egress..."

if gcloud beta network-security authz-policies describe "${AUTHZ_POLICY_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud beta network-security authz-policies delete "${AUTHZ_POLICY_NAME}" \
        --location="${REGION}" --project="${PROJECT_ID}" --quiet
    log_success "AuthzPolicy '${AUTHZ_POLICY_NAME}' removida."
fi

for ext in "${AUTHZ_EXT_ENFORCED}" "${AUTHZ_EXT_DRYRUN}"; do
    if gcloud service-extensions authz-extensions describe "${ext}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud service-extensions authz-extensions delete "${ext}" \
            --location="${REGION}" --project="${PROJECT_ID}" --quiet
        log_success "Service Extension '${ext}' removida."
    fi
done

if gcloud network-services agent-gateways describe "${AGW_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud network-services agent-gateways delete "${AGW_NAME}" \
        --location="${REGION}" --project="${PROJECT_ID}" --quiet
    log_success "Agent Gateway '${AGW_NAME}' removido."
fi

# ------------------------------------------------------------------------------
# 4. Delete Cloud Run MCP Server & Invoker Service Account
# ------------------------------------------------------------------------------
log_step "4. Removendo servidor MCP no Cloud Run e Service Account de invocação..."

if gcloud run services describe "${MCP_SERVICE_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud run services delete "${MCP_SERVICE_NAME}" \
        --region="${REGION}" --project="${PROJECT_ID}" --quiet
    log_success "Serviço Cloud Run '${MCP_SERVICE_NAME}' removido."
fi

if gcloud iam service-accounts describe "${MCP_INVOKER_SA}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud iam service-accounts delete "${MCP_INVOKER_SA}" \
        --project="${PROJECT_ID}" --quiet
    log_success "Service Account '${MCP_INVOKER_SA}' removida."
fi

# ------------------------------------------------------------------------------
# 5. Delete Staging Bucket & Local State
# ------------------------------------------------------------------------------
log_step "5. Removendo bucket de staging 'gs://${STAGING_BUCKET}' e estado local..."

if gcloud storage buckets describe "gs://${STAGING_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud storage rm --recursive "gs://${STAGING_BUCKET}" --quiet 2>/dev/null || true
    log_success "Bucket 'gs://${STAGING_BUCKET}' removido."
fi

rm -rf "${STATE_DIR}"
log_success "Diretório '.state' limpo."

log_banner "Desprovisionamento Concluído Sem Resíduos (Zero-Residuals)!"
