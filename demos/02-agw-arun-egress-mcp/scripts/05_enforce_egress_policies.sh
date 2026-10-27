#!/usr/bin/env bash
# ==============================================================================
# Script 05: Bind IAP Egress Policies (CEL Read-Only MCP) & Switch Gateway to ENFORCED
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 05: Políticas IAP Condicionais (CEL MCP L7) e Ativação do Modo ENFORCED"

AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
REGISTRY_INFO_FILE="${STATE_DIR}/registry_info.json"

if [[ ! -f "${AGENT_INFO_FILE}" || ! -f "${REGISTRY_INFO_FILE}" ]]; then
    log_error "Arquivos de estado não encontrados em '${STATE_DIR}'. Execute as etapas 02..04 antes."
    exit 1
fi

export AGENT_SPIFFE=$(jq -r '.agent_identity' "${AGENT_INFO_FILE}")
export AGENT_PRINCIPAL_SET=$(jq -r '.agent_principal_set' "${AGENT_INFO_FILE}")
GAPI_ENDPOINT_ID=$(jq -r '.gapi_endpoint_id' "${REGISTRY_INFO_FILE}")
MCP_REGISTRY_ID=$(jq -r '.mcp_registry_id' "${REGISTRY_INFO_FILE}")

# ------------------------------------------------------------------------------
# 1. Grant roles/iap.egressor on Core Google APIs Endpoint in Agent Registry
# ------------------------------------------------------------------------------
log_step "1. Concedendo 'roles/iap.egressor' para Core Google APIs (Endpoint ID: ${GAPI_ENDPOINT_ID})..."
export IAP_ETAG=$(gcloud beta iap web get-iam-policy \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --resource-type=agent-registry \
    --endpoint="${GAPI_ENDPOINT_ID}" \
    --format="value(etag)")

GAPI_IAP_JSON="${STATE_DIR}/iap-gapi-policy.json"
envsubst < "${DEMO_ROOT}/cfg/iap-gapi-policy.json.template" > "${GAPI_IAP_JSON}"

gcloud beta iap web set-iam-policy "${GAPI_IAP_JSON}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --resource-type=agent-registry \
    --endpoint="${GAPI_ENDPOINT_ID}" \
    --quiet >/dev/null

log_success "Egress autorizado para APIs essenciais do Google Cloud!"

# ------------------------------------------------------------------------------
# 2. Grant Conditional CEL roles/iap.egressor on Corporate Treasury MCP Server
#    Allows ONLY MCP handshake (toolName == '') and readOnly tools (isReadOnly == true)
# ------------------------------------------------------------------------------
log_step "2. Aplicando política CEL condicional (somente MCP readOnly) no MCP Server (ID: ${MCP_REGISTRY_ID})..."
export IAP_ETAG=$(gcloud beta iap web get-iam-policy \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --resource-type=agent-registry \
    --mcp-server="${MCP_REGISTRY_ID}" \
    --format="value(etag)")

MCP_IAP_JSON="${STATE_DIR}/iap-mcp-policy.json"
envsubst < "${DEMO_ROOT}/cfg/iap-mcp-policy.json.template" > "${MCP_IAP_JSON}"

gcloud beta iap web set-iam-policy "${MCP_IAP_JSON}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --resource-type=agent-registry \
    --mcp-server="${MCP_REGISTRY_ID}" \
    --quiet >/dev/null

log_success "Política CEL (iap.googleapis.com/mcp.tool.isReadOnly == true) vinculada ao MCP Server!"

# ------------------------------------------------------------------------------
# 3. Switch Agent Gateway AuthzPolicy from DRY_RUN to ENFORCED (failOpen: false)
# ------------------------------------------------------------------------------
log_step "3. Alternando AuthzPolicy '${AUTHZ_POLICY_NAME}' para modo ENFORCED (failOpen: false)..."
export ACTIVE_AUTHZ_EXT="${AUTHZ_EXT_ENFORCED}"
POLICY_YAML="${STATE_DIR}/${AUTHZ_POLICY_NAME}.yaml"
envsubst < "${DEMO_ROOT}/cfg/authz-policy.yaml.template" > "${POLICY_YAML}"

gcloud beta network-security authz-policies import "${AUTHZ_POLICY_NAME}" \
    --source="${POLICY_YAML}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

log_info "Aguardando propagação das políticas IAP e xDS no Agent Gateway (15s)..."
sleep 15

log_success "Modo Zero-Trust ENFORCED ativo no Agent Gateway '${AGW_NAME}'!"
log_banner "Etapa 05 Concluída com Sucesso!"
