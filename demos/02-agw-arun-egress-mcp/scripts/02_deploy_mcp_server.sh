#!/usr/bin/env bash
# ==============================================================================
# Script 02: Deploy Corporate Treasury MCP Server on Cloud Run & Generate Toolspec
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 02: Deploy do Servidor MCP (ERP Tesouraria) no Cloud Run & Toolspec"

log_step "1. Fazendo deploy do servidor Streamable HTTP MCP '${MCP_SERVICE_NAME}' no Cloud Run..."
for attempt in 1 2 3; do
    if gcloud run deploy "${MCP_SERVICE_NAME}" \
        --source="${DEMO_ROOT}/src/mcp_server" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --ingress=all \
        --no-allow-unauthenticated \
        --min-instances=0 \
        --max-instances=3 \
        --cpu=1 \
        --memory=512Mi \
        --quiet; then
        break
    fi
    if [[ "${attempt}" -eq 3 ]]; then
        log_error "Falha ao fazer deploy do Cloud Run '${MCP_SERVICE_NAME}' após 3 tentativas."
        exit 1
    fi
    log_warn "Aguardando propagação IAM de Cloud Build (tentativa ${attempt}/3)... tentando novamente em 15s."
    sleep 15
done

MCP_BASE_URL=$(gcloud run services describe "${MCP_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(status.url)")
MCP_URL="${MCP_BASE_URL}/mcp"

log_success "Servidor MCP ativo em: ${MCP_URL}"

log_step "2. Criando Service Account dedicada de invocação OIDC ('${MCP_INVOKER_SA_NAME}')..."
if gcloud iam service-accounts describe "${MCP_INVOKER_SA}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Service Account '${MCP_INVOKER_SA}' já existe."
else
    gcloud iam service-accounts create "${MCP_INVOKER_SA_NAME}" \
        --display-name="SA Invoker OIDC para ${MCP_SERVICE_NAME}" \
        --project="${PROJECT_ID}" \
        --quiet
    log_success "Service Account '${MCP_INVOKER_SA}' criada!"
    sleep 5
fi

log_step "3. Vinculando roles/run.invoker no Cloud Run para a SA Invoker e operador atual..."
ACTIVE_USER=$(gcloud config get-value account 2>/dev/null || true)
if [[ -n "${ACTIVE_USER}" ]]; then
    gcloud run services add-iam-policy-binding "${MCP_SERVICE_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --member="user:${ACTIVE_USER}" \
        --role="roles/run.invoker" \
        --quiet >/dev/null
fi

gcloud run services add-iam-policy-binding "${MCP_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${MCP_INVOKER_SA}" \
    --role="roles/run.invoker" \
    --quiet >/dev/null

COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for role in "roles/iam.serviceAccountTokenCreator" "roles/iam.serviceAccountOpenIdTokenCreator"; do
    gcloud iam service-accounts add-iam-policy-binding "${MCP_INVOKER_SA}" \
        --project="${PROJECT_ID}" \
        --member="serviceAccount:${COMPUTE_SA}" \
        --role="${role}" \
        --quiet >/dev/null
done

log_step "4. Inspecionando servidor MCP ao vivo via JSON-RPC e gerando 'toolspec.json'..."
OIDC_TOKEN=$(gcloud auth print-identity-token)
TOOLSPEC_FILE="${STATE_DIR}/toolspec.json"

python3 "${DEMO_ROOT}/src/mcp_server/generate_toolspec.py" \
    --mcp-url="${MCP_URL}" \
    --token="${OIDC_TOKEN}" \
    --output="${TOOLSPEC_FILE}"

cat > "${STATE_DIR}/mcp_info.json" <<EOF
{
  "service_name": "${MCP_SERVICE_NAME}",
  "base_url": "${MCP_BASE_URL}",
  "mcp_url": "${MCP_URL}",
  "invoker_sa": "${MCP_INVOKER_SA}",
  "toolspec_path": "${TOOLSPEC_FILE}"
}
EOF

log_success "Metadados do MCP Server e toolspec.json salvos em '${STATE_DIR}'!"
log_banner "Etapa 02 Concluída com Sucesso!"
