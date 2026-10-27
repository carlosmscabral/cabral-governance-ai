#!/usr/bin/env bash
# ==============================================================================
# Script 04: Deploy ADK Agent to Vertex AI Reasoning Engine (Egress Governed) & Bind IAM
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 04: Deploy do Agente ADK FinOps no Vertex AI Reasoning Engine & Identidade SPIFFE"

MCP_INFO_FILE="${STATE_DIR}/mcp_info.json"
if [[ ! -f "${MCP_INFO_FILE}" ]]; then
    log_error "Arquivo '${MCP_INFO_FILE}' não encontrado. Execute 02_deploy_mcp_server.sh primeiro."
    exit 1
fi
MCP_URL=$(jq -r '.mcp_url' "${MCP_INFO_FILE}")

# ------------------------------------------------------------------------------
# 1. Provision Staging Bucket
# ------------------------------------------------------------------------------
log_step "1. Verificando bucket de staging 'gs://${STAGING_BUCKET}'..."
if gcloud storage buckets describe "gs://${STAGING_BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Bucket de staging 'gs://${STAGING_BUCKET}' já existe."
else
    gcloud storage buckets create "gs://${STAGING_BUCKET}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --uniform-bucket-level-access \
        --quiet
    log_success "Bucket de staging criado!"
fi

# ------------------------------------------------------------------------------
# 2. Ensure Local Python Virtual Environment (.venv) with ADK + MCP SDK
# ------------------------------------------------------------------------------
log_step "2. Preparando ambiente virtual Python (.venv) com ADK e MCP SDK..."
VENV_DIR="${DEMO_ROOT}/.venv"
if [[ ! -f "${VENV_DIR}/bin/python" ]]; then
    if command -v uv &>/dev/null; then
        uv venv "${VENV_DIR}" --python python3
        uv pip install --python "${VENV_DIR}/bin/python" \
            "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" \
            "google-auth>=2.35.0" \
            "mcp>=1.26.0,<2.0.0" \
            "httpx>=0.28.0"
    else
        python3 -m venv "${VENV_DIR}"
        "${VENV_DIR}/bin/pip" install \
            "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" \
            "google-auth>=2.35.0" \
            "mcp>=1.26.0,<2.0.0" \
            "httpx>=0.28.0"
    fi
else
    # Ensure mcp is installed even if .venv existed
    if ! "${VENV_DIR}/bin/python" -c "import mcp" &>/dev/null; then
        if command -v uv &>/dev/null; then
            uv pip install --python "${VENV_DIR}/bin/python" "mcp>=1.26.0,<2.0.0" "httpx>=0.28.0"
        else
            "${VENV_DIR}/bin/pip" install "mcp>=1.26.0,<2.0.0" "httpx>=0.28.0"
        fi
    fi
fi
PYTHON_EXEC="${VENV_DIR}/bin/python"

# ------------------------------------------------------------------------------
# 3. Check for Existing Reasoning Engine & Detect Drift (MODEL_NAME / MCP_URL)
# ------------------------------------------------------------------------------
log_step "3. Verificando Reasoning Engine '${RE_DISPLAY_NAME}' e detecção de drift..."
AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
NEED_DEPLOY=true
SAVED_ENGINE_ID=""

if [[ -f "${AGENT_INFO_FILE}" ]]; then
    SAVED_ENGINE_ID=$(jq -r '.engine_id // empty' "${AGENT_INFO_FILE}")
fi

TOKEN=$(gcloud auth print-access-token)
if [[ -z "${SAVED_ENGINE_ID}" ]]; then
    SAVED_ENGINE_ID=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" | \
        jq -r '.reasoningEngines[]? | select(.displayName=="'"${RE_DISPLAY_NAME}"'") | .name' | awk -F'/' '{print $NF}' | head -n 1 || true)
fi

