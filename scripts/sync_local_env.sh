#!/usr/bin/env bash
# ==============================================================================
# Bootstrap & Sync de Ambiente Local (.env em 2 camadas + ADC Argolis isolado)
#
# Uso na raiz do repositório (gMac ou Linux):
#   ./scripts/sync_local_env.sh
#
# Flags opcionais:
#   --use-global-gcloud   Usa a configuração `argolis` global (~/.config/gcloud)
#                         em vez de criar `.gcp/gcloud-argolis` dentro do repo.
#   --account EMAIL       Override da conta Argolis (default: admin@carloscabral.altostrat.com)
#   --project PROJECT_ID  Override do projeto GCP (default: cabral-governance-ai)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Nota: NÃO herdamos PROJECT_ID/REGION/MODEL_NAME implícitos do shell pai (ex.: ~/.zshrc
# exportando PROJECT_ID de outro repo como cabral-ca-da-caixa). Use --project se quiser override.
USE_GLOBAL_GCLOUD=0
ARGOLIS_ACCOUNT="admin@carloscabral.altostrat.com"
PROJECT_ID="cabral-governance-ai"
REGION="us-central1"
MODEL_NAME="gemini-3.8-flash"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --use-global-gcloud)
            USE_GLOBAL_GCLOUD=1
            shift
            ;;
        --account)
            ARGOLIS_ACCOUNT="$2"
            shift 2
            ;;
        --project)
            PROJECT_ID="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "❌ [ERRO] Flag desconhecida: $1" >&2
            exit 1
            ;;
    esac
done

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

echo "=============================================================================="
echo "🔧 Sincronizando Ambiente Local Estático — ${PROJECT_ID}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Configurar gcloud + ADC isolado em .gcp/gcloud-argolis (sem tocar no global)
# ------------------------------------------------------------------------------
if [[ "${USE_GLOBAL_GCLOUD}" -eq 0 ]]; then
    GCLOUD_DIR="${REPO_ROOT}/.gcp/gcloud-argolis"
    mkdir -p "${GCLOUD_DIR}"
    export CLOUDSDK_CONFIG="${GCLOUD_DIR}"

    # IMPORTANTE: se o shell do usuário já tiver CLOUDSDK_ACTIVE_CONFIG_NAME=argolis,
    # criamos primeiro o perfil `argolis` usando `default` no bootstrap para evitar:
    # "ERROR: Cannot set property in configuration [argolis], it does not exist."
    if ! CLOUDSDK_ACTIVE_CONFIG_NAME=default gcloud config configurations describe argolis &>/dev/null; then
        echo "📁 Criando perfil isolado [argolis] em .gcp/gcloud-argolis..."
        CLOUDSDK_ACTIVE_CONFIG_NAME=default gcloud config configurations create argolis --activate >/dev/null
    else
        CLOUDSDK_ACTIVE_CONFIG_NAME=default gcloud config configurations activate argolis >/dev/null 2>&1 || true
    fi
    export CLOUDSDK_ACTIVE_CONFIG_NAME="argolis"

    ADC_FILE="${GCLOUD_DIR}/application_default_credentials.json"

    # Verifica se já há sessão OAuth válida + arquivo ADC (reaproveita login já feito!)
    NEED_LOGIN=0
    if [[ ! -f "${ADC_FILE}" ]]; then
        NEED_LOGIN=1
    elif ! gcloud auth print-access-token "${ARGOLIS_ACCOUNT}" &>/dev/null; then
        NEED_LOGIN=1
    fi

    if [[ "${NEED_LOGIN}" -eq 1 ]]; then
        echo "🔐 Autenticando ${ARGOLIS_ACCOUNT} no navegador (credenciais salvas só em .gcp/)..."
        CLOUDSDK_CORE_DISABLE_PROMPTS=0 gcloud auth login "${ARGOLIS_ACCOUNT}" --update-adc
    else
        echo "✅ Credenciais OAuth + ADC existentes em .gcp/gcloud-argolis reutilizadas."
    fi

    # Carimba quota_project_id no ADC JSON ANTES do `gcloud config set project`
    # para eliminar o warning de quota project e evitar uso do projeto compartilhado 32555940559
    if [[ -f "${ADC_FILE}" ]]; then
        python3 - "${ADC_FILE}" "${PROJECT_ID}" <<'PY'
import json, sys
adc_path, project_id = sys.argv[1], sys.argv[2]
with open(adc_path, "r", encoding="utf-8") as f:
    data = json.load(f)
