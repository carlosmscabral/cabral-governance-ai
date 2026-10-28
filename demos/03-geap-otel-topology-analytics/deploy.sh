#!/usr/bin/env bash
# ==============================================================================
# Master Deployment Script (Idempotent)
# Demo 03: End-to-End Multi-Agent OTel, Live Topology & BigQuery Agent Analytics
# ==============================================================================

set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Deploy Automatizado: Observabilidade Ponta a Ponta (OTel + Topologia + BigQuery Analytics)"

log_info "Verificando ferramentas de linha de comando..."
check_command "gcloud" "Instale o Google Cloud SDK"
check_command "bq" "Instale o componente bq do Google Cloud SDK"
check_command "jq" "sudo apt-get install jq / brew install jq"
check_command "curl" "sudo apt-get install curl"
check_command "python3" "Instale Python 3.11+"

log_info "Resumo do Ambiente Alvo:"
echo "  • Projeto GCP:          ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "  • Região Infra:         ${REGION}"
echo "  • Modelo Gemini:        ${MODEL_NAME} (endpoint: ${MODEL_LOCATION})"
echo "  • Nó 1 (Orquestrador):  ${RE_DISPLAY_NAME} (Vertex AI Reasoning Engine)"
echo "  • Nó 2 (Especialista):  ${A2A_SERVICE_NAME} (Cloud Run --functional-type=agent / A2A)"
echo "  • Nó 3 (Ferramentas):   ${MCP_SERVICE_NAME} (Cloud Run --functional-type=mcp-server / FastMCP)"
echo "  • Dataset BigQuery:     ${PROJECT_ID}.${BQ_DATASET} (Storage Write API + Semantic Views)"
echo "  • Bucket Telemetria:    gs://${TELEMETRY_BUCKET} (JSONL Completions & Multimodal Offload)"
echo ""

"${DEMO_ROOT}/scripts/01_enable_apis_and_storage.sh"
"${DEMO_ROOT}/scripts/02_deploy_mcp_and_a2a.sh"
"${DEMO_ROOT}/scripts/03_deploy_orchestrator_and_topology.sh"

RE_ENGINE_ID=$(jq -r '.engine_id' "${STATE_DIR}/agent_info.json")
MCP_URL=$(jq -r '.mcp_url' "${STATE_DIR}/agent_info.json")
A2A_CARD_URL=$(jq -r '.a2a_card_url' "${STATE_DIR}/agent_info.json")

log_banner "Implantação Concluída com Sucesso!"

echo -e "${COLOR_GREEN}Recursos Provisionados:${COLOR_NC}"
echo "  • Reasoning Engine ID:  ${RE_ENGINE_ID} (${RE_DISPLAY_NAME})"
echo "  • Cloud Run A2A Agent:  ${A2A_CARD_URL}"
echo "  • Cloud Run MCP Server: ${MCP_URL}"
echo "  • BigQuery Analytics:   ${PROJECT_ID}.${BQ_DATASET}.${BQ_TABLE} (views: v_llm_response, v_tool_completed, v_a2a_interaction)"
echo "  • Cloud Trace Console:  https://console.cloud.google.com/traces/explorer?project=${PROJECT_ID}"
echo ""
echo -e "${COLOR_CYAN}Próximo passo — execute a suíte automatizada de testes em PT-BR:${COLOR_NC}"
echo "  ./test.sh"
echo ""
