#!/usr/bin/env bash
# ==============================================================================
# Script 03: Provision Agent Gateway (AGENT_TO_ANYWHERE), IAP Extensions & Registry
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 03: Criando Agent Gateway Egress (AGENT_TO_ANYWHERE) e Catálogo no Agent Registry"

MCP_INFO_FILE="${STATE_DIR}/mcp_info.json"
if [[ ! -f "${MCP_INFO_FILE}" ]]; then
    log_error "Arquivo '${MCP_INFO_FILE}' não encontrado. Execute 02_deploy_mcp_server.sh primeiro."
    exit 1
fi

MCP_URL=$(jq -r '.mcp_url' "${MCP_INFO_FILE}")
TOOLSPEC_FILE=$(jq -r '.toolspec_path' "${MCP_INFO_FILE}")

# ------------------------------------------------------------------------------
# 1. Create Standalone Google-Managed Agent Gateway (AGENT_TO_ANYWHERE)
# ------------------------------------------------------------------------------
log_step "1. Provisionando Agent Gateway '${AGW_NAME}' (governedAccessPath=AGENT_TO_ANYWHERE)..."
AGW_YAML="${STATE_DIR}/${AGW_NAME}.yaml"
envsubst < "${DEMO_ROOT}/cfg/agent-gateway.yaml.template" > "${AGW_YAML}"

if gcloud network-services agent-gateways describe "${AGW_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Agent Gateway '${AGW_NAME}' já existe. Sincronizando manifesto..."
fi

gcloud network-services agent-gateways import "${AGW_NAME}" \
    --source="${AGW_YAML}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

log_success "Agent Gateway Egress '${AGW_NAME}' ativo!"

# ------------------------------------------------------------------------------
# 2. Create IAP Service Extensions (DRY_RUN + ENFORCED) & Bootstrap AuthzPolicy
# ------------------------------------------------------------------------------
log_step "2. Importando Service Extensions IAP (DRY_RUN e ENFORCED)..."
DRYRUN_YAML="${STATE_DIR}/${AUTHZ_EXT_DRYRUN}.yaml"
ENFORCED_YAML="${STATE_DIR}/${AUTHZ_EXT_ENFORCED}.yaml"

envsubst < "${DEMO_ROOT}/cfg/authz-extension-dryrun.yaml.template" > "${DRYRUN_YAML}"
envsubst < "${DEMO_ROOT}/cfg/authz-extension-enforced.yaml.template" > "${ENFORCED_YAML}"

gcloud service-extensions authz-extensions import "${AUTHZ_EXT_DRYRUN}" \
    --source="${DRYRUN_YAML}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

gcloud service-extensions authz-extensions import "${AUTHZ_EXT_ENFORCED}" \
    --source="${ENFORCED_YAML}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

log_step "3. Vinculando AuthzPolicy (${AUTHZ_POLICY_NAME}) em modo DRY_RUN durante o bootstrap do agente..."
export ACTIVE_AUTHZ_EXT="${AUTHZ_EXT_DRYRUN}"
POLICY_YAML="${STATE_DIR}/${AUTHZ_POLICY_NAME}.yaml"
envsubst < "${DEMO_ROOT}/cfg/authz-policy.yaml.template" > "${POLICY_YAML}"

gcloud beta network-security authz-policies import "${AUTHZ_POLICY_NAME}" \
    --source="${POLICY_YAML}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

log_success "AuthzPolicy vinculada ao Agent Gateway em modo DRY_RUN para inicialização segura."

# ------------------------------------------------------------------------------
# 3. Register Consolidated Core Google APIs in Agent Registry
#    (Includes both standard and :443 HTTP/2 gRPC :authority variants + global aiplatform)
# ------------------------------------------------------------------------------
GAPI_INTERFACES=(
    --interfaces=protocolBinding=JSONRPC,url=https://aiplatform.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://aiplatform.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://aiplatform.mtls.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://aiplatform.mtls.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://${REGION}-aiplatform.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://${REGION}-aiplatform.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://${REGION}-aiplatform.mtls.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://${REGION}-aiplatform.mtls.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://iamcredentials.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://iamcredentials.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://iamcredentials.mtls.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://sts.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://oauth2.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://cloudresourcemanager.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://cloudresourcemanager.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://telemetry.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://telemetry.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://telemetry.mtls.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://logging.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://logging.googleapis.com:443
    --interfaces=protocolBinding=JSONRPC,url=https://cloudtrace.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://monitoring.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://agentregistry.googleapis.com
    --interfaces=protocolBinding=JSONRPC,url=https://agentregistry.googleapis.com:443
)

