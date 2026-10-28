#!/usr/bin/env bash
# ==============================================================================
# Passo 02: Deploy do Servidor FastMCP (Nó 3) e Especialista A2A (Nó 2) no Cloud Run
# Demo 03: End-to-End Multi-Agent OTel, Live Topology & BigQuery Agent Analytics
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_step "02. Implantando Nós Remotos no Cloud Run (--functional-type=mcp-server & agent)..."

compute_dir_sha256() {
    local dir="$1"
    python3 - "$dir" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(d for d in dirnames if d != "__pycache__" and not d.startswith("."))
    for fn in sorted(filenames):
        if fn.endswith(".pyc") or fn.startswith("."):
            continue
        fp = os.path.join(dirpath, fn)
        rel = os.path.relpath(fp, root)
        h.update(rel.encode("utf-8") + b"\0")
        with open(fp, "rb") as f:
            h.update(f.read() + b"\0")
print(h.hexdigest())
PY
}

# ------------------------------------------------------------------------------
# 1. Deploy Node 3: Streamable HTTP FastMCP Server (`o11y-mcp-erp-ops`)
# ------------------------------------------------------------------------------
MCP_SRC_DIR="${DEMO_ROOT}/src/mcp_server"
MCP_SRC_HASH=$(compute_dir_sha256 "${MCP_SRC_DIR}")
EXISTING_MCP_JSON=$(gcloud beta run services describe "${MCP_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="json" 2>/dev/null || echo "")

DEPLOY_MCP=true
MCP_FT_ARGS=(--functional-type=mcp-server)

if [[ -n "${EXISTING_MCP_JSON}" ]]; then
    MCP_FT_ARGS=()
    DEPLOYED_MCP_SHA=$(echo "${EXISTING_MCP_JSON}" | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="SOURCE_SHA256") | .value' || true)
    DEPLOYED_MCP_URL=$(echo "${EXISTING_MCP_JSON}" | jq -r '.status.url // empty' || true)
    if [[ -n "${DEPLOYED_MCP_URL}" && "${DEPLOYED_MCP_SHA}" == "${MCP_SRC_HASH}" && "${FORCE_REDEPLOY:-false}" != "true" ]]; then
        log_info "Nó 3 Cloud Run '${MCP_SERVICE_NAME}' já está sincronizado (SHA=${MCP_SRC_HASH:0:12}). Pulando rebuild."
        DEPLOY_MCP=false
    elif [[ -n "${DEPLOYED_MCP_URL}" && -z "${DEPLOYED_MCP_SHA}" && -f "${STATE_DIR}/cloudrun_nodes.json" && "${FORCE_REDEPLOY:-false}" != "true" ]]; then
        SAVED_MCP_SHA=$(jq -r '.mcp_src_sha256 // empty' "${STATE_DIR}/cloudrun_nodes.json" 2>/dev/null || true)
        if [[ "${SAVED_MCP_SHA}" == "${MCP_SRC_HASH}" ]]; then
            log_info "Nó 3 Cloud Run '${MCP_SERVICE_NAME}' já está sincronizado (SHA=${MCP_SRC_HASH:0:12}). Pulando rebuild."
            DEPLOY_MCP=false
        fi
    fi
fi

if [[ "${DEPLOY_MCP}" == "true" ]]; then
    log_info "Implantando Nó 3: Cloud Run FastMCP Server '${MCP_SERVICE_NAME}' (SHA=${MCP_SRC_HASH:0:12})..."
    gcloud beta run deploy "${MCP_SERVICE_NAME}" \
        --source="${MCP_SRC_DIR}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        "${MCP_FT_ARGS[@]}" \
        --service-account="${MCP_RUNTIME_SA}" \
        --ingress=all \
        --no-allow-unauthenticated \
        --min-instances=0 \
        --max-instances=4 \
        --memory=512Mi \
        --set-env-vars="PROJECT_ID=${PROJECT_ID},GOOGLE_CLOUD_PROJECT=${PROJECT_ID},MCP_SERVICE_NAME=${MCP_SERVICE_NAME},REGION=${REGION},GOOGLE_API_USE_CLIENT_CERTIFICATE=false,GOOGLE_API_USE_MTLS_ENDPOINT=never,SOURCE_SHA256=${MCP_SRC_HASH}" \
        --quiet
fi

MCP_BASE_URL=$(gcloud run services describe "${MCP_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(status.url)")
MCP_URL="${MCP_BASE_URL}/mcp"
log_success "FastMCP Server ativo: ${MCP_URL}"

# ------------------------------------------------------------------------------
# 2. Pre-grant IAM to Cloud Run A2A Agent SPIFFE Identity (if ORG_ID available)
# ------------------------------------------------------------------------------
A2A_SPIFFE_PRINCIPAL=""
if [[ -n "${ORG_ID}" ]]; then
    A2A_SPIFFE_PRINCIPAL="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/run/projects/${PROJECT_NUMBER}/locations/${REGION}/services/${A2A_SERVICE_NAME}"
    log_info "Pré-autorizando identidade SPIFFE do Agente A2A no Cloud Run: ${A2A_SPIFFE_PRINCIPAL}"
    for role in \
        "roles/aiplatform.user" \
        "roles/telemetry.writer" \
        "roles/telemetry.tracesWriter" \
        "roles/telemetry.metricsWriter" \
        "roles/cloudtrace.agent" \
        "roles/logging.logWriter" \
        "roles/monitoring.metricWriter" \
        "roles/browser"; do
        gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
            --member="${A2A_SPIFFE_PRINCIPAL}" \
            --role="${role}" \
            --condition=None \
            --quiet >/dev/null
    done
fi

# ------------------------------------------------------------------------------
# 3. Deploy Node 2: Specialist A2A Agent (`o11y-a2a-sla-risk`)
# ------------------------------------------------------------------------------
A2A_SRC_DIR="${DEMO_ROOT}/src/a2a_specialist"
A2A_SRC_HASH=$(compute_dir_sha256 "${A2A_SRC_DIR}")
EXISTING_A2A_JSON=$(gcloud beta run services describe "${A2A_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="json" 2>/dev/null || echo "")

DEPLOY_A2A=true
A2A_FT_ARGS=(--functional-type=agent --identity-type=agent-identity --no-identity-certificate)

if [[ -n "${EXISTING_A2A_JSON}" ]]; then
    A2A_FT_ARGS=(--identity-type=agent-identity --no-identity-certificate)
    DEPLOYED_A2A_SHA=$(echo "${EXISTING_A2A_JSON}" | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="SOURCE_SHA256") | .value' || true)
    DEPLOYED_A2A_MODEL=$(echo "${EXISTING_A2A_JSON}" | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="MODEL_NAME") | .value' || true)
    DEPLOYED_A2A_URL=$(echo "${EXISTING_A2A_JSON}" | jq -r '.status.url // empty' || true)
    if [[ -n "${DEPLOYED_A2A_URL}" && "${DEPLOYED_A2A_MODEL}" == "${MODEL_NAME}" && "${FORCE_REDEPLOY:-false}" != "true" ]]; then
        if [[ "${DEPLOYED_A2A_SHA}" == "${A2A_SRC_HASH}" ]]; then
            log_info "Nó 2 Cloud Run '${A2A_SERVICE_NAME}' já está sincronizado (SHA=${A2A_SRC_HASH:0:12}, model=${MODEL_NAME}). Pulando rebuild."
            DEPLOY_A2A=false
        elif [[ -z "${DEPLOYED_A2A_SHA}" && -f "${STATE_DIR}/cloudrun_nodes.json" ]]; then
            SAVED_A2A_SHA=$(jq -r '.a2a_src_sha256 // empty' "${STATE_DIR}/cloudrun_nodes.json" 2>/dev/null || true)
            if [[ "${SAVED_A2A_SHA}" == "${A2A_SRC_HASH}" ]]; then
                log_info "Nó 2 Cloud Run '${A2A_SERVICE_NAME}' já está sincronizado (SHA=${A2A_SRC_HASH:0:12}, model=${MODEL_NAME}). Pulando rebuild."
                DEPLOY_A2A=false
            fi
        fi
    fi
fi

if [[ "${DEPLOY_A2A}" == "true" ]]; then
    log_info "Implantando Nó 2: Cloud Run Specialist A2A Agent '${A2A_SERVICE_NAME}' (SHA=${A2A_SRC_HASH:0:12}, model=${MODEL_NAME})..."
    gcloud beta run deploy "${A2A_SERVICE_NAME}" \
        --source="${A2A_SRC_DIR}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        "${A2A_FT_ARGS[@]}" \
        --ingress=all \
        --no-allow-unauthenticated \
        --min-instances=0 \
        --max-instances=4 \
        --memory=1Gi \
        --set-env-vars="PROJECT_ID=${PROJECT_ID},GOOGLE_CLOUD_PROJECT=${PROJECT_ID},MODEL_NAME=${MODEL_NAME},GOOGLE_GENAI_USE_VERTEXAI=True,GOOGLE_CLOUD_LOCATION=global,VERTEX_AI_LOCATION=global,PUBLIC_HOST=${A2A_DETERMINISTIC_HOST},PUBLIC_PORT=443,PUBLIC_PROTOCOL=https,OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental,OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=EVENT_ONLY,ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false,GOOGLE_API_USE_CLIENT_CERTIFICATE=false,GOOGLE_API_USE_MTLS_ENDPOINT=never,GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false,SOURCE_SHA256=${A2A_SRC_HASH}" \
        --quiet
fi

# Inspect status.url & effective Agent Identity on Cloud Run
A2A_DESC_JSON=$(gcloud beta run services describe "${A2A_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="json")

A2A_STATUS_URL=$(echo "${A2A_DESC_JSON}" | jq -r '.status.url // empty')
# Prefer the deterministic project-number URL so AgentCard origin validation matches 100%
A2A_BASE_URL="https://${A2A_DETERMINISTIC_HOST}"
A2A_AGENT_CARD_URL="${A2A_BASE_URL}/.well-known/agent-card.json"

# Also check if Cloud Run populated an explicit agent identity annotation/field and ensure IAM
DETECTED_A2A_ID=$(echo "${A2A_DESC_JSON}" | jq -r '
    .metadata.annotations["run.googleapis.com/effective-identity"] //
    .spec.template.metadata.annotations["run.googleapis.com/agent-identity"] //
    empty')
if [[ -n "${DETECTED_A2A_ID}" ]]; then
    if [[ "${DETECTED_A2A_ID}" != principal://* ]]; then
        DETECTED_A2A_PRINCIPAL="principal://${DETECTED_A2A_ID}"
    else
        DETECTED_A2A_PRINCIPAL="${DETECTED_A2A_ID}"
    fi
    if [[ "${DETECTED_A2A_PRINCIPAL}" != "${A2A_SPIFFE_PRINCIPAL}" ]]; then
        log_info "Garantindo IAM para identidade detectada do Cloud Run Agent: ${DETECTED_A2A_PRINCIPAL}"
        for role in "roles/aiplatform.user" "roles/telemetry.writer" "roles/telemetry.tracesWriter" "roles/telemetry.metricsWriter" "roles/cloudtrace.agent" "roles/logging.logWriter" "roles/monitoring.metricWriter" "roles/browser"; do
            gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
                --member="${DETECTED_A2A_PRINCIPAL}" \
                --role="${role}" \
                --condition=None \
                --quiet >/dev/null
        done
        A2A_SPIFFE_PRINCIPAL="${DETECTED_A2A_PRINCIPAL}"
    fi
fi

# ------------------------------------------------------------------------------
# 4. Bind roles/run.invoker on BOTH Cloud Run services to CR_INVOKER_SA & active user
# ------------------------------------------------------------------------------
ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
for svc in "${MCP_SERVICE_NAME}" "${A2A_SERVICE_NAME}"; do
    log_info "Concedendo 'roles/run.invoker' em '${svc}' para '${CR_INVOKER_SA}'..."
    gcloud run services add-iam-policy-binding "${svc}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --member="serviceAccount:${CR_INVOKER_SA}" \
        --role="roles/run.invoker" \
        --quiet >/dev/null

    if [[ -n "${ACTIVE_ACCOUNT}" ]]; then
        MEMBER_PREFIX="user"
        [[ "${ACTIVE_ACCOUNT}" == *.gserviceaccount.com ]] && MEMBER_PREFIX="serviceAccount"
        gcloud run services add-iam-policy-binding "${svc}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --member="${MEMBER_PREFIX}:${ACTIVE_ACCOUNT}" \
            --role="roles/run.invoker" \
            --quiet >/dev/null || true
    fi
done

# ------------------------------------------------------------------------------
# 5. Smoke-check authenticated `/healthz` and `/.well-known/agent-card.json`
# ------------------------------------------------------------------------------
ID_TOKEN=$(gcloud auth print-identity-token 2>/dev/null || true)
if [[ -n "${ID_TOKEN}" ]]; then
    MCP_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${ID_TOKEN}" "${MCP_BASE_URL}/healthz" || echo "000")
    A2A_CARD_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${ID_TOKEN}" "${A2A_AGENT_CARD_URL}" || echo "000")
    log_info "Smoke-check autenticado: MCP /healthz=HTTP ${MCP_HEALTH} | A2A agent-card.json=HTTP ${A2A_CARD_HTTP}"
fi

cat > "${STATE_DIR}/cloudrun_nodes.json" <<EOF
{
  "mcp_service_name": "${MCP_SERVICE_NAME}",
  "mcp_base_url": "${MCP_BASE_URL}",
  "mcp_url": "${MCP_URL}",
  "mcp_src_sha256": "${MCP_SRC_HASH}",
  "a2a_service_name": "${A2A_SERVICE_NAME}",
  "a2a_status_url": "${A2A_STATUS_URL}",
  "a2a_base_url": "${A2A_BASE_URL}",
  "a2a_agent_card_url": "${A2A_AGENT_CARD_URL}",
  "a2a_spiffe_principal": "${A2A_SPIFFE_PRINCIPAL}",
  "a2a_src_sha256": "${A2A_SRC_HASH}",
  "cr_invoker_sa": "${CR_INVOKER_SA}"
}
EOF

log_success "Passo 02 concluído: Nós MCP e A2A ativos e autenticados via OIDC!"
