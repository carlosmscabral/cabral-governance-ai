#!/usr/bin/env bash
# ==============================================================================
# Passo 03: Deploy do Agente Orquestrador (Nó 1 - Reasoning Engine) & Topologia App Hub
# Demo 03: End-to-End Multi-Agent OTel, Live Topology & BigQuery Agent Analytics
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_step "03. Implantando Agente Orquestrador no Reasoning Engine e configurando App Hub..."

NODES_FILE="${STATE_DIR}/cloudrun_nodes.json"
if [[ ! -f "${NODES_FILE}" ]]; then
    log_error "Arquivo '${NODES_FILE}' não encontrado. Execute 02_deploy_mcp_and_a2a.sh primeiro."
    exit 1
fi

MCP_URL=$(jq -r '.mcp_url' "${NODES_FILE}")
A2A_AGENT_CARD_URL=$(jq -r '.a2a_agent_card_url' "${NODES_FILE}")

# ------------------------------------------------------------------------------
# 1. Prepare local Python virtual environment (.venv)
# ------------------------------------------------------------------------------
VENV_DIR="${DEMO_ROOT}/.venv"
if [[ ! -d "${VENV_DIR}" ]]; then
    log_info "Criando ambiente virtual Python isolado em '${VENV_DIR}'..."
    if command -v uv &>/dev/null; then
        uv venv "${VENV_DIR}" --python 3.11 || uv venv "${VENV_DIR}"
    else
        python3 -m venv "${VENV_DIR}"
    fi
fi

PYTHON_BIN="${VENV_DIR}/bin/python"
log_info "Sincronizando dependências ADK, OTel, A2A, MCP e BigQuery Analytics no .venv..."
if command -v uv &>/dev/null; then
    uv pip install --python "${PYTHON_BIN}" --quiet \
        "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" \
        "google-adk[bigquery-analytics,a2a]>=2.12.0" \
        "opentelemetry-exporter-otlp-proto-http>=1.37.0" \
        "google-cloud-bigquery>=3.25.0" \
        "google-cloud-bigquery-storage>=2.26.0" \
        "google-cloud-storage>=2.14.0" \
        "fsspec[gcs]>=2024.6.0" \
        "gcsfs>=2024.6.0" \
        "google-auth>=2.35.0" \
        "mcp>=1.26.0,<2.0.0" \
        "a2a-sdk>=1.2.0" \
        "httpx>=0.28.0" \
        "opentelemetry-instrumentation-httpx>=0.48b0" \
        "opentelemetry-instrumentation-google-genai>=0.4b0" \
        "pydantic>=2.0.0" \
        "cloudpickle>=3.0.0"
else
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install --quiet \
        "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" \
        "google-adk[bigquery-analytics,a2a]>=2.12.0" \
        "opentelemetry-exporter-otlp-proto-http>=1.37.0" \
        "google-cloud-bigquery>=3.25.0" \
        "google-cloud-bigquery-storage>=2.26.0" \
        "google-cloud-storage>=2.14.0" \
        "fsspec[gcs]>=2024.6.0" \
        "gcsfs>=2024.6.0" \
        "google-auth>=2.35.0" \
        "mcp>=1.26.0,<2.0.0" \
        "a2a-sdk>=1.2.0" \
        "httpx>=0.28.0" \
        "opentelemetry-instrumentation-httpx>=0.48b0" \
        "opentelemetry-instrumentation-google-genai>=0.4b0" \
        "pydantic>=2.0.0" \
        "cloudpickle>=3.0.0"
fi

# ------------------------------------------------------------------------------
# 2. Check existing Reasoning Engine & detect configuration/model drift
# ------------------------------------------------------------------------------
AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
TOKEN=$(gcloud auth print-access-token)

EXISTING_RE_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" | \
    jq -c '.reasoningEngines[]? | select(.displayName=="'"${RE_DISPLAY_NAME}"'")' | head -n 1 || true)

DEPLOY_NEEDED=true
UPDATE_ENGINE_ARGS=()

