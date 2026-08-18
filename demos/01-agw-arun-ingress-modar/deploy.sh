#!/usr/bin/env bash
# ==============================================================================
# Master Deployment Orchestrator
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Iniciando Deploy Completo: Agent Gateway Ingress & Model Armor"

START_TIME=$(date +%s)

# Execute modular deployment phases
"${DEMO_ROOT}/scripts/01_enable_apis.sh"
"${DEMO_ROOT}/scripts/02_create_gateway.sh"
"${DEMO_ROOT}/scripts/03_create_model_armor.sh"
"${DEMO_ROOT}/scripts/04_create_authz_policy.sh"
"${DEMO_ROOT}/scripts/05_deploy_agent.sh"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
RE_ENGINE_ID=$(jq -r '.engine_id // "N/A"' "${AGENT_INFO_FILE}" 2>/dev/null || echo "N/A")

log_banner "Deploy Concluído com Sucesso em ${DURATION} segundos!"

printf "${COLOR_GREEN}${COLOR_BOLD}Resumo do Ambiente Governado:${COLOR_NC}\n"
printf "  • Projeto GCP:             ${COLOR_CYAN}%s${COLOR_NC} (%s)\n" "${PROJECT_ID}" "${PROJECT_NUMBER}"
printf "  • Região:                  ${COLOR_CYAN}%s${COLOR_NC}\n" "${REGION}"
printf "  • Agent Gateway:           ${COLOR_CYAN}%s${COLOR_NC}\n" "${AGW_NAME}"
printf "  • Modelo Generativo:       ${COLOR_CYAN}%s${COLOR_NC}\n" "${MODEL_NAME}"
printf "  • Vertex AI Engine ID:     ${COLOR_CYAN}%s${COLOR_NC}\n" "${RE_ENGINE_ID}"
printf "  • Bucket de Dados:         ${COLOR_CYAN}gs://%s${COLOR_NC}\n" "${DATA_BUCKET}"
printf "  • Política de Segurança:   ${COLOR_CYAN}%s (CONTENT_AUTHZ)${COLOR_NC}\n" "${AUTHZ_POLICY_NAME}"
printf "  • Extensão Model Armor:    ${COLOR_CYAN}%s${COLOR_NC}\n" "${AUTHZ_EXT_NAME}"
printf "\n"
printf "${COLOR_YELLOW}👉 Para executar a suíte automatizada de testes em PT-BR, execute:${COLOR_NC}\n"
printf "   ${COLOR_BOLD}./test.sh${COLOR_NC}\n\n"
