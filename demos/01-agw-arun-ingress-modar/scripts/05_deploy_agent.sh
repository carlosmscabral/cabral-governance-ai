#!/usr/bin/env bash
# ==============================================================================
# Script 05: Stage Data, Deploy ADK Agent to Reasoning Engine & Bind IAM
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 05: Preparação de Dados, Deploy do Agente ADK no Vertex AI e Configuração de IAM"

# ------------------------------------------------------------------------------
# 1. Cloud Storage Buckets Provisioning
# ------------------------------------------------------------------------------
log_step "1. Verificando e criando buckets de Staging e Dados no Cloud Storage..."

# Staging Bucket
if gcloud storage buckets describe "gs://${STAGING_BUCKET}" &>/dev/null; then
    log_info "Bucket de staging 'gs://${STAGING_BUCKET}' já existe."
else
    log_info "Criando bucket de staging 'gs://${STAGING_BUCKET}'..."
    gcloud storage buckets create "gs://${STAGING_BUCKET}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --uniform-bucket-level-access
    log_success "Bucket de staging criado com sucesso!"
fi

# Data Bucket
if gcloud storage buckets describe "gs://${DATA_BUCKET}" &>/dev/null; then
    log_info "Bucket de dados 'gs://${DATA_BUCKET}' já existe."
else
    log_info "Criando bucket de dados 'gs://${DATA_BUCKET}'..."
    gcloud storage buckets create "gs://${DATA_BUCKET}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --uniform-bucket-level-access
    log_success "Bucket de dados criado com sucesso!"
fi

# ------------------------------------------------------------------------------
# 2. Upload Customer Datasets to Data Bucket
# ------------------------------------------------------------------------------
log_step "2. Fazendo upload dos datasets de clientes (Leste, Oeste, VIP) para o bucket de dados..."
gcloud storage cp "${DEMO_ROOT}/src/data/"*.csv "gs://${DATA_BUCKET}/"
log_success "Arquivos CSV sincronizados com 'gs://${DATA_BUCKET}'."

# ------------------------------------------------------------------------------
# 3. Deploy ADK Agent to Vertex AI Reasoning Engine
# ------------------------------------------------------------------------------
log_step "3. Verificando e realizando deploy do Agente ADK no Vertex AI Agent Runtime..."

AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
NEED_DEPLOY=true

# Ensure Python Virtual Environment exists
VENV_DIR="${DEMO_ROOT}/.venv"
if [[ ! -f "${VENV_DIR}/bin/python" ]]; then
    log_info "Criando ambiente virtual Python e instalando dependências do ADK..."
    if command -v uv &>/dev/null; then
        uv venv "${VENV_DIR}" --python python3
        uv pip install --python "${VENV_DIR}/bin/python" "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" "google-cloud-storage>=2.14.0"
    else
        python3 -m venv "${VENV_DIR}"
        "${VENV_DIR}/bin/pip" install "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" "google-cloud-storage>=2.14.0"
    fi
fi
PYTHON_EXEC="${VENV_DIR}/bin/python"

if [[ -f "${AGENT_INFO_FILE}" ]]; then
    SAVED_ENGINE_ID=$(jq -r '.engine_id // empty' "${AGENT_INFO_FILE}")
    if [[ -n "${SAVED_ENGINE_ID}" ]]; then
        log_verify "Verificando se Reasoning Engine '${SAVED_ENGINE_ID}' ainda existe..."
        if curl -s -f -H "Authorization: Bearer $(gcloud auth print-access-token)" \
            -H "x-goog-user-project: ${PROJECT_ID}" \
            "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${SAVED_ENGINE_ID}" &>/dev/null; then
            log_info "Reasoning Engine '${SAVED_ENGINE_ID}' já está ativo e operacional."
            NEED_DEPLOY=false
        fi
    fi
fi

