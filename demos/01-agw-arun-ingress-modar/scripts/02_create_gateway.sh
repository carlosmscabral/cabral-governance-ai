#!/usr/bin/env bash
# ==============================================================================
# Script 02: Provision & Verify Agent Gateway (CLIENT_TO_AGENT Ingress)
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 02: Provisionamento do Agent Gateway (Modo Ingress CLIENT_TO_AGENT)"

log_info "Gateway Alvo: ${COLOR_BOLD}${AGW_NAME}${COLOR_NC}"
log_info "Localização: ${COLOR_BOLD}${REGION}${COLOR_NC}"
log_info "URI do Recurso: ${COLOR_CYAN}${AGW_URI}${COLOR_NC}"

log_step "1. Verificando se o Agent Gateway já existe..."
if gcloud network-services agent-gateways describe "${AGW_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_success "Agent Gateway '${AGW_NAME}' já existe no projeto."
else
    log_info "Gerando manifesto YAML do Agent Gateway..."
    AGW_YAML="${STATE_DIR}/${AGW_NAME}.yaml"
    eval "cat <<EOF
$(cat "${DEMO_ROOT}/cfg/agent-gateway.yaml.template")
EOF
" > "${AGW_YAML}"

    log_info "Importando Agent Gateway '${AGW_NAME}' com modo googleManaged CLIENT_TO_AGENT..."
    gcloud network-services agent-gateways import "${AGW_NAME}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --source="${AGW_YAML}"
    
    log_success "Agent Gateway '${AGW_NAME}' importado com sucesso!"
fi

# Verify Details
log_step "2. Detalhes do Agent Gateway provisionado:"
gcloud network-services agent-gateways describe "${AGW_NAME}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="table(name,googleManaged.governedAccessPath,protocols,createTime)"

log_banner "Etapa 02 Concluída com Sucesso!"