EXISTING_ENGINE_ARG=()
if [[ -n "${SAVED_ENGINE_ID}" ]]; then
    EXISTING_META=$(curl -s -f -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${SAVED_ENGINE_ID}" 2>/dev/null || true)
    if [[ -n "${EXISTING_META}" ]]; then
        DEPLOYED_MODEL=$(echo "${EXISTING_META}" | jq -r '.spec.deploymentSpec.env[]? | select(.name=="MODEL_NAME") | .value' || true)
        DEPLOYED_MCP_URL=$(echo "${EXISTING_META}" | jq -r '.spec.deploymentSpec.env[]? | select(.name=="MCP_URL") | .value' || true)
        if [[ "${DEPLOYED_MODEL}" == "${MODEL_NAME}" && "${DEPLOYED_MCP_URL}" == "${MCP_URL}" && "${FORCE_REDEPLOY:-false}" != "true" ]]; then
            log_info "Reasoning Engine '${SAVED_ENGINE_ID}' já está sincronizado com modelo '${MODEL_NAME}' (global) e '${MCP_URL}'."
            NEED_DEPLOY=false
        else
            log_info "Drift detectado no Reasoning Engine '${SAVED_ENGINE_ID}' (modelo='${DEPLOYED_MODEL:-?}', mcp_url='${DEPLOYED_MCP_URL:-?}'). Atualizando in-place..."
            EXISTING_ENGINE_ARG=(--engine-id="${SAVED_ENGINE_ID}")
        fi
    fi
fi

if [[ "${NEED_DEPLOY}" == "true" ]]; then
    "${PYTHON_EXEC}" "${DEMO_ROOT}/src/deploy_agent.py" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --staging-bucket="${STAGING_BUCKET}" \
        --model-name="${MODEL_NAME}" \
        --mcp-url="${MCP_URL}" \
        --mcp-invoker-sa="${MCP_INVOKER_SA}" \
        --agent-gateway-egress="${AGW_URI}" \
        --display-name="${RE_DISPLAY_NAME}" \
        --output-json="${AGENT_INFO_FILE}" \
        --enable-agent-identity \
        --enable-telemetry \
        --allow-token-sharing \
        "${EXISTING_ENGINE_ARG[@]}"
fi

# ------------------------------------------------------------------------------
# 4. Resolve Canonical SPIFFE Identity & Grant IAM + OIDC Impersonation Roles
# ------------------------------------------------------------------------------
log_step "4. Extraindo Identidade SPIFFE canônica e vinculando permissões IAM & Impersonation..."
TOKEN=$(gcloud auth print-access-token)
if [[ -f "${AGENT_INFO_FILE}" ]]; then
    RE_ENGINE_ID=$(jq -r '.engine_id' "${AGENT_INFO_FILE}")
else
    RE_ENGINE_ID="${SAVED_ENGINE_ID}"
fi

RE_METADATA=$(curl -s -f -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}")

EFFECTIVE_ID=$(echo "${RE_METADATA}" | jq -r '.spec.effectiveIdentity // empty' 2>/dev/null || true)
ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --filter="type:organization" --format="value(id)" 2>/dev/null || true)
if [[ -z "${ORG_ID}" && "${EFFECTIVE_ID}" =~ org-([0-9]+) ]]; then
    ORG_ID="${BASH_REMATCH[1]}"
fi

if [[ -n "${EFFECTIVE_ID}" ]]; then
    if [[ "${EFFECTIVE_ID}" == principal://* ]]; then
        AGENT_SPIFFE="${EFFECTIVE_ID}"
    else
        AGENT_SPIFFE="principal://${EFFECTIVE_ID}"
    fi
elif [[ -n "${ORG_ID}" ]]; then
    AGENT_SPIFFE="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}"
else
    AGENT_SPIFFE="principal://agents.global.project-${PROJECT_NUMBER}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}"
fi

if [[ -n "${ORG_ID}" ]]; then
    AGENT_PRINCIPAL_SET="principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
else
    AGENT_PRINCIPAL_SET="principalSet://agents.global.project-${PROJECT_NUMBER}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
fi

log_info "Reasoning Engine ID: ${COLOR_BOLD}${RE_ENGINE_ID}${COLOR_NC}"
log_info "Identidade SPIFFE:   ${COLOR_CYAN}${AGENT_SPIFFE}${COLOR_NC}"
log_info "PrincipalSet Frota:  ${COLOR_CYAN}${AGENT_PRINCIPAL_SET}${COLOR_NC}"

# Bridge SPIFFE JWT-SVID -> OIDC Token for Cloud Run via SA Impersonation
for role in "roles/iam.serviceAccountTokenCreator" "roles/iam.serviceAccountOpenIdTokenCreator"; do
    gcloud iam service-accounts add-iam-policy-binding "${MCP_INVOKER_SA}" \
        --project="${PROJECT_ID}" \
        --member="${AGENT_SPIFFE}" \
        --role="${role}" \
        --quiet >/dev/null
    gcloud iam service-accounts add-iam-policy-binding "${MCP_INVOKER_SA}" \
        --project="${PROJECT_ID}" \
        --member="${AGENT_PRINCIPAL_SET}" \
        --role="${role}" \
        --quiet >/dev/null
done

# Grant Vertex AI, Agent Registry Viewer, Telemetry & Logging roles to SPIFFE identity
for role in \
    "roles/aiplatform.user" \
    "roles/agentregistry.viewer" \
    "roles/cloudtrace.agent" \
    "roles/telemetry.writer" \
    "roles/logging.logWriter" \
    "roles/monitoring.metricWriter" \
    "roles/browser"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="${AGENT_SPIFFE}" \
        --role="${role}" \
        --condition=None \
        --quiet >/dev/null
done

cat > "${AGENT_INFO_FILE}" <<EOF
{
  "reasoning_engine_name": "projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}",
  "engine_id": "${RE_ENGINE_ID}",
  "agent_identity": "${AGENT_SPIFFE}",
  "agent_principal_set": "${AGENT_PRINCIPAL_SET}",
  "project": "${PROJECT_ID}",
  "region": "${REGION}",
  "mcp_url": "${MCP_URL}",
  "mcp_invoker_sa": "${MCP_INVOKER_SA}",
  "agent_gateway_egress": "${AGW_URI}"
}
EOF

log_success "Permissões IAM e OIDC Impersonation vinculadas à identidade SPIFFE!"
log_banner "Etapa 04 Concluída com Sucesso!"