if data.get("quota_project_id") != project_id:
    data["quota_project_id"] = project_id
    with open(adc_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PY
    fi

    gcloud config set account "${ARGOLIS_ACCOUNT}" >/dev/null 2>&1
    gcloud config set project "${PROJECT_ID}" >/dev/null 2>&1
    gcloud config set api_endpoint_overrides/modelarmor "https://modelarmor.${REGION}.rep.googleapis.com/" >/dev/null 2>&1
else
    export CLOUDSDK_ACTIVE_CONFIG_NAME="argolis"
    GCLOUD_DIR=""
    ADC_FILE=""
    echo "ℹ️  Usando configuração global gcloud [argolis]."
fi

# ------------------------------------------------------------------------------
# 2. Resolver metadados do projeto (PROJECT_NUMBER, ORG_ID) e Access Token
# ------------------------------------------------------------------------------
ACCESS_TOKEN="$(gcloud auth print-access-token)"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
ORG_ID="$(gcloud projects get-ancestors "${PROJECT_ID}" --format='json' 2>/dev/null | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((x["id"] for x in d if x.get("type")=="organization"), ""))' || true)"
ORG_ID="${ORG_ID:-970548019292}"

echo "✅ Projeto verificado: ${PROJECT_ID} (number=${PROJECT_NUMBER}, org=${ORG_ID})"

# ------------------------------------------------------------------------------
# 3. Gerar `/.env` da raiz + `demos/<NN>/.env` completos + `.state/agent_info.json`
# ------------------------------------------------------------------------------
echo "🔎 Descobrindo Reasoning Engines e serviços Cloud Run ativos em ${REGION}..."

RUN_SERVICES_JSON="$(gcloud run services list --project="${PROJECT_ID}" --region="${REGION}" --format='json' 2>/dev/null || echo '[]')"

REPO_ROOT="${REPO_ROOT}" \
GCLOUD_DIR="${GCLOUD_DIR}" \
ADC_FILE="${ADC_FILE}" \
PROJECT_ID="${PROJECT_ID}" \
PROJECT_NUMBER="${PROJECT_NUMBER}" \
ORG_ID="${ORG_ID}" \
REGION="${REGION}" \
MODEL_NAME="${MODEL_NAME}" \
ACCESS_TOKEN="${ACCESS_TOKEN}" \
RUN_SERVICES_JSON="${RUN_SERVICES_JSON}" \
python3 - <<'PY'
import json
import os
import subprocess
import urllib.request
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
gcloud_dir = os.environ.get("GCLOUD_DIR", "")
adc_file = os.environ.get("ADC_FILE", "")
project_id = os.environ["PROJECT_ID"]
project_number = os.environ["PROJECT_NUMBER"]
org_id = os.environ["ORG_ID"]
region = os.environ["REGION"]
model_name = os.environ["MODEL_NAME"]
token = os.environ["ACCESS_TOKEN"]
run_services = json.loads(os.environ.get("RUN_SERVICES_JSON", "[]") or "[]")

# 1. Consultar Reasoning Engines vivos na Vertex AI
re_url = f"https://{region}-aiplatform.googleapis.com/v1beta1/projects/{project_id}/locations/{region}/reasoningEngines"
req = urllib.request.Request(
    re_url,
    headers={
        "Authorization": f"Bearer {token}",
        "x-goog-user-project": project_id,
    },
)
reasoning_engines = []
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
        reasoning_engines = payload.get("reasoningEngines", [])
except urllib.error.HTTPError as exc:
    err_body = exc.read().decode("utf-8", errors="replace")[:300]
    print(f"⚠️  Aviso: falha ao listar Reasoning Engines via API (HTTP {exc.code}: {err_body}); usando .state local se existir.")
except Exception as exc:
    print(f"⚠️  Aviso: falha ao listar Reasoning Engines via API ({exc}); usando .state local se existir.")

# Indexar Reasoning Engines por displayName (mantendo o mais recente se houver mais de um)
re_by_display: dict[str, dict] = {}
for item in sorted(reasoning_engines, key=lambda x: x.get("createTime", "")):
    disp = item.get("displayName", "")
    if disp:
        re_by_display[disp] = item

# Indexar Cloud Run URLs por nome de serviço
run_url_by_name: dict[str, str] = {}
for svc in run_services:
    name = svc.get("metadata", {}).get("name", "")
    url = svc.get("status", {}).get("url", "")
    if name and url:
        run_url_by_name[name] = url

# 2. Montar linhas base do /.env da raiz
root_lines = [
    "# ==============================================================================",
    "# AUTO-GENERATED BY ./scripts/sync_local_env.sh — DO NOT COMMIT (.gitignore)",
    "# Root defaults for cabral-governance-ai (Argolis + Gemini global + GEAP runtime)",
    "# ==============================================================================",
    "CLOUDSDK_ACTIVE_CONFIG_NAME=argolis",
]
if gcloud_dir:
    root_lines.append(f"CLOUDSDK_CONFIG={gcloud_dir}")
if adc_file:
    root_lines.append(f"GOOGLE_APPLICATION_CREDENTIALS={adc_file}")

root_lines.extend([
    f"GOOGLE_CLOUD_QUOTA_PROJECT={project_id}",
    "",
    f"PROJECT_ID={project_id}",
    f"PROJECT_NUMBER={project_number}",
    f"ORG_ID={org_id}",
    f"GOOGLE_CLOUD_PROJECT={project_id}",
    f"CLOUDSDK_CORE_PROJECT={project_id}",
    f"REGION={region}",
    "",
    "# Modelo Gemini (SEMPRE global) vs. Região do Reasoning Engine (us-central1)",
    "GOOGLE_GENAI_USE_VERTEXAI=True",
    f"MODEL_NAME={model_name}",
    "MODEL_LOCATION=global",
    "GOOGLE_CLOUD_LOCATION=global",
    "VERTEX_AI_LOCATION=global",
    "AGENT_LOCATION=global",
    f"GOOGLE_CLOUD_AGENT_ENGINE_LOCATION={region}",
    "",
    "# Defaults de Runtime ADK, mTLS (evita conflito com cert corp no gMac) e OTel GEAP",
    "ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING=1",
    "GOOGLE_API_USE_CLIENT_CERTIFICATE=false",
    "GOOGLE_API_USE_MTLS_ENDPOINT=never",
    "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false",
    "",
    "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true",
    "OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental",
    "ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false",
    "OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true",
])

root_env_path = repo_root / ".env"
root_env_path.write_text("\n".join(root_lines) + "\n", encoding="utf-8")
(repo_root / ".envrc").write_text("dotenv .env\n", encoding="utf-8")
print(f"  ✔ Raiz: .env e .envrc gerados ({root_env_path})")

# 3. Para cada demo em demos/*, extrair variáveis de env.sh e mesclar com recursos vivos
demos_dir = repo_root / "demos"
demo_keys_of_interest = [
    "PREFIX",
    "RE_DISPLAY_NAME",
    "AGW_NAME",
    "AGW_URI",
    "DATA_BUCKET",
    "STAGING_BUCKET",
    "TELEMETRY_BUCKET",
    "MCP_SERVICE_NAME",
    "MCP_INVOKER_SA",
    "A2A_SERVICE_NAME",
    "A2A_DETERMINISTIC_HOST",
    "CR_INVOKER_SA",
    "BQ_DATASET",
    "BQ_TABLE",
    "BQ_TRACES_LINKED_DATASET",
    "APPHUB_APP_ID",
]

for demo_dir in sorted(demos_dir.iterdir()):
    env_sh = demo_dir / "env.sh"
    if not demo_dir.is_dir() or not env_sh.is_file():
        continue

    # Avaliar env.sh em subshell limpo (sem herdar PREFIX/AGW/etc. de outro projeto no shell pai)
    cmd = (
        f"source {str(env_sh)!r} >/dev/null 2>&1 && "
        "python3 -c 'import json, os, sys; print(json.dumps({k: os.environ.get(k, \"\") for k in sys.argv[1:]}))' "
        + " ".join(demo_keys_of_interest)
    )
    sub_env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", ""),
        "PROJECT_ID": project_id,
        "PROJECT_NUMBER": project_number,
        "ORG_ID": org_id,
        "REGION": region,
        "MODEL_NAME": model_name,
        "CLOUDSDK_ACTIVE_CONFIG_NAME": "argolis",
    }
    if gcloud_dir:
        sub_env["CLOUDSDK_CONFIG"] = gcloud_dir
    raw = subprocess.check_output(["bash", "-c", cmd], env=sub_env, text=True).strip()
    dvars = json.loads(raw.splitlines()[-1])

    re_display = dvars.get("RE_DISPLAY_NAME", "")
    re_obj = re_by_display.get(re_display)

    state_dir = demo_dir / ".state"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "agent_info.json"
    existing_state = {}
    if state_file.is_file():
        try:
            existing_state = json.loads(state_file.read_text(encoding="utf-8"))
        except Exception:
            existing_state = {}

    engine_name = existing_state.get("reasoning_engine_name", "")
    engine_id = existing_state.get("engine_id", "")
    agent_identity = existing_state.get("agent_identity")

    if re_obj:
        engine_name = re_obj.get("name", engine_name)
        engine_id = engine_name.split("/")[-1] if engine_name else engine_id
        eff_id = (
            re_obj.get("spec", {})
            .get("effectiveIdentity", "")
        )
        if eff_id:
            agent_identity = eff_id

    mcp_svc = dvars.get("MCP_SERVICE_NAME", "")
    mcp_url = existing_state.get("mcp_url", "")
    if mcp_svc and mcp_svc in run_url_by_name:
        mcp_url = run_url_by_name[mcp_svc].rstrip("/") + "/mcp"

    a2a_svc = dvars.get("A2A_SERVICE_NAME", "")
    a2a_card_url = existing_state.get("a2a_card_url", "")
    if a2a_svc:
        if dvars.get("A2A_DETERMINISTIC_HOST"):
            a2a_card_url = f"https://{dvars['A2A_DETERMINISTIC_HOST']}/.well-known/agent-card.json"
        elif a2a_svc in run_url_by_name:
            a2a_card_url = run_url_by_name[a2a_svc].rstrip("/") + "/.well-known/agent-card.json"

    # Atualizar .state/agent_info.json local (habilita Agent Console e test.sh no gMac)
    if engine_id:
        new_state = dict(existing_state)
        new_state.update({
            "reasoning_engine_name": engine_name,
            "engine_id": engine_id,
            "agent_identity": agent_identity,
            "project": project_id,
            "region": region,
        })
        if dvars.get("AGW_URI"):
            if "ingress" in demo_dir.name:
                new_state["agent_gateway_ingress"] = dvars["AGW_URI"]
            elif "egress" in demo_dir.name:
                new_state["agent_gateway_egress"] = dvars["AGW_URI"]
        if mcp_url:
            new_state["mcp_url"] = mcp_url
        if dvars.get("MCP_INVOKER_SA"):
            new_state["mcp_invoker_sa"] = dvars["MCP_INVOKER_SA"]
        if a2a_card_url:
            new_state["a2a_card_url"] = a2a_card_url
        if dvars.get("BQ_DATASET"):
            new_state["bq_dataset"] = dvars["BQ_DATASET"]
        if dvars.get("BQ_TABLE"):
            new_state["bq_table"] = dvars["BQ_TABLE"]
        if dvars.get("TELEMETRY_BUCKET"):
            new_state["telemetry_bucket"] = dvars["TELEMETRY_BUCKET"]

        state_file.write_text(json.dumps(new_state, indent=2) + "\n", encoding="utf-8")

    # Montar demos/<NN>/.env completo (raiz + específicos da demo, porque o ADK para no 1º .env)
    demo_lines = list(root_lines) + [
        "",
        f"# --- Recursos Específicos: {demo_dir.name} ---",
    ]
    if engine_id:
        demo_lines.append(f"GOOGLE_CLOUD_AGENT_ENGINE_ID={engine_id}")
        demo_lines.append(f"REASONING_ENGINE_NAME={engine_name}")
    for k in [
        "PREFIX",
        "RE_DISPLAY_NAME",
        "AGW_URI",
        "DATA_BUCKET",
        "STAGING_BUCKET",
        "TELEMETRY_BUCKET",
        "MCP_INVOKER_SA",
        "CR_INVOKER_SA",
        "BQ_DATASET",
        "BQ_TABLE",
        "BQ_TRACES_LINKED_DATASET",
        "APPHUB_APP_ID",
    ]:
        if dvars.get(k):
            demo_lines.append(f"{k}={dvars[k]}")

    if mcp_url:
        demo_lines.append(f"MCP_URL={mcp_url}")
    if a2a_card_url:
        demo_lines.append(f"A2A_AGENT_CARD_URL={a2a_card_url}")

    if dvars.get("TELEMETRY_BUCKET"):
        demo_lines.extend([
            "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=NO_CONTENT",
            "OTEL_INSTRUMENTATION_GENAI_COMPLETION_HOOK=upload",
            "OTEL_INSTRUMENTATION_GENAI_UPLOAD_FORMAT=jsonl",
            f"OTEL_INSTRUMENTATION_GENAI_UPLOAD_BASE_PATH=gs://{dvars['TELEMETRY_BUCKET']}/completions",
        ])
    else:
        demo_lines.append("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true")

    demo_env_path = demo_dir / ".env"
    demo_env_path.write_text("\n".join(demo_lines) + "\n", encoding="utf-8")
    (demo_dir / ".envrc").write_text("dotenv .env\n", encoding="utf-8")
    status_id = f"Engine ID={engine_id}" if engine_id else "sem Engine ativo (InMemory)"
    print(f"  ✔ {demo_dir.name}/.env gerado ({status_id})")
PY

echo "=============================================================================="
echo "🎉 Pronto! Ambiente local sincronizado em /.env e demos/*/.env."
echo "   • Para ADK CLI: rode 'adk web demos/03-geap-otel-topology-analytics/src' direto"
echo "   • Para direnv (opcional): rode 'direnv allow' na raiz"
echo "   • Para Agent Console: rode './tools/agent-console/start.sh'"
echo "=============================================================================="
