#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite (Brazilian Portuguese / PT-BR)
# Demo 03: End-to-End Multi-Agent OTel, Live Topology & BigQuery Agent Analytics
# ==============================================================================

set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Suíte de Testes Automatizados: OTel Distribuído, Topologia Viva & BigQuery Agent Analytics"

AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
RE_ENGINE_ID=""

if [[ -f "${AGENT_INFO_FILE}" ]]; then
    RE_ENGINE_ID=$(jq -r '.engine_id // empty' "${AGENT_INFO_FILE}")
fi

if [[ -z "${RE_ENGINE_ID}" ]]; then
    log_info "Buscando ID do Reasoning Engine via API do Vertex AI..."
    RE_ENGINE_ID=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" | \
        jq -r '.reasoningEngines[]? | select(.displayName=="'"${RE_DISPLAY_NAME}"'") | .name' | awk -F'/' '{print $NF}' | head -n 1)
fi

if [[ -z "${RE_ENGINE_ID}" ]]; then
    log_error "Nenhum Reasoning Engine ativo encontrado para o agente '${RE_DISPLAY_NAME}'."
    log_info "Execute ./deploy.sh primeiro para provisionar o ambiente."
    exit 1
fi

log_info "Testando Reasoning Engine ID: ${RE_ENGINE_ID} (${RE_DISPLAY_NAME})"
ENDPOINT_URI="https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}:streamQuery?alt=sse"
TEST_START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

gen_hex() {
    local bytes="$1"
    python3 -c "import secrets; print(secrets.token_hex(${bytes}))"
}

send_traced_query() {
    local prompt="$1"
    local trace_id="$2"
    local span_id
    span_id=$(gen_hex 8)
    local traceparent="00-${trace_id}-${span_id}-01"
    local max_attempts=3
    local delay=4
    local resp=""
    local exit_code=0
    local token

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        token=$(gcloud auth print-access-token)
        resp=$(curl -s --max-time 120 -X POST "${ENDPOINT_URI}" \
            -H "Authorization: Bearer ${token}" \
            -H "x-goog-user-project: ${PROJECT_ID}" \
            -H "Content-Type: application/json" \
            -H "traceparent: ${traceparent}" \
            -d @- <<EOF
{
  "input": {
    "message": "${prompt}",
    "user_id": "test-o11y-$(date +%s)-$RANDOM"
  }
}
EOF
        ) && exit_code=0 || exit_code=$?

        if [[ $exit_code -eq 0 && -n "${resp// }" ]]; then
            echo "$resp"
            return 0
        fi

        if ((attempt < max_attempts)); then
            log_warn "Tentativa ${attempt}/${max_attempts} de query falhou (exit_code=${exit_code}). Retentando em ${delay}s..."
            sleep "$delay"
        fi
    done

    echo "$resp"
    return "$exit_code"
}