if [[ -n "${EXISTING_RE_JSON}" ]]; then
    RE_FULL_NAME=$(echo "${EXISTING_RE_JSON}" | jq -r '.name')
    RE_ENGINE_ID="${RE_FULL_NAME##*/}"
    DEPLOYED_MODEL=$(echo "${EXISTING_RE_JSON}" | jq -r '.spec.deploymentSpec.env[]? | select(.name=="MODEL_NAME") | .value' || true)
    DEPLOYED_MCP=$(echo "${EXISTING_RE_JSON}" | jq -r '.spec.deploymentSpec.env[]? | select(.name=="MCP_URL") | .value' || true)
    DEPLOYED_A2A=$(echo "${EXISTING_RE_JSON}" | jq -r '.spec.deploymentSpec.env[]? | select(.name=="A2A_AGENT_CARD_URL") | .value' || true)
    DEPLOYED_BKT=$(echo "${EXISTING_RE_JSON}" | jq -r '.spec.deploymentSpec.env[]? | select(.name=="TELEMETRY_BUCKET") | .value' || true)
    AGENT_IDENTITY=$(echo "${EXISTING_RE_JSON}" | jq -r '.spec.effectiveIdentity // empty')

    if [[ "${DEPLOYED_MODEL}" == "${MODEL_NAME}" && "${DEPLOYED_MCP}" == "${MCP_URL}" && "${DEPLOYED_A2A}" == "${A2A_AGENT_CARD_URL}" && "${DEPLOYED_BKT}" == "${TELEMETRY_BUCKET}" && "${FORCE_REDEPLOY:-false}" != "true" ]]; then
        log_info "Reasoning Engine '${RE_DISPLAY_NAME}' (${RE_ENGINE_ID}) já está sincronizado com '${MODEL_NAME}' (global), MCP e A2A."
        cat > "${AGENT_INFO_FILE}" <<EOF
{
  "reasoning_engine_name": "${RE_FULL_NAME}",
  "engine_id": "${RE_ENGINE_ID}",
  "agent_identity": "${AGENT_IDENTITY}",
  "project": "${PROJECT_ID}",
  "region": "${REGION}",
  "mcp_url": "${MCP_URL}",
  "a2a_card_url": "${A2A_AGENT_CARD_URL}",
  "bq_dataset": "${BQ_DATASET}",
  "bq_table": "${BQ_TABLE}",
  "telemetry_bucket": "${TELEMETRY_BUCKET}"
}
EOF
        DEPLOY_NEEDED=false
    else
        log_warn "Drift detectado no Reasoning Engine '${RE_ENGINE_ID}' (model='${DEPLOYED_MODEL}'->'${MODEL_NAME}'). Atualizando in-place..."
        UPDATE_ENGINE_ARGS=(--engine-id "${RE_ENGINE_ID}")
    fi
fi

if [[ "${DEPLOY_NEEDED}" == "true" ]]; then
    "${PYTHON_BIN}" "${DEMO_ROOT}/src/deploy_agent.py" \
        --project "${PROJECT_ID}" \
        --region "${REGION}" \
        --staging-bucket "${STAGING_BUCKET}" \
        --telemetry-bucket "${TELEMETRY_BUCKET}" \
        --model-name "${MODEL_NAME}" \
        --mcp-url "${MCP_URL}" \
        --a2a-card-url "${A2A_AGENT_CARD_URL}" \
        --cr-invoker-sa "${CR_INVOKER_SA}" \
        --bq-dataset "${BQ_DATASET}" \
        --bq-table "${BQ_TABLE}" \
        --display-name "${RE_DISPLAY_NAME}" \
        --output-json "${AGENT_INFO_FILE}" \
        "${UPDATE_ENGINE_ARGS[@]}"
fi

RE_ENGINE_ID=$(jq -r '.engine_id' "${AGENT_INFO_FILE}")
RAW_AGENT_IDENTITY=$(jq -r '.agent_identity // empty' "${AGENT_INFO_FILE}")

if [[ -z "${RAW_AGENT_IDENTITY}" || "${RAW_AGENT_IDENTITY}" == "null" ]]; then
    TOKEN=$(gcloud auth print-access-token)
    RAW_AGENT_IDENTITY=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}" | \
        jq -r '.spec.effectiveIdentity // empty')
fi

