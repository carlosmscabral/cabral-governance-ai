#!/usr/bin/env bash
# ==============================================================================
# Master Teardown & Zero-Residual Cleanup Script
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Iniciando Desprovisionamento Completo (Zero-Residuals)"

# Ensure Model Armor endpoint override is set for template deletion
gcloud config set api_endpoint_overrides/modelarmor "https://modelarmor.${REGION}.rep.googleapis.com/" 2>/dev/null || true
TOKEN=$(gcloud auth print-access-token)

# ------------------------------------------------------------------------------
# 1. Delete Vertex AI Reasoning Engine & Clear Agent IAM
# ------------------------------------------------------------------------------
log_step "1. Removendo Reasoning Engine do Vertex AI..."

AGENT_INFO_FILE="${STATE_DIR}/agent_info.json"
RE_ENGINE_ID=""
if [[ -f "${AGENT_INFO_FILE}" ]]; then
    RE_ENGINE_ID=$(jq -r '.engine_id // empty' "${AGENT_INFO_FILE}")
fi

if [[ -z "${RE_ENGINE_ID}" ]]; then
    RE_ENGINE_ID=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" | \
        jq -r '.reasoningEngines[] | select(.displayName=="'"${RE_DISPLAY_NAME}"'") | .name' | awk -F'/' '{print $NF}' | head -n 1)
fi

if [[ -n "${RE_ENGINE_ID}" ]]; then
    log_info "Deletando Reasoning Engine '${RE_ENGINE_ID}'..."
    curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ENGINE_ID}?force=true" >/dev/null || true
    log_success "Reasoning Engine removido."
else
    log_info "Nenhum Reasoning Engine ativo encontrado para remoção."
fi

# Remove PrincipalSet IAM
PRINCIPAL_SET="principalSet://agents.aiplatform.googleapis.com/projects/${PROJECT_NUMBER}/locations/${REGION}/platformContainer/*"
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="${PRINCIPAL_SET}" \
    --role="roles/mcp.toolUser" \
    --condition=None \
    --quiet &>/dev/null || true

# ------------------------------------------------------------------------------
# 2. Delete Cloud Storage Buckets
# ------------------------------------------------------------------------------
log_step "2. Removendo Buckets do Cloud Storage (Dados e Staging)..."

for bucket in "${DATA_BUCKET}" "${STAGING_BUCKET}"; do
    if gcloud storage buckets describe "gs://${bucket}" &>/dev/null; then
        log_info "Removendo objetos e deletando bucket 'gs://${bucket}'..."
        gcloud storage rm --recursive "gs://${bucket}" --quiet 2>/dev/null || true
        log_success "Bucket 'gs://${bucket}' deletado."
    fi
done

# ------------------------------------------------------------------------------
# 3. Delete Network Security Authz Policy
# ------------------------------------------------------------------------------
log_step "3. Deletando Network Security Authz Policy..."
if gcloud beta network-security authz-policies describe "${AUTHZ_POLICY_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud beta network-security authz-policies delete "${AUTHZ_POLICY_NAME}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
    log_success "Authz Policy '${AUTHZ_POLICY_NAME}' removida."
else
    log_info "Authz Policy '${AUTHZ_POLICY_NAME}' não encontrada."
fi

# ------------------------------------------------------------------------------
# 4. Delete Service Extensions Authz Extension
# ------------------------------------------------------------------------------
log_step "4. Deletando Service Extension Authz Extension..."
if gcloud beta service-extensions authz-extensions describe "${AUTHZ_EXT_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud beta service-extensions authz-extensions delete "${AUTHZ_EXT_NAME}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
    log_success "Authz Extension '${AUTHZ_EXT_NAME}' removida."
else
    log_info "Authz Extension '${AUTHZ_EXT_NAME}' não encontrada."
fi

# Remove DEP SA roles
DEP_SA="service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"
for role in "roles/modelarmor.calloutUser" "roles/serviceusage.serviceUsageConsumer" "roles/modelarmor.user"; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${DEP_SA}" \
        --role="${role}" \
        --condition=None \
        --quiet &>/dev/null || true
done

# ------------------------------------------------------------------------------
# 5. Delete Model Armor Templates
# ------------------------------------------------------------------------------
log_step "5. Deletando Templates do Model Armor..."

for tpl in "${MODAR_RESP_TEMPLATE_ID}" "${MODAR_REQ_TEMPLATE_ID}"; do
    if gcloud beta model-armor templates describe "${tpl}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        log_info "Deletando template Model Armor '${tpl}'..."
        gcloud beta model-armor templates delete "${tpl}" \
            --location="${REGION}" \
            --project="${PROJECT_ID}" \
            --quiet 2>/dev/null || true
        log_success "Template '${tpl}' removido."
    fi
done

# Unset endpoint override
gcloud config unset api_endpoint_overrides/modelarmor 2>/dev/null || true

# ------------------------------------------------------------------------------
# 6. Delete Cloud DLP Templates
# ------------------------------------------------------------------------------
log_step "6. Deletando Templates do Cloud Sensitive Data Protection (DLP)..."

# Deidentify template
DLP_DEIDENTIFY_URI="https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/deidentifyTemplates/${DLP_DEIDENTIFY_TEMPLATE_ID}"
curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT_ID}" "${DLP_DEIDENTIFY_URI}" >/dev/null || true

# Inspect template
DLP_INSPECT_URI="https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/inspectTemplates/${DLP_INSPECT_TEMPLATE_ID}"
curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT_ID}" "${DLP_INSPECT_URI}" >/dev/null || true

log_success "Templates do Cloud DLP removidos."

# Remove Model Armor SA role
MODEL_ARMOR_SA="service-${PROJECT_NUMBER}@gcp-sa-modelarmor.iam.gserviceaccount.com"
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${MODEL_ARMOR_SA}" \
    --role="roles/dlp.user" \
    --condition=None \
    --quiet &>/dev/null || true

# ------------------------------------------------------------------------------
# 7. Delete Agent Gateway
# ------------------------------------------------------------------------------
log_step "7. Deletando Agent Gateway..."
if gcloud network-services agent-gateways describe "${AGW_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Deletando Agent Gateway '${AGW_NAME}'..."
    gcloud network-services agent-gateways delete "${AGW_NAME}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
    log_success "Agent Gateway '${AGW_NAME}' removido."
else
    log_info "Agent Gateway '${AGW_NAME}' não encontrado."
fi

# ------------------------------------------------------------------------------
# 8. Clean Local State
# ------------------------------------------------------------------------------
log_step "8. Limpando artefatos e arquivos temporários locais..."
rm -rf "${STATE_DIR}"
log_success "Diretório de estado local limpo."

log_banner "Desprovisionamento Concluído! Todos os Recursos Foram Limpos Sem Resíduos."
