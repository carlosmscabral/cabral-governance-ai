#!/usr/bin/env bash
# ==============================================================================
# Script 03: Create Cloud DLP & Model Armor Security Guardrail Templates
# Demo: Agent Gateway Ingress with Agent Runtime & Model Armor
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${DEMO_ROOT}/lib/common.sh"
source "${DEMO_ROOT}/env.sh"
setup_error_trap

log_banner "Etapa 03: Criação de Templates do Cloud DLP e Model Armor"

# Ensure Model Armor endpoint override is set
gcloud config set api_endpoint_overrides/modelarmor "https://modelarmor.${REGION}.rep.googleapis.com/" 2>/dev/null || true

TOKEN=$(gcloud auth print-access-token)

# ------------------------------------------------------------------------------
# 1. Cloud DLP Inspect Template
# ------------------------------------------------------------------------------
log_step "1. Configurando DLP Inspect Template para detecção de SSN/PII..."
DLP_INSPECT_URI="https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/inspectTemplates/${DLP_INSPECT_TEMPLATE_ID}"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT_ID}" "${DLP_INSPECT_URI}")

if [[ "$HTTP_STATUS" == "200" ]]; then
    log_info "DLP Inspect Template '${DLP_INSPECT_TEMPLATE_ID}' já existe."
else
    log_info "Criando DLP Inspect Template '${DLP_INSPECT_TEMPLATE_ID}'..."
    curl -s -f -X POST "https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/inspectTemplates" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        -H "Content-Type: application/json" \
        -d @- <<EOF
{
  "templateId": "${DLP_INSPECT_TEMPLATE_ID}",
  "inspectTemplate": {
    "displayName": "Template de Inspeção SSN/PII para Agent Gateway",
    "description": "Detecta números de seguro social (US_SOCIAL_SECURITY_NUMBER) em respostas de agentes",
    "inspectConfig": {
      "infoTypes": [
        { "name": "US_SOCIAL_SECURITY_NUMBER" }
      ],
      "minLikelihood": "POSSIBLE"
    }
  }
}
EOF
    printf "\n"
    log_success "DLP Inspect Template criado com sucesso!"
fi

# ------------------------------------------------------------------------------
# 2. Cloud DLP De-identify Template
# ------------------------------------------------------------------------------
log_step "2. Configurando DLP De-identify Template para redação automática..."
DLP_DEIDENTIFY_URI="https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/deidentifyTemplates/${DLP_DEIDENTIFY_TEMPLATE_ID}"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT_ID}" "${DLP_DEIDENTIFY_URI}")

if [[ "$HTTP_STATUS" == "200" ]]; then
    log_info "DLP De-identify Template '${DLP_DEIDENTIFY_TEMPLATE_ID}' já existe."
else
    log_info "Criando DLP De-identify Template '${DLP_DEIDENTIFY_TEMPLATE_ID}'..."
    curl -s -f -X POST "https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/deidentifyTemplates" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "x-goog-user-project: ${PROJECT_ID}" \
        -H "Content-Type: application/json" \
        -d @- <<EOF
{
  "templateId": "${DLP_DEIDENTIFY_TEMPLATE_ID}",
  "deidentifyTemplate": {
    "displayName": "Template de Redação SSN para Agent Gateway",
    "description": "Substitui SSNs pelo marcador [US_SOCIAL_SECURITY_NUMBER]",
    "deidentifyConfig": {
      "infoTypeTransformations": {
        "transformations": [
          {
            "infoTypes": [
              { "name": "US_SOCIAL_SECURITY_NUMBER" }
            ],
            "primitiveTransformation": {
              "replaceWithInfoTypeConfig": {}
            }
          }
        ]
      }
    }
  }
}
EOF
    printf "\n"
    log_success "DLP De-identify Template criado com sucesso!"
fi


# ------------------------------------------------------------------------------
# 3. Model Armor Request Template
# ------------------------------------------------------------------------------
log_step "3. Configurando Template de Requisição do Model Armor (Filtros de Prompt/Ataque)..."
if gcloud beta model-armor templates describe "${MODAR_REQ_TEMPLATE_ID}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Model Armor Request Template '${MODAR_REQ_TEMPLATE_ID}' já existe."
else
    log_info "Criando Model Armor Request Template '${MODAR_REQ_TEMPLATE_ID}'..."
    gcloud beta model-armor templates create "${MODAR_REQ_TEMPLATE_ID}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --rai-settings-filters='[
            { "filterType": "HATE_SPEECH", "confidenceLevel": "MEDIUM_AND_ABOVE" },
            { "filterType": "HARASSMENT", "confidenceLevel": "MEDIUM_AND_ABOVE" },
            { "filterType": "SEXUALLY_EXPLICIT", "confidenceLevel": "MEDIUM_AND_ABOVE" }
        ]' \
        --pi-and-jailbreak-filter-settings-enforcement=enabled \
        --pi-and-jailbreak-filter-settings-confidence-level=medium-and-above \
        --malicious-uri-filter-settings-enforcement=enabled \
        --template-metadata-custom-llm-response-safety-error-code=798 \
        --template-metadata-custom-llm-response-safety-error-message="A resposta foi bloqueada pela política de segurança de conteúdo do Model Armor." \
        --template-metadata-custom-prompt-safety-error-code=799 \
        --template-metadata-custom-prompt-safety-error-message="A requisição foi bloqueada pelo filtro de segurança de conteúdo do Model Armor." \
        --template-metadata-ignore-partial-invocation-failures \
        --template-metadata-log-operations \
        --template-metadata-log-sanitize-operations
    
    log_success "Model Armor Request Template criado com sucesso!"
fi

# ------------------------------------------------------------------------------
# 4. Model Armor Response Template
# ------------------------------------------------------------------------------
log_step "4. Configurando Template de Resposta do Model Armor (Integração com Cloud DLP)..."
if gcloud beta model-armor templates describe "${MODAR_RESP_TEMPLATE_ID}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    log_info "Model Armor Response Template '${MODAR_RESP_TEMPLATE_ID}' já existe."
else
    log_info "Criando Model Armor Response Template '${MODAR_RESP_TEMPLATE_ID}'..."
    gcloud beta model-armor templates create "${MODAR_RESP_TEMPLATE_ID}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --rai-settings-filters='[
            { "filterType": "HATE_SPEECH", "confidenceLevel": "MEDIUM_AND_ABOVE" },
            { "filterType": "HARASSMENT", "confidenceLevel": "MEDIUM_AND_ABOVE" },
            { "filterType": "SEXUALLY_EXPLICIT", "confidenceLevel": "MEDIUM_AND_ABOVE" }
        ]' \
        --malicious-uri-filter-settings-enforcement=enabled \
        --advanced-config-inspect-template="projects/${PROJECT_ID}/locations/${REGION}/inspectTemplates/${DLP_INSPECT_TEMPLATE_ID}" \
        --advanced-config-deidentify-template="projects/${PROJECT_ID}/locations/${REGION}/deidentifyTemplates/${DLP_DEIDENTIFY_TEMPLATE_ID}" \
        --template-metadata-ignore-partial-invocation-failures \
        --template-metadata-log-operations \
        --template-metadata-log-sanitize-operations
    
    log_success "Model Armor Response Template criado com sucesso!"
fi

log_banner "Etapa 03 Concluída com Sucesso!"
