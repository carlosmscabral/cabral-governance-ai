#!/usr/bin/env bash
# ==============================================================================
# Central Environment Configuration & Preflight Resolution
# Demo 03: End-to-End Multi-Agent OTel, Live Topology & BigQuery Agent Analytics
# ==============================================================================

# Find demo root directory
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load common library if available
if [[ -f "${DEMO_ROOT}/lib/common.sh" ]]; then
    source "${DEMO_ROOT}/lib/common.sh"
fi

# Auto-select 'argolis' gcloud configuration if available and not explicitly overridden
if [[ -z "${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" ]]; then
    if gcloud config configurations describe argolis &>/dev/null; then
        export CLOUDSDK_ACTIVE_CONFIG_NAME="argolis"
    fi
fi

# Non-interactive gcloud execution
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# Standardize Project ID (default: cabral-governance-ai)
export PROJECT_ID="${PROJECT_ID:-cabral-governance-ai}"
export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"
if [[ -z "${PROJECT_ID:-}" ]]; then
    if declare -f log_error >/dev/null; then
        log_error "PROJECT_ID não definido e nenhuma configuração ativa do gcloud foi encontrada."
        log_info "Defina via: export PROJECT_ID=seu-projeto-gcp"
    else
        echo "❌ [ERRO] PROJECT_ID não definido. Defina via export PROJECT_ID=seu-projeto-gcp" >&2
    fi
    return 1 2>/dev/null || exit 1
fi

# Fetch Project Number
export PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null)}"
if [[ -z "${PROJECT_NUMBER:-}" ]]; then
    if declare -f log_error >/dev/null; then
        log_error "Não foi possível obter o PROJECT_NUMBER para o projeto '${PROJECT_ID}'."
        log_info "Verifique se você está autenticado (gcloud config configurations list) e possui 'roles/resourcemanager.projectViewer'."
    else
        echo "❌ [ERRO] Falha ao obter PROJECT_NUMBER para '${PROJECT_ID}'" >&2
    fi
    return 1 2>/dev/null || exit 1
fi

# Discover Organization ID (needed to pre-compute Cloud Run SPIFFE Agent Identity URI)
if [[ -z "${ORG_ID:-}" ]]; then
    ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --format="json" 2>/dev/null | \
        jq -r '.[]? | select(.type=="organization") | .id' | head -n 1 || true)
fi
export ORG_ID="${ORG_ID:-}"

# Regional & Model Settings (Model Location ALWAYS global per AGENTS.md)
export REGION="${REGION:-us-central1}"
export MODEL_NAME="${MODEL_NAME:-gemini-3.8-flash}"
export MODEL_LOCATION="global"
export GOOGLE_CLOUD_LOCATION="global"
export VERTEX_AI_LOCATION="global"
export AGENT_LOCATION="global"

# Resource Naming Slugs (PREFIX isolates Demo 03 cleanly from Demo 01 and Demo 02)
export PREFIX="${PREFIX:-o11y}"

# Storage Buckets (Staging for Reasoning Engine + JSONL Offload for GenAI OTel Hook)
export STAGING_BUCKET="${STAGING_BUCKET:-${PROJECT_ID}-${PREFIX}-staging}"
export TELEMETRY_BUCKET="${TELEMETRY_BUCKET:-${PROJECT_ID}-${PREFIX}-telemetry}"

# BigQuery Agent Analytics & Cloud Trace Linked Dataset
export BQ_DATASET="${BQ_DATASET:-geap_o11y_demo03}"
export BQ_TABLE="${BQ_TABLE:-agent_events}"
export BQ_TRACES_LINKED_DATASET="${BQ_TRACES_LINKED_DATASET:-geap_o11y_traces_linked}"

# Node 3: Cloud Run Streamable HTTP FastMCP Server (--functional-type=mcp-server)
export MCP_SERVICE_NAME="${MCP_SERVICE_NAME:-${PREFIX}-mcp-erp-ops}"
export MCP_RUNTIME_SA_NAME="${MCP_RUNTIME_SA_NAME:-sa-${PREFIX}-mcp-runtime}"
export MCP_RUNTIME_SA="${MCP_RUNTIME_SA:-${MCP_RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

# Node 2: Cloud Run Specialist A2A Agent (--functional-type=agent --identity-type=agent-identity)
export A2A_SERVICE_NAME="${A2A_SERVICE_NAME:-${PREFIX}-a2a-sla-risk}"
export A2A_DETERMINISTIC_HOST="${A2A_SERVICE_NAME}-${PROJECT_NUMBER}.${REGION}.run.app"

# Dedicated Invoker Service Account (impersonated by Orchestrator SPIFFE identity for Cloud Run OIDC)
export CR_INVOKER_SA_NAME="${CR_INVOKER_SA_NAME:-sa-${PREFIX}-cr-invoker}"
export CR_INVOKER_SA="${CR_INVOKER_SA:-${CR_INVOKER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

# Node 1: Vertex AI Reasoning Engine Orchestrator (ADK + BigQueryAgentAnalyticsPlugin)
export RE_DISPLAY_NAME="${RE_DISPLAY_NAME:-${PREFIX}-agent-orchestrator}"

# App Hub Application Grouping for Multi-Node SRE Topology
export APPHUB_APP_ID="${APPHUB_APP_ID:-${PREFIX}-multiagent-app}"

# State Directory for Idempotent Tracking
export STATE_DIR="${DEMO_ROOT}/.state"
mkdir -p "${STATE_DIR}"