log_step "4. Catalogando APIs essenciais do Google Cloud ('${GAPI_SERVICE_NAME}') no Agent Registry..."
if gcloud agent-registry services describe "${GAPI_SERVICE_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Serviço '${GAPI_SERVICE_NAME}' já existe no Agent Registry. Atualizando in-place (preservando ID)..."
    gcloud agent-registry services update "${GAPI_SERVICE_NAME}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --display-name="${GAPI_DISPLAY_NAME}" \
        --description="Endpoints essenciais do Google Cloud (Global Gemini, Vertex AI, IAM Credentials, Telemetry, Logging)" \
        "${GAPI_INTERFACES[@]}" \
        --quiet
else
    gcloud agent-registry services create "${GAPI_SERVICE_NAME}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --display-name="${GAPI_DISPLAY_NAME}" \
        --description="Endpoints essenciais do Google Cloud (Global Gemini, Vertex AI, IAM Credentials, Telemetry, Logging)" \
        --endpoint-spec-type=no-spec \
        "${GAPI_INTERFACES[@]}" \
        --quiet
fi

GAPI_ENDPOINT_ID=$(gcloud agent-registry services describe "${GAPI_SERVICE_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --format="value(registryResource.basename())")

log_success "Core Google APIs catalogadas! Endpoint Registry ID: ${GAPI_ENDPOINT_ID}"

# ------------------------------------------------------------------------------
# 4. Register Corporate Treasury MCP Server in Agent Registry with toolspec.json
# ------------------------------------------------------------------------------
log_step "5. Catalogando o servidor MCP '${MCP_REGISTRY_SERVICE_NAME}' com 'toolspec.json' no Agent Registry..."
if gcloud agent-registry services describe "${MCP_REGISTRY_SERVICE_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Serviço MCP '${MCP_REGISTRY_SERVICE_NAME}' já existe no Agent Registry. Atualizando URL e toolspec in-place (preservando ID)..."
    gcloud agent-registry services update "${MCP_REGISTRY_SERVICE_NAME}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --display-name="${MCP_DISPLAY_NAME}" \
        --description="Servidor MCP de Tesouraria Corporativa e FinOps (Streamable HTTP JSON-RPC)" \
        --mcp-server-spec-content="${TOOLSPEC_FILE}" \
        --interfaces="url=${MCP_URL},protocolBinding=JSONRPC" \
        --quiet
else
    gcloud agent-registry services create "${MCP_REGISTRY_SERVICE_NAME}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --display-name="${MCP_DISPLAY_NAME}" \
        --description="Servidor MCP de Tesouraria Corporativa e FinOps (Streamable HTTP JSON-RPC)" \
        --mcp-server-spec-type=tool-spec \
        --mcp-server-spec-content="${TOOLSPEC_FILE}" \
        --interfaces="url=${MCP_URL},protocolBinding=JSONRPC" \
        --quiet
fi

MCP_REGISTRY_ID=$(gcloud agent-registry services describe "${MCP_REGISTRY_SERVICE_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --format="value(registryResource.basename())")

log_success "Servidor MCP catalogado no Agent Registry! MCP Registry ID: ${MCP_REGISTRY_ID}"

cat > "${STATE_DIR}/registry_info.json" <<EOF
{
  "gapi_service_name": "${GAPI_SERVICE_NAME}",
  "gapi_endpoint_id": "${GAPI_ENDPOINT_ID}",
  "mcp_registry_service_name": "${MCP_REGISTRY_SERVICE_NAME}",
  "mcp_registry_id": "${MCP_REGISTRY_ID}",
  "mcp_url": "${MCP_URL}"
}
EOF

log_banner "Etapa 03 Concluída com Sucesso!"