# ------------------------------------------------------------------------------
# 3. Grant IAM Permissions to Reasoning Engine SPIFFE Agent Identity (+ Fallback SA)
# ------------------------------------------------------------------------------
PRINCIPALS_TO_AUTHORIZE=()
if [[ -n "${RAW_AGENT_IDENTITY}" && "${RAW_AGENT_IDENTITY}" != "null" ]]; then
    if [[ "${RAW_AGENT_IDENTITY}" == principal://* ]]; then
        PRINCIPALS_TO_AUTHORIZE+=("${RAW_AGENT_IDENTITY}")
    else
        PRINCIPALS_TO_AUTHORIZE+=("principal://${RAW_AGENT_IDENTITY}")
    fi
fi
RE_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
PRINCIPALS_TO_AUTHORIZE+=("serviceAccount:${RE_SERVICE_AGENT}")

log_info "Autorizando identidade SPIFFE do Orquestrador no Vertex AI, Telemetry API, BigQuery, GCS e OIDC Impersonation..."
for member in "${PRINCIPALS_TO_AUTHORIZE[@]}"; do
    for role in \
        "roles/aiplatform.user" \
        "roles/telemetry.writer" \
        "roles/telemetry.tracesWriter" \
        "roles/telemetry.metricsWriter" \
        "roles/cloudtrace.agent" \
        "roles/logging.logWriter" \
        "roles/monitoring.metricWriter" \
        "roles/bigquery.dataEditor" \
        "roles/bigquery.jobUser" \
        "roles/browser"; do
        gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="${member}" \
            --role="${role}" \
            --condition=None \
            --quiet >/dev/null || true
    done

    # Allow writing GenAI `.jsonl` completion hook payloads & multimodal offloads to TELEMETRY_BUCKET
    gcloud storage buckets add-iam-policy-binding "gs://${TELEMETRY_BUCKET}" \
        --member="${member}" \
        --role="roles/storage.objectAdmin" \
        --quiet >/dev/null || true

    # Allow minting short-lived OIDC ID tokens as CR_INVOKER_SA to call Cloud Run MCP + A2A
    gcloud iam service-accounts add-iam-policy-binding "${CR_INVOKER_SA}" \
        --project="${PROJECT_ID}" \
        --member="${member}" \
        --role="roles/iam.serviceAccountTokenCreator" \
        --quiet >/dev/null || true

    gcloud iam service-accounts add-iam-policy-binding "${CR_INVOKER_SA}" \
        --project="${PROJECT_ID}" \
        --member="${member}" \
        --role="roles/iam.serviceAccountOpenIdTokenCreator" \
        --quiet >/dev/null || true
done

# ------------------------------------------------------------------------------
# 4. Provision Regional App Hub Application & Register Discovered Workloads/Services
# ------------------------------------------------------------------------------
log_info "Configurando aplicação App Hub '${APPHUB_APP_ID}' em '${REGION}' para Topologia SRE..."
if ! gcloud apphub applications describe "${APPHUB_APP_ID}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    if gcloud apphub applications create "${APPHUB_APP_ID}" \
        --location="${REGION}" \
        --scope-type="REGIONAL" \
        --display-name="GEAP OTel Multi-Agent Operations" \
        --description="Demo 03: Multi-Agent Topology (Reasoning Engine + Cloud Run A2A + Cloud Run FastMCP)" \
        --environment-type="PRODUCTION" \
        --criticality-type="HIGH" \
        --project="${PROJECT_ID}" \
        --quiet &>/dev/null; then
        log_success "Aplicação App Hub '${APPHUB_APP_ID}' criada!"
    else
        log_warn "App Hub '${APPHUB_APP_ID}' não pôde ser criado neste projeto (pode exigir Host Project App Hub; a topologia nativa do Agent Registry & Cloud Trace segue 100% funcional)."
    fi
else
    log_info "Aplicação App Hub '${APPHUB_APP_ID}' já existe."
fi

# Best-effort registration of discovered Cloud Run services/workloads into App Hub if enabled
if gcloud apphub applications describe "${APPHUB_APP_ID}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    for cr_slug in "${MCP_SERVICE_NAME}" "${A2A_SERVICE_NAME}"; do
        DISC_SVC=$(gcloud apphub discovered-services list \
            --location="${REGION}" \
            --project="${PROJECT_ID}" \
            --filter="serviceReference.uri~'${cr_slug}'" \
            --format="value(name)" 2>/dev/null | head -n 1 || true)
        if [[ -n "${DISC_SVC}" ]]; then
            gcloud apphub applications services create "${cr_slug}" \
                --application="${APPHUB_APP_ID}" \
                --location="${REGION}" \
                --discovered-service="${DISC_SVC}" \
                --display-name="${cr_slug}" \
                --project="${PROJECT_ID}" \
                --quiet &>/dev/null || true
        fi
    done
fi

log_info "Aguardando propagação IAM de 15s..."
sleep 15
log_success "Passo 03 concluído: Orquestrador '${RE_DISPLAY_NAME}' (${RE_ENGINE_ID}) operacional!"
