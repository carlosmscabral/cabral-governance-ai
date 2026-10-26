#!/usr/bin/env bash
# ==============================================================================
# Weekly CI Healthcheck & Drift Detector for cabral-governance-ai Demos
# Runs preflight Argolis auth check, optional SDK upgrade, deploy.sh & test.sh
# ==============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/.state/ci_logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(TZ=America/Sao_Paulo date +%Y%m%d_%H%M%S)"
SUMMARY_LOG="${LOG_DIR}/ci_${TIMESTAMP}.log"

UPGRADE_SDK=false
FULL_REBUILD=false

for arg in "$@"; do
    case "$arg" in
        --upgrade-sdk) UPGRADE_SDK=true ;;
        --full-rebuild) FULL_REBUILD=true ;;
    esac
done

export CLOUDSDK_ACTIVE_CONFIG_NAME="${CLOUDSDK_ACTIVE_CONFIG_NAME:-argolis}"
export PROJECT_ID="${PROJECT_ID:-cabral-governance-ai}"

echo "================================================================================" | tee -a "${SUMMARY_LOG}"
echo "🩺 [CI HEALTHCHECK] Iniciando validação em $(TZ=America/Sao_Paulo date '+%Y-%m-%d %H:%M:%S BRT')" | tee -a "${SUMMARY_LOG}"
echo "   Repo:    ${REPO_ROOT}" | tee -a "${SUMMARY_LOG}"
echo "   Project: ${PROJECT_ID} (gcloud config: ${CLOUDSDK_ACTIVE_CONFIG_NAME})" | tee -a "${SUMMARY_LOG}"
echo "   Flags:   upgrade_sdk=${UPGRADE_SDK}, full_rebuild=${FULL_REBUILD}" | tee -a "${SUMMARY_LOG}"
echo "================================================================================" | tee -a "${SUMMARY_LOG}"

# 1. Preflight Check: Argolis OAuth Token
if ! TOKEN=$(gcloud auth print-access-token --configuration="${CLOUDSDK_ACTIVE_CONFIG_NAME}" 2>>"${SUMMARY_LOG}") || [[ -z "${TOKEN}" ]]; then
    echo "❌ [AUTH_EXPIRED] Token OAuth da configuração '${CLOUDSDK_ACTIVE_CONFIG_NAME}' expirou ou está indisponível." | tee -a "${SUMMARY_LOG}"
    echo "👉 Ação necessária pelo usuário: gcloud auth login --configuration=${CLOUDSDK_ACTIVE_CONFIG_NAME}" | tee -a "${SUMMARY_LOG}"
    exit 2
fi
echo "✅ [PREFLIGHT] Token OAuth Argolis válido." | tee -a "${SUMMARY_LOG}"

# 2.Preflight Check: Verify gemini-3.8-flash availability on global Vertex AI endpoint
HTTP_MODEL=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/publishers/google/models/gemini-3.8-flash:generateContent" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"role":"user","parts":[{"text":"ping"}]}]}')

if [[ "${HTTP_MODEL}" != "200" ]]; then
    echo "⚠️ [MODEL_DRIFT] Modelo padrão 'gemini-3.8-flash' (global) retornou HTTP ${HTTP_MODEL}!" | tee -a "${SUMMARY_LOG}"
else
    echo "✅ [PREFLIGHT] Modelo 'gemini-3.8-flash' (global) ativo (HTTP 200)." | tee -a "${SUMMARY_LOG}"
fi

OVERALL_FAILED=0
DEMOS_TESTED=0

for demo_dir in "${REPO_ROOT}/demos/"*; do
    [[ -d "${demo_dir}" ]] || continue
    [[ -x "${demo_dir}/deploy.sh" && -x "${demo_dir}/test.sh" ]] || continue

    demo_name="$(basename "${demo_dir}")"
    ((++DEMOS_TESTED))
    DEMO_LOG="${LOG_DIR}/${demo_name}_${TIMESTAMP}.log"

    echo "" | tee -a "${SUMMARY_LOG}"
    echo "--------------------------------------------------------------------------------" | tee -a "${SUMMARY_LOG}"
    echo "🚀 Testando Demo: ${demo_name}" | tee -a "${SUMMARY_LOG}"
    echo "--------------------------------------------------------------------------------" | tee -a "${SUMMARY_LOG}"

    (
        cd "${demo_dir}"
        if [[ "${UPGRADE_SDK}" == "true" && -d ".venv" ]]; then
            echo "📦 [SDK UPGRADE] Atualizando pacotes Python em ${demo_name}/.venv..."
            if command -v uv &>/dev/null; then
                uv pip install --upgrade --python ".venv/bin/python" \
                    "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" \
                    "google-cloud-storage>=2.14.0" \
                    "pydantic>=2.0.0" \
                    "cloudpickle>=3.0.0"
            else
                ".venv/bin/pip" install --upgrade \
                    "google-cloud-aiplatform[adk,agent_engines]>=1.80.0" \
                    "google-cloud-storage>=2.14.0" \
                    "pydantic>=2.0.0" \
                    "cloudpickle>=3.0.0"
            fi
        fi

        if [[ "${FULL_REBUILD}" == "true" && -x "./undeploy.sh" ]]; then
            echo "🧹 [FULL REBUILD] Executando ./undeploy.sh..."
            ./undeploy.sh
        fi

        echo "🛠️ [DEPLOY] Executando ./deploy.sh..."
        ./deploy.sh

        echo "🧪 [TEST] Executando ./test.sh..."
        ./test.sh
    ) > "${DEMO_LOG}" 2>&1
    DEMO_RC=$?

    cat "${DEMO_LOG}" >> "${SUMMARY_LOG}"

    if [[ ${DEMO_RC} -eq 0 ]]; then
        echo "✅ [PASSOU] Demo '${demo_name}' validada com sucesso (deploy + test)!" | tee -a "${SUMMARY_LOG}"
    else
        echo "❌ [FALHOU] Demo '${demo_name}' falhou (exit code ${DEMO_RC}). Veja detalhes em: ${DEMO_LOG}" | tee -a "${SUMMARY_LOG}"
        echo "--- Últimas 40 linhas de ${DEMO_LOG} ---"
        tail -n 40 "${DEMO_LOG}"
        ((++OVERALL_FAILED))
    fi
done

echo "" | tee -a "${SUMMARY_LOG}"
echo "================================================================================" | tee -a "${SUMMARY_LOG}"
echo "📊 [RESUMO CI] Demos testadas: ${DEMOS_TESTED} | Falhas: ${OVERALL_FAILED}" | tee -a "${SUMMARY_LOG}"
echo "📄 Log consolidado: ${SUMMARY_LOG}" | tee -a "${SUMMARY_LOG}"
echo "================================================================================" | tee -a "${SUMMARY_LOG}"

if (( OVERALL_FAILED > 0 )); then
    exit 1
fi
exit 0
