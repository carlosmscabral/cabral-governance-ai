#!/usr/bin/env bash
# ==============================================================================
# Master Deployment Orchestrator
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
# ==============================================================================

set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Iniciando Deploy Completo: Agent Gateway to Anywhere (Egress + MCP + IAP)"

START_TIME=$(date +%s)

# Execute modular deployment phases
"${DEMO_ROOT}/scripts/01_enable_apis.sh"
"${DEMO_ROOT}/scripts/02_deploy_mcp_server.sh"
"${DEMO_ROOT}/scripts/03_create_gateway_and_registry.sh"
"${DEMO_ROOT}/scripts/04_deploy_agent.sh"
"${DEMO_ROOT}/scripts/05_enforce_egress_policies.sh"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
RE_ENGINE_ID=$(jq -r '.engine_id // "N/A"' "${AGENT_INFO_FILE}" 2>/dev/null || echo "N/A")
MCP_URL=$(jq -r '.mcp_url // "N/A"' "${AGENT_INFO_FILE}" 2>/dev/null || echo "N/A")

log_banner "Deploy Concluído com Sucesso em ${DURATION} segundos!"

printf "${COLOR_GREEN}${COLOR_BOLD}Resumo do Ambiente Governado (Egress):${COLOR_NC}\n"
printf "  • Projeto GCP:             ${COLOR_CYAN}%s${COLOR_NC} (%s)\n" "${PROJECT_ID}" "${PROJECT_NUMBER}"
printf "  • Região Infraestrutura:   ${COLOR_CYAN}%s${COLOR_NC}\n" "${REGION}"
printf "  • Modelo Generativo:       ${COLOR_CYAN}%s (global)${COLOR_NC}\n" "${MODEL_NAME}"
printf "  • Agent Gateway Egress:    ${COLOR_CYAN}%s (AGENT_TO_ANYWHERE)${COLOR_NC}\n" "${AGW_NAME}"
printf "  • Servidor MCP (Cloud Run):${COLOR_CYAN}%s${COLOR_NC}\n" "${MCP_URL}"
printf "  • Vertex AI Engine ID:     ${COLOR_CYAN}%s${COLOR_NC}\n" "${RE_ENGINE_ID}"
printf "  • Política de Segurança:   ${COLOR_CYAN}%s (REQUEST_AUTHZ / IAP ENFORCED)${COLOR_NC}\n" "${AUTHZ_POLICY_NAME}"
printf "\n"
printf "${COLOR_YELLOW}👉 Para executar a suíte automatizada de testes em PT-BR, execute:${COLOR_NC}\n"
printf "   ${COLOR_BOLD}./test.sh${COLOR_NC}\n\n"