if [[ "$NEED_DEPLOY" == "true" ]]; then
    log_info "Iniciando deploy do agente ADK com ingress governado via Agent Gateway..."
    log_info "Gateway Ingress: ${AGW_URI}"
    log_info "Modelo: ${MODEL_NAME}"
    
    "${PYTHON_EXEC}" "${DEMO_ROOT}/src/deploy_agent.py" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --staging-bucket="${STAGING_BUCKET}" \
        --data-bucket="${DATA_BUCKET}" \
        --model-name="${MODEL_NAME}" \
        --agent-gateway-ingress="${AGW_URI}" \
        --display-name="${RE_DISPLAY_NAME}" \
        --output-json="${AGENT_INFO_FILE}" \
        --enable-agent-identity \
        --enable-telemetry \
        --allow-token-sharing

    log_success "Deploy concluído com sucesso!"
fi


# Load engine ID
RE_ENGINE_ID=$(jq -r '.engine_id' "${AGENT_INFO_FILE}")
log_info "ID do Reasoning Engine: ${COLOR_BOLD}${RE_ENGINE_ID}${COLOR_NC}"

# ------------------------------------------------------------------------------
# 4. Bind IAM Permissions to Agent SPIFFE Identity & PrincipalSet
# ------------------------------------------------------------------------------
log_step "4. Configurando privilégio mínimo (IAM) para a identidade SPIFFE do Agente..."

# Fetch reasoning engine metadata from Vertex AI API to extract exact Agent Identity
TOKEN=$(gcloud auth print-access-token)
RE_METADATA=$(curl -s -f -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}")

# Resolve Organization Ancestor for canonical SPIFFE Trust Domain
ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --filter="type:organization" --format="value(id)" 2>/dev/null || true)

if [[ -n "$ORG_ID" ]]; then
    AGENT_SPIFFE="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}"
    AGENT_PRINCIPAL_SET="principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
else
    AGENT_SPIFFE="principal://agents.global.project-${PROJECT_NUMBER}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}"
    AGENT_PRINCIPAL_SET="principalSet://agents.global.project-${PROJECT_NUMBER}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
fi

log_info "Identidade SPIFFE do Agente: ${COLOR_CYAN}${AGENT_SPIFFE}${COLOR_NC}"
log_info "PrincipalSet da Frota: ${COLOR_CYAN}${AGENT_PRINCIPAL_SET}${COLOR_NC}"

# Grant storage.objectViewer directly to SPIFFE Agent Identity on the Data Bucket
log_info "Concedendo roles/storage.objectViewer no bucket 'gs://${DATA_BUCKET}' para a Identidade SPIFFE e SA de runtime..."
gcloud storage buckets add-iam-policy-binding "gs://${DATA_BUCKET}" \
    --member="${AGENT_SPIFFE}" \
    --role="roles/storage.objectViewer" --quiet &>/dev/null || true
gcloud storage buckets add-iam-policy-binding "gs://${DATA_BUCKET}" \
    --member="${AGENT_PRINCIPAL_SET}" \
    --role="roles/storage.objectViewer" --quiet &>/dev/null || true
gcloud storage buckets add-iam-policy-binding "gs://${DATA_BUCKET}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/storage.objectViewer" --quiet &>/dev/null || true
gcloud storage buckets add-iam-policy-binding "gs://${DATA_BUCKET}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com" \
    --role="roles/storage.objectViewer" --quiet &>/dev/null || true

# Grant Telemetry, Logging and Vertex AI User roles to SPIFFE Agent Identity
log_info "Concedendo papéis de telemetria e observabilidade à Identidade SPIFFE do agente..."
for role in "roles/aiplatform.user" "roles/cloudtrace.agent" "roles/telemetry.writer" "roles/logging.logWriter"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="${AGENT_SPIFFE}" \
        --role="${role}" \
        --condition=None \
        --quiet &>/dev/null || true
done

log_success "Políticas IAM de identidade e acesso vinculadas com sucesso!"

log_banner "Etapa 05 Concluída com Sucesso!"
