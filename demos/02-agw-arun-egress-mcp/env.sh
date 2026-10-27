#!/usr/bin/env bash
# ==============================================================================
# Central Environment Configuration & Preflight Resolution
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
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

# Regional & Model Settings (Model Location ALWAYS global per AGENTS.md)
export REGION="${REGION:-us-central1}"
export MODEL_NAME="${MODEL_NAME:-gemini-3.8-flash}"
export MODEL_LOCATION="global"
export GOOGLE_CLOUD_LOCATION="global"
export VERTEX_AI_LOCATION="global"
export AGENT_LOCATION="global"

# Resource Naming Slugs (PREFIX namespaces all Demo 02 resources cleanly from Demo 01)
export PREFIX="${PREFIX:-agw-egress}"
export AGW_NAME="${AGW_NAME:-${PREFIX}-ata}"
export AGW_URI="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_NAME}"

# Storage Staging Bucket
export STAGING_BUCKET="${STAGING_BUCKET:-${PROJECT_ID}-${PREFIX}-staging}"

# Cloud Run MCP Server & Invoker Service Account (Zero VPC / Standalone HTTPS + OIDC IAM)
export MCP_SERVICE_NAME="${MCP_SERVICE_NAME:-${PREFIX}-mcp-erp}"
export MCP_DISPLAY_NAME="${MCP_DISPLAY_NAME:-erp.tesouraria.mcp}"
export MCP_INVOKER_SA_NAME="${MCP_INVOKER_SA_NAME:-sa-${PREFIX}-mcp-invoker}"
export MCP_INVOKER_SA="${MCP_INVOKER_SA:-${MCP_INVOKER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

# Agent Registry Catalog Services
export GAPI_SERVICE_NAME="${GAPI_SERVICE_NAME:-${PREFIX}-core-gapi}"
export GAPI_DISPLAY_NAME="${GAPI_DISPLAY_NAME:-gapi.core.services}"
export MCP_REGISTRY_SERVICE_NAME="${MCP_REGISTRY_SERVICE_NAME:-${PREFIX}-mcp-erp}"

# Service Extensions (IAP) & Network Security Authz Policy (REQUEST_AUTHZ)
export AUTHZ_EXT_DRYRUN="${AUTHZ_EXT_DRYRUN:-${PREFIX}-svc-ext-iap-dryrun}"
export AUTHZ_EXT_ENFORCED="${AUTHZ_EXT_ENFORCED:-${PREFIX}-svc-ext-iap-enforced}"
export AUTHZ_POLICY_NAME="${AUTHZ_POLICY_NAME:-${PREFIX}-authz-policy}"

# Vertex AI Reasoning Engine Display Name
export RE_DISPLAY_NAME="${RE_DISPLAY_NAME:-${PREFIX}-agent-finops}"

# State Directory for Idempotent Tracking
export STATE_DIR="${DEMO_ROOT}/.state"
mkdir -p "${STATE_DIR}"