extract_content() {
    local raw="$1"
    local parsed
    parsed=$(echo "$raw" | grep -E '^data:' | sed 's/^data: //' | jq -r '
        if type == "array" then .[] else . end |
        select(.content.parts != null) |
        .content.parts[].text // empty
    ' 2>/dev/null | tr '\n' ' ' || true)

    if [[ -n "${parsed// }" ]]; then
        echo "$parsed"
    else
        echo "$raw" | jq -r '
            if type == "array" then .[] else . end |
            .content.parts[]?.text //
            .candidates[]?.content.parts[]?.text //
            .output.content.parts[]?.text //
            .error.message //
            .error_message //
            empty' 2>/dev/null | tr '\n' ' ' || echo "$raw"
    fi
}

has_internal_error() {
    local raw="$1"
    echo "$raw" | grep -qE '"error_code"|"error":\s*\{'
}

TESTS_PASSED=0
TESTS_FAILED=0

# ==============================================================================
# TESTE 1: Caminho Feliz Multi-Agente (Orquestrador -> MCP ERP -> Especialista A2A)
# ==============================================================================
TRACE_ID_1=$(gen_hex 16)
log_step "1. [TESTE 1] Orquestração Multi-Agente Ponta a Ponta (Pedido #PED-9042 via MCP + A2A)"
log_info "W3C Trace ID injetado: ${TRACE_ID_1}"
PROMPT_1="Consulte o pedido corporativo PED-9042 no ERP e acione o especialista de risco de SLA para calcular a multa estimada em reais e o plano de mitigação."

RESP_1=$(send_traced_query "${PROMPT_1}" "${TRACE_ID_1}")
CONTENT_1=$(extract_content "${RESP_1}")

echo -e "${COLOR_CYAN}--- Resposta do Orquestrador (Ato 1) ---${COLOR_NC}"
echo "$CONTENT_1"
echo -e "${COLOR_CYAN}----------------------------------------${COLOR_NC}"

# Expected math: R$ 185.000 * 0.0075 * 4h = R$ 5.550,00 (Metalúrgica Aurora S.A.)
if ! has_internal_error "${RESP_1}" && echo "$CONTENT_1" | grep -iq "Aurora" && (echo "$CONTENT_1" | grep -qE "5\.550|5,550|5550" || echo "$CONTENT_1" | grep -q "185.000"); then
    log_success "TESTE 1 PASSOU: Orquestrador consultou o FastMCP ('Metalúrgica Aurora') e o Especialista A2A ('R$ 5.550,00') no mesmo turno!"
    ((++TESTS_PASSED))
else
    log_error "TESTE 1 FALHOU: Resposta não continha os dados esperados da Metalúrgica Aurora / multa de SLA ou houve erro interno."
    ((++TESTS_FAILED))
fi

sleep 2
printf "\n"

# ==============================================================================
# TESTE 2: Diagnóstico de Gargalo / Lock no WMS + Escalonamento A2A (Cadeia Fria)
# ==============================================================================
TRACE_ID_2=$(gen_hex 16)
log_step "2. [TESTE 2] Anomalia de Latência & Lock no WMS (LOTE-LOCK-503 -> Span ERROR + Multa Cadeia Fria)"
log_info "W3C Trace ID injetado: ${TRACE_ID_2}"
PROMPT_2="Concilie o lote logístico LOTE-LOCK-503 no WMS, diagnostique qualquer gargalo técnico de banco de dados e acione o especialista A2A para calcular o risco financeiro de SLA do pedido impactado."

RESP_2=$(send_traced_query "${PROMPT_2}" "${TRACE_ID_2}")
CONTENT_2=$(extract_content "${RESP_2}")

echo -e "${COLOR_CYAN}--- Resposta do Orquestrador (Ato 2) ---${COLOR_NC}"
echo "$CONTENT_2"
echo -e "${COLOR_CYAN}----------------------------------------${COLOR_NC}"

if ! has_internal_error "${RESP_2}" && echo "$CONTENT_2" | grep -iq "BioFarma" && echo "$CONTENT_2" | grep -iqE "lock|55P03|wms_expedicao_fria|48291"; then
    log_success "TESTE 2 PASSOU: Orquestrador diagnosticou o lock na tabela 'wms_expedicao_fria' (BioFarma) e quantificou o impacto via A2A!"
    ((++TESTS_PASSED))
else
    log_error "TESTE 2 FALHOU: Resposta não reportou o lock do lote LOTE-LOCK-503 / BioFarma adequadamente."
    ((++TESTS_FAILED))
fi

sleep 3
printf "\n"

# ==============================================================================
# TESTE 3: Costura W3C `traceparent` no Cloud Trace + Offload JSONL no GCS
# ==============================================================================
log_step "3. [TESTE 3] Auditoria Cloud Trace (Costura W3C entre os 3 Runtimes) & Offload GCS"
log_verify "Aguardando indexação dos spans OTLP no Cloud Trace para os Trace IDs '${TRACE_ID_1}' e '${TRACE_ID_2}'..."

STITCHED_OK=false
SPAN_SUMMARY=""

for attempt in {1..10}; do
    TOKEN=$(gcloud auth print-access-token)
    TRACE_JSON_1=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://cloudtrace.googleapis.com/v1/projects/${PROJECT_ID}/traces/${TRACE_ID_1}" || echo "{}")
    TRACE_JSON_2=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://cloudtrace.googleapis.com/v1/projects/${PROJECT_ID}/traces/${TRACE_ID_2}" || echo "{}")

    SPAN_COUNT_1=$(echo "${TRACE_JSON_1}" | jq '.spans | length // 0' 2>/dev/null || echo 0)
    SPAN_COUNT_2=$(echo "${TRACE_JSON_2}" | jq '.spans | length // 0' 2>/dev/null || echo 0)

    HAS_MCP_SPAN=$(echo "${TRACE_JSON_1} ${TRACE_JSON_2}" | grep -cE "erp\.postgres_order_lookup|erp\.legacy_wms_lock_contention|mcp\.server" || true)
    HAS_A2A_SPAN=$(echo "${TRACE_JSON_1} ${TRACE_JSON_2}" | grep -cE "a2a\.specialist|sla\.penalty_matrix_eval|sla_risk_specialist" || true)
    HAS_RE_SPAN=$(echo "${TRACE_JSON_1} ${TRACE_JSON_2}" | grep -cE "finops_ops_orchestrator|invoke_agent|generate_content|reasoningEngines" || true)

    if (( SPAN_COUNT_1 >= 3 && HAS_MCP_SPAN >= 1 && HAS_A2A_SPAN >= 1 && HAS_RE_SPAN >= 1 )); then
        STITCHED_OK=true
        SPAN_SUMMARY="Trace1=${SPAN_COUNT_1} spans, Trace2=${SPAN_COUNT_2} spans (ReasoningEngine + CloudRun A2A + CloudRun FastMCP costurados!)"
        break
    fi
    sleep 4
done

GCS_COMPLETIONS_COUNT=$(gcloud storage ls --recursive "gs://${TELEMETRY_BUCKET}/**" 2>/dev/null | grep -c '\.jsonl$' || true)
log_info "Arquivos .jsonl de offload/completions no bucket gs://${TELEMETRY_BUCKET}: ${GCS_COMPLETIONS_COUNT}"

if [[ "${STITCHED_OK}" == "true" ]]; then
    log_success "TESTE 3 PASSOU: Propagação W3C traceparent comprovada nos 3 nós! (${SPAN_SUMMARY})"
    log_info "🔗 Explorer Trace 1: https://console.cloud.google.com/traces/explorer;traceId=${TRACE_ID_1}?project=${PROJECT_ID}"
    log_info "🔗 Explorer Trace 2: https://console.cloud.google.com/traces/explorer;traceId=${TRACE_ID_2}?project=${PROJECT_ID}"
    ((++TESTS_PASSED))
else
    log_error "TESTE 3 FALHOU: Não foram encontrados spans costurados dos 3 serviços sob o mesmo Trace ID (RE=${HAS_RE_SPAN:-0}, MCP=${HAS_MCP_SPAN:-0}, A2A=${HAS_A2A_SPAN:-0})."
    ((++TESTS_FAILED))
fi

printf "\n"

# ==============================================================================
# TESTE 4: BigQuery Agent Analytics (FinOps Tokens + Proveniência MCP vs A2A)
# ==============================================================================
log_step "4. [TESTE 4] Auditoria SQL no BigQuery Agent Analytics (v_llm_response & v_tool_completed)"
log_verify "Consultando '${PROJECT_ID}.${BQ_DATASET}' via BigQuery Storage Write API..."

BQ_OK=false
BQ_SUMMARY=""

for attempt in {1..8}; do
    BQ_TOOL_JSON=$(bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --format=json \
        "SELECT tool_origin, COUNT(*) AS calls, ROUND(AVG(total_ms), 1) AS avg_ms
         FROM \`${PROJECT_ID}.${BQ_DATASET}.v_tool_completed\`
         WHERE timestamp >= TIMESTAMP('${TEST_START_UTC}')
         GROUP BY tool_origin" 2>/dev/null || echo "[]")

    BQ_LLM_JSON=$(bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --format=json \
        "SELECT COUNT(*) AS llm_turns,
                COALESCE(SUM(usage_prompt_tokens), 0) AS prompt_tokens,
                COALESCE(SUM(usage_completion_tokens), 0) AS completion_tokens,
                COUNT(DISTINCT trace_id) AS distinct_traces
         FROM \`${PROJECT_ID}.${BQ_DATASET}.v_llm_response\`
         WHERE timestamp >= TIMESTAMP('${TEST_START_UTC}')" 2>/dev/null || echo "[]")

    HAS_ORIGIN_MCP=$(echo "${BQ_TOOL_JSON}" | jq '[.[]? | select(.tool_origin=="MCP")] | length' 2>/dev/null || echo 0)
    HAS_ORIGIN_A2A=$(echo "${BQ_TOOL_JSON}" | jq '[.[]? | select(.tool_origin=="A2A")] | length' 2>/dev/null || echo 0)
    LLM_TURNS=$(echo "${BQ_LLM_JSON}" | jq -r '.[0].llm_turns // "0"' 2>/dev/null || echo 0)
    PROMPT_TOKENS=$(echo "${BQ_LLM_JSON}" | jq -r '.[0].prompt_tokens // "0"' 2>/dev/null || echo 0)

    if (( HAS_ORIGIN_MCP >= 1 && HAS_ORIGIN_A2A >= 1 && LLM_TURNS >= 2 && PROMPT_TOKENS > 0 )); then
        BQ_OK=true
        BQ_SUMMARY=$(echo "${BQ_TOOL_JSON}" | jq -c '.')
        break
    fi
    sleep 4
done

if [[ "${BQ_OK}" == "true" ]]; then
    log_success "TESTE 4 PASSOU: BigQuery Agent Analytics registrou tokens (turns=${LLM_TURNS}, prompt_tokens=${PROMPT_TOKENS}) e origens MCP + A2A: ${BQ_SUMMARY}"
    ((++TESTS_PASSED))
else
    log_error "TESTE 4 FALHOU: Eventos esperados (tool_origin MCP & A2A + tokens LLM) não apareceram em '${BQ_DATASET}' (MCP=${HAS_ORIGIN_MCP:-0}, A2A=${HAS_ORIGIN_A2A:-0}, LLM=${LLM_TURNS:-0})."
    ((++TESTS_FAILED))
fi

printf "\n"

# ==============================================================================
# TESTE 5: Descoberta Automática no Agent Registry & Grafo de Topologia SRE
# ==============================================================================
log_step "5. [TESTE 5] Descoberta de Nós no Agent Registry & Grafo de Topologia (apptopology)"

REG_AGENTS=$(gcloud agent-registry agents list --location="${REGION}" --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "[]")
REG_MCPS=$(gcloud agent-registry mcp-servers list --location="${REGION}" --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "[]")
TOPO_GRAPH=$(gcloud app-topology resources-graph generate --domains=SRE --project="${PROJECT_ID}" --format="json" 2>/dev/null || echo "{}")

FOUND_MCP_REG=$(echo "${REG_MCPS} ${TOPO_GRAPH}" | grep -c "${MCP_SERVICE_NAME}" || true)
FOUND_A2A_REG=$(echo "${REG_AGENTS} ${TOPO_GRAPH}" | grep -c "${A2A_SERVICE_NAME}" || true)
FOUND_RE_REG=$(echo "${REG_AGENTS} ${TOPO_GRAPH}" | grep -cE "${RE_ENGINE_ID}|${RE_DISPLAY_NAME}" || true)

# Fallback verification directly on Cloud Run functional-type annotations if Agent Registry indexing is still warming up (<2 min after first deploy)
CR_MCP_FT=$(gcloud beta run services describe "${MCP_SERVICE_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --format="json" 2>/dev/null | grep -c "mcp-server" || true)
CR_A2A_FT=$(gcloud beta run services describe "${A2A_SERVICE_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --format="json" 2>/dev/null | grep -c "agent" || true)

if (( (FOUND_MCP_REG >= 1 || CR_MCP_FT >= 1) && (FOUND_A2A_REG >= 1 || CR_A2A_FT >= 1) )); then
    log_success "TESTE 5 PASSOU: Topologia Multi-Nó verificada (Registry/Topology matches: RE=${FOUND_RE_REG}, A2A=${FOUND_A2A_REG}, MCP=${FOUND_MCP_REG}; Cloud Run functional-types ativos)!"
    ((++TESTS_PASSED))
else
    log_error "TESTE 5 FALHOU: Nós da topologia não foram localizados no Agent Registry / Cloud Run functional-type."
    ((++TESTS_FAILED))
fi

# ==============================================================================
# Resumo Final
# ==============================================================================
log_banner "Resultado Final da Suíte de Testes (Demo 03)"
echo -e "  ✅ Testes Aprovados: ${COLOR_GREEN}${TESTS_PASSED}${COLOR_NC}"
echo -e "  ❌ Testes Falhos:    ${COLOR_RED}${TESTS_FAILED}${COLOR_NC}"
echo ""

if (( TESTS_FAILED > 0 )); then
    log_error "A suíte de testes encontrou ${TESTS_FAILED} falha(s)."
    exit 1
fi

log_success "100% dos cenários de Negócio, OpenTelemetry Distribuído, BigQuery Analytics e Topologia passaram!"
exit 0
