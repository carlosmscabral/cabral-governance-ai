#!/usr/bin/env bash
# ==============================================================================
# Central Environment Configuration & Preflight Resolution
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

# Find demo root directory
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load common library if available
if [[ -f "${DEMO_ROOT}/lib/common.sh" ]]; then
    source "${DEMO_ROOT}/lib/common.sh"
fi

# Detect Project ID
export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
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
        log_info "Verifique se você possui permissões de 'roles/resourcemanager.projectViewer'."
    else
        echo "❌ [ERRO] Falha ao obter PROJECT_NUMBER para '${PROJECT_ID}'" >&2
    fi
    return 1 2>/dev/null || exit 1
fi

# Regional & Model Settings
export REGION="${REGION:-us-central1}"
export MODEL_NAME="${MODEL_NAME:-gemini-flash-latest}"
export MODEL_LOCATION="${MODEL_LOCATION:-global}"
export GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-global}"
export VERTEX_AI_LOCATION="${VERTEX_AI_LOCATION:-global}"
export AGENT_LOCATION="${AGENT_LOCATION:-global}"

# Resource Naming Slugs (PREFIX is used to namespace all provisioned resources)
export PREFIX="${PREFIX:-agw-modar}"
export AGW_NAME="${AGW_NAME:-${PREFIX}-ingress}"
export AGW_URI="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_NAME}"

# Storage Buckets
export DATA_BUCKET="${DATA_BUCKET:-${PROJECT_ID}-${PREFIX}-data}"
export STAGING_BUCKET="${STAGING_BUCKET:-${PROJECT_ID}-${PREFIX}-staging}"

# Sensitive Data Protection (DLP) Templates
export DLP_INSPECT_TEMPLATE_ID="${DLP_INSPECT_TEMPLATE_ID:-${PREFIX}-ssn-inspect}"
export DLP_DEIDENTIFY_TEMPLATE_ID="${DLP_DEIDENTIFY_TEMPLATE_ID:-${PREFIX}-ssn-redact}"

# Model Armor Templates
export MODAR_REQ_TEMPLATE_ID="${MODAR_REQ_TEMPLATE_ID:-${PREFIX}-req-template}"
export MODAR_RESP_TEMPLATE_ID="${MODAR_RESP_TEMPLATE_ID:-${PREFIX}-resp-template}"

# Service Extensions & Network Security Authz
export AUTHZ_EXT_NAME="${AUTHZ_EXT_NAME:-${PREFIX}-svc-ext-authz}"
export AUTHZ_POLICY_NAME="${AUTHZ_POLICY_NAME:-${PREFIX}-authz-policy}"

# Vertex AI Reasoning Engine Display Name
export RE_DISPLAY_NAME="${RE_DISPLAY_NAME:-${PREFIX}-agent-crm}"

# State Directory for Idempotent Tracking
export STATE_DIR="${DEMO_ROOT}/.state"
mkdir -p "${STATE_DIR}"
