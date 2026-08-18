#!/usr/bin/env bash
# ==============================================================================
# Script 04: Configure Service Extensions & Network Security Authz Policy
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 04: Configuração de Authz Extensions e Políticas de Segurança"

# ------------------------------------------------------------------------------
# 1. Generate and Import Service Extensions Authz Extension
# ------------------------------------------------------------------------------
log_step "1. Gerando manifesto do Service Extension Authz Extension..."
AUTHZ_EXT_YAML="${STATE_DIR}/authz-extension.yaml"

# Replace variables in template
eval "cat <<EOF
$(cat "${DEMO_ROOT}/cfg/authz-extension.yaml.template")
EOF
" > "${AUTHZ_EXT_YAML}"

log_info "Manifesto gerado em: ${AUTHZ_EXT_YAML}"
cat "${AUTHZ_EXT_YAML}"

log_step "2. Importando Authz Extension no Google Cloud..."
if gcloud beta service-extensions authz-extensions describe "${AUTHZ_EXT_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Authz Extension '${AUTHZ_EXT_NAME}' já existe. Atualizando/importando..."
fi

gcloud beta service-extensions authz-extensions import "${AUTHZ_EXT_NAME}" \
    --source="${AUTHZ_EXT_YAML}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
log_success "Authz Extension '${AUTHZ_EXT_NAME}' importado com sucesso!"

# ------------------------------------------------------------------------------
# 2. Generate and Import Network Security Authz Policy
# ------------------------------------------------------------------------------
log_step "3. Gerando manifesto do Network Security Authz Policy..."
AUTHZ_POLICY_YAML="${STATE_DIR}/authz-policy.yaml"

# Replace variables in template
eval "cat <<EOF
$(cat "${DEMO_ROOT}/cfg/authz-policy.yaml.template")
EOF
" > "${AUTHZ_POLICY_YAML}"

log_info "Manifesto gerado em: ${AUTHZ_POLICY_YAML}"
cat "${AUTHZ_POLICY_YAML}"

log_step "4. Importando Authz Policy vinculada ao Agent Gateway..."
if gcloud beta network-security authz-policies describe "${AUTHZ_POLICY_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Authz Policy '${AUTHZ_POLICY_NAME}' já existe. Atualizando/importando..."
fi

gcloud beta network-security authz-policies import "${AUTHZ_POLICY_NAME}" \
    --source="${AUTHZ_POLICY_YAML}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
log_success "Authz Policy '${AUTHZ_POLICY_NAME}' vinculada ao Agent Gateway '${AGW_NAME}' com sucesso!"

log_banner "Etapa 04 Concluída com Sucesso!"
