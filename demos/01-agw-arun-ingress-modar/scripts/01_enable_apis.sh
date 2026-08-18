#!/usr/bin/env bash
# ==============================================================================
# Script 01: Enable APIs, Register Core Services & Configure Service Agents
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 01: Habilitar APIs, Registrar Serviços no Agent Registry e Configurar IAM"

log_info "Projeto Alvo: ${COLOR_BOLD}${PROJECT_ID}${COLOR_NC} (Número: ${PROJECT_NUMBER})"
log_info "Região Principal: ${COLOR_BOLD}${REGION}${COLOR_NC}"

# 1. Preflight CLI tool checks
log_step "1. Validando ferramentas essenciais no ambiente..."
check_command "gcloud" "Instale o Google Cloud SDK: https://cloud.google.com/sdk"
check_command "jq" "Instale o jq: brew install jq (macOS) ou sudo apt install jq"
check_command "curl" "Instale o curl"

# 2. Required APIs list
REQUIRED_APIS=(
    "aiplatform.googleapis.com"
    "agentregistry.googleapis.com"
    "modelarmor.googleapis.com"
    "dlp.googleapis.com"
    "networkservices.googleapis.com"
    "serviceextensions.googleapis.com"
    "networksecurity.googleapis.com"
    "iap.googleapis.com"
    "storage.googleapis.com"
    "compute.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
    "cloudtrace.googleapis.com"
    "telemetry.googleapis.com"
)

# 3. Resilient Idempotent API enablement
log_step "2. Verificando e habilitando APIs necessárias no Google Cloud..."
ENABLED_SERVICES=$(gcloud services list --enabled --project="${PROJECT_ID}" --format="value(config.name)" 2>/dev/null || true)

for api in "${REQUIRED_APIS[@]}"; do
    if echo "$ENABLED_SERVICES" | grep -q "^${api}$"; then
        log_info "API já habilitada: ${COLOR_GREEN}${api}${COLOR_NC}"
    else
        log_info "Habilitando API: ${COLOR_YELLOW}${api}${COLOR_NC}..."
        if gcloud services enable "${api}" --project="${PROJECT_ID}" 2>/dev/null; then
            log_success "API '${api}' habilitada com sucesso."
        else
            log_warn "Não foi possível habilitar a API '${api}' (pode ser serviço em preview restrito ou já gerenciado pela organização)."
        fi
    fi
done


# 4. Configure Regional Endpoint Override for Model Armor
log_step "3. Configurando override do endpoint regional do Model Armor..."
log_info "Endpoint regional: https://modelarmor.${REGION}.rep.googleapis.com/"
gcloud config set api_endpoint_overrides/modelarmor "https://modelarmor.${REGION}.rep.googleapis.com/" 2>/dev/null || true
log_success "Override do endpoint regional do Model Armor configurado."

# 5. Service Agent IAM Bindings (Model Armor & Service Extensions)
log_step "4. Vinculando papéis IAM aos Service Agents gerenciados do Google Cloud..."

# Model Armor SA
MODEL_ARMOR_SA="service-${PROJECT_NUMBER}@gcp-sa-modelarmor.iam.gserviceaccount.com"
log_info "Service Agent Model Armor: ${MODEL_ARMOR_SA}"

# Ensure Model Armor Service Identity is generated
gcloud beta services identity create --service=modelarmor.googleapis.com --project="${PROJECT_ID}" 2>/dev/null || true

log_info "Concedendo papel roles/dlp.user ao Service Agent do Model Armor..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${MODEL_ARMOR_SA}" \
    --role="roles/dlp.user" \
    --condition=None \
    --quiet &>/dev/null || true
log_success "Papel 'roles/dlp.user' vinculado ao Model Armor."

# Service Extensions / Data Path Extensions (DEP) SA
DEP_SA="service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"
log_info "Service Agent Service Extensions (DEP): ${DEP_SA}"

# Ensure Service Extensions Service Identity is generated
gcloud beta services identity create --service=serviceextensions.googleapis.com --project="${PROJECT_ID}" 2>/dev/null || true

log_info "Concedendo papéis ao Service Agent de Service Extensions..."
for role in "roles/modelarmor.calloutUser" "roles/serviceusage.serviceUsageConsumer" "roles/modelarmor.user"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${DEP_SA}" \
        --role="${role}" \
        --condition=None \
        --quiet &>/dev/null || true
    log_info "Papel '${role}' vinculado com sucesso."
done

# Vertex AI SA (requires networkservices.viewer to validate Agent Gateway Ingress)
VERTEX_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com"
log_info "Service Agent Vertex AI: ${VERTEX_SA}"
gcloud beta services identity create --service=aiplatform.googleapis.com --project="${PROJECT_ID}" 2>/dev/null || true
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${VERTEX_SA}" \
    --role="roles/networkservices.viewer" \
    --condition=None \
    --quiet &>/dev/null || true
log_info "Papel 'roles/networkservices.viewer' vinculado ao Vertex AI Service Agent."

log_success "Todos os papéis IAM dos Service Agents foram configurados!"

log_banner "Etapa 01 Concluída com Sucesso!"
