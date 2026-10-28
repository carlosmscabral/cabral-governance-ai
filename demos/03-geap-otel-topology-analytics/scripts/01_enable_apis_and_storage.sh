#!/usr/bin/env bash
# ==============================================================================
# Passo 01: Habilitação de APIs, Identidades IAM, Buckets GCS, BigQuery & Trace Link
# Demo 03: End-to-End Multi-Agent OTel, Live Topology & BigQuery Agent Analytics
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_step "01. Habilitando APIs do Google Cloud, Storage, BigQuery e Observability..."

APIS_BATCH_1=(
    "aiplatform.googleapis.com"
    "run.googleapis.com"
    "cloudbuild.googleapis.com"
    "artifactregistry.googleapis.com"
    "storage.googleapis.com"
    "bigquery.googleapis.com"
    "bigquerystorage.googleapis.com"
    "logging.googleapis.com"
    "cloudtrace.googleapis.com"
    "monitoring.googleapis.com"
    "telemetry.googleapis.com"
)

APIS_BATCH_2=(
    "agentregistry.googleapis.com"
    "apphub.googleapis.com"
    "apptopology.googleapis.com"
    "observability.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "cloudresourcemanager.googleapis.com"
)

log_info "Ativando lote 1 de APIs (Runtime, Storage, BigQuery & OpenTelemetry)..."
gcloud services enable "${APIS_BATCH_1[@]}" --project="${PROJECT_ID}" --quiet
log_info "Ativando lote 2 de APIs (Agent Registry, App Hub, App Topology & IAM)..."
gcloud services enable "${APIS_BATCH_2[@]}" --project="${PROJECT_ID}" --quiet
log_success "Todas as APIs necessárias estão habilitadas."

# Provision Google-managed Service Agents
log_info "Garantindo provisionamento de Service Agents gerenciados..."
for svc in aiplatform.googleapis.com run.googleapis.com agentregistry.googleapis.com apphub.googleapis.com apptopology.googleapis.com observability.googleapis.com; do
    gcloud beta services identity create --service="${svc}" --project="${PROJECT_ID}" --quiet &>/dev/null || true
done

# Grant Cloud Build source deploy permissions to default Compute Engine SA
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
log_info "Garantindo permissões de Cloud Build para a conta padrão (${COMPUTE_SA})..."
for role in "roles/cloudbuild.builds.builder" "roles/storage.admin" "roles/artifactregistry.writer" "roles/logging.logWriter"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${COMPUTE_SA}" \
        --role="${role}" \
        --condition=None \
        --quiet >/dev/null
done

# Create dedicated Service Account for Cloud Run FastMCP Server runtime
if ! gcloud iam service-accounts describe "${MCP_RUNTIME_SA}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Criando Service Account de runtime do MCP Server '${MCP_RUNTIME_SA_NAME}'..."
    gcloud iam service-accounts create "${MCP_RUNTIME_SA_NAME}" \
        --display-name="Demo 03 OTel FastMCP Server Runtime SA" \
        --project="${PROJECT_ID}" \
        --quiet
    sleep 5
else
    log_info "Service Account '${MCP_RUNTIME_SA}' já existe."
fi

log_info "Concedendo papéis de exportação OTLP (Telemetry/Trace/Logging) para '${MCP_RUNTIME_SA}'..."
for role in "roles/telemetry.writer" "roles/telemetry.tracesWriter" "roles/cloudtrace.agent" "roles/logging.logWriter" "roles/monitoring.metricWriter" "roles/browser"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${MCP_RUNTIME_SA}" \
        --role="${role}" \
        --condition=None \
        --quiet >/dev/null
done

# Create dedicated OIDC Invoker Service Account (impersonated by Orchestrator SPIFFE Identity)
if ! gcloud iam service-accounts describe "${CR_INVOKER_SA}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Criando Service Account Invoker OIDC '${CR_INVOKER_SA_NAME}'..."
    gcloud iam service-accounts create "${CR_INVOKER_SA_NAME}" \
        --display-name="Demo 03 Cloud Run OIDC Invoker SA (MCP + A2A)" \
        --project="${PROJECT_ID}" \
        --quiet
    sleep 5
