#!/usr/bin/env bash
# ==============================================================================
# Script 01: Enable Required GCP APIs & Provision Service Identities
# Demo 02: Agent Gateway to Anywhere (Egress) — Zero-Trust MCP & Anti-Exfiltration
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 01: Habilitando APIs do Google Cloud e Agentes de Serviço"

check_command gcloud "Instale o Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
check_command jq "sudo apt-get install jq / brew install jq"
check_command curl "sudo apt-get install curl"
check_command python3 "Instale Python 3.10+"

APIS=(
    "agentregistry.googleapis.com"
    "aiplatform.googleapis.com"
    "artifactregistry.googleapis.com"
    "cloudapiregistry.googleapis.com"
    "cloudbuild.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "cloudtrace.googleapis.com"
    "compute.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "iap.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
    "networksecurity.googleapis.com"
    "networkservices.googleapis.com"
    "observability.googleapis.com"
    "run.googleapis.com"
    "serviceextensions.googleapis.com"
    "serviceusage.googleapis.com"
    "storage.googleapis.com"
    "telemetry.googleapis.com"
)

log_step "1. Habilitando ${#APIS[@]} APIs necessárias no projeto '${PROJECT_ID}' (em lotes <= 15)..."
gcloud services enable "${APIS[@]:0:12}" --project="${PROJECT_ID}" --quiet
gcloud services enable "${APIS[@]:12}" --project="${PROJECT_ID}" --quiet
log_success "Todas as APIs foram habilitadas com sucesso!"

log_step "2. Provisionando identidades de Agentes de Serviço (Service Identities)..."
SERVICE_IDENTITIES=(
    "aiplatform.googleapis.com"
    "networkservices.googleapis.com"
    "serviceextensions.googleapis.com"
    "iap.googleapis.com"
    "agentregistry.googleapis.com"
    "run.googleapis.com"
)

for svc in "${SERVICE_IDENTITIES[@]}"; do
    log_info "Garantindo identidade gerenciada para ${svc}..."
    gcloud beta services identity create --service="${svc}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
done

log_step "3. Garantindo permissões de build para o Cloud Run (Default Compute SA em Argolis)..."
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for role in \
    "roles/run.builder" \
    "roles/storage.objectAdmin" \
    "roles/artifactregistry.writer" \
    "roles/logging.logWriter"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${COMPUTE_SA}" \
        --role="${role}" \
        --condition=None \
        --quiet >/dev/null
done

log_success "APIs, Service Identities e permissões base configuradas!"
log_banner "Etapa 01 Concluída com Sucesso!"