else
    log_info "Service Account '${CR_INVOKER_SA}' já existe."
fi

# Provision GCS Buckets (Staging + Telemetry Offload)
for bkt in "${STAGING_BUCKET}" "${TELEMETRY_BUCKET}"; do
    if ! gcloud storage buckets describe "gs://${bkt}" --project="${PROJECT_ID}" &>/dev/null; then
        log_info "Criando bucket GCS 'gs://${bkt}' em '${REGION}'..."
        gcloud storage buckets create "gs://${bkt}" \
            --project="${PROJECT_ID}" \
            --location="${REGION}" \
            --uniform-bucket-level-access \
            --quiet
    else
        log_info "Bucket GCS 'gs://${bkt}' já existe."
    fi
done
log_success "Buckets GCS de Staging e Telemetria prontos."

# Provision BigQuery Dataset for BigQueryAgentAnalyticsPlugin (multi-region US)
if ! bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${BQ_DATASET}" &>/dev/null; then
    log_info "Criando dataset BigQuery '${PROJECT_ID}:${BQ_DATASET}' (location=US)..."
    bq --project_id="${PROJECT_ID}" --location=US mk \
        --dataset \
        --description="Demo 03: Real-Time ADK BigQuery Agent Analytics (FinOps, Tool Provenance & OTel Trace Join)" \
        "${PROJECT_ID}:${BQ_DATASET}"
else
    log_info "Dataset BigQuery '${PROJECT_ID}:${BQ_DATASET}' já existe."
fi
log_success "Dataset BigQuery '${BQ_DATASET}' pronto."

# Enable Log Analytics on _Default bucket (idempotent)
log_info "Garantindo Log Analytics ativo no bucket '_Default'..."
gcloud logging buckets update _Default --location=global --enable-analytics --project="${PROJECT_ID}" --quiet &>/dev/null || true

# Provision Zero-Copy Linked Dataset in BigQuery for Cloud Trace (_AllSpans)
log_info "Verificando Linked Dataset BigQuery '${BQ_TRACES_LINKED_DATASET}' para Cloud Trace (_AllSpans)..."
TRACE_OBS_DATASET=$(gcloud observability buckets datasets list \
    --bucket="_Trace" \
    --location="global" \
    --project="${PROJECT_ID}" \
    --format="value(name)" 2>/dev/null | head -n 1 | awk -F'/' '{print $NF}' || true)

if [[ -n "${TRACE_OBS_DATASET}" ]]; then
    if gcloud observability buckets datasets links describe "${BQ_TRACES_LINKED_DATASET}" \
        --bucket="_Trace" \
        --dataset="${TRACE_OBS_DATASET}" \
        --location="global" \
        --project="${PROJECT_ID}" &>/dev/null; then
        log_info "Linked Dataset '${BQ_TRACES_LINKED_DATASET}' (_AllSpans) já está ativo."
    else
        log_info "Criando Linked Dataset '${BQ_TRACES_LINKED_DATASET}' no bucket _Trace (dataset=${TRACE_OBS_DATASET})..."
        if gcloud observability buckets datasets links create "${BQ_TRACES_LINKED_DATASET}" \
            --bucket="_Trace" \
            --dataset="${TRACE_OBS_DATASET}" \
            --location="global" \
            --description="Zero-copy Cloud Trace _AllSpans linked dataset for Demo 03 SQL joins" \
            --project="${PROJECT_ID}" \
            --quiet &>/dev/null; then
            log_success "Linked Dataset '${BQ_TRACES_LINKED_DATASET}._AllSpans' criado com sucesso!"
        else
            log_warn "Não foi possível criar automaticamente o link '${BQ_TRACES_LINKED_DATASET}' (prosseguindo com Cloud Trace API + '${BQ_DATASET}')."
        fi
    fi
else
    log_info "Dataset de spans em '_Trace' ainda será inicializado pelo primeiro trace; tentaremos vincular novamente após o tráfego se necessário."
fi

log_success "Passo 01 concluído com sucesso!"
