#!/usr/bin/env bash
# ==============================================================================
# Launcher for Agent Console & Wire Inspector
# Supports both standalone mode (127.0.0.1:8090) and Jetski Web UI Sidecar mode
# (via ANTIGRAVITY_SIDECAR_WEB_PORT).
# ==============================================================================

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOL_DIR}/../.." && pwd)"

export HOST="${HOST:-127.0.0.1}"
export PORT="${ANTIGRAVITY_SIDECAR_WEB_PORT:-${PORT:-8090}}"
export PYTHONUNBUFFERED=1

# Auto-detect argolis gcloud configuration if not set
if [[ -z "${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" ]]; then
    if gcloud config configurations describe argolis &>/dev/null; then
        export CLOUDSDK_ACTIVE_CONFIG_NAME="argolis"
    fi
fi

RELOAD_ARGS=()
if [[ "${AGENT_CONSOLE_NO_RELOAD:-0}" != "1" ]]; then
    RELOAD_ARGS=(--reload)
fi

# 1. Check if a local venv in tools/agent-console or demos/01-* already has fastapi+uvicorn+httpx
for candidate_py in \
    "${TOOL_DIR}/.venv/bin/python" \
    "${REPO_ROOT}/demos/01-agw-arun-ingress-modar/.venv/bin/python"; do
    if [[ -x "${candidate_py}" ]]; then
        if "${candidate_py}" -c "import fastapi, uvicorn, httpx" &>/dev/null; then
            exec "${candidate_py}" "${TOOL_DIR}/server.py" --host "${HOST}" --port "${PORT}" "${RELOAD_ARGS[@]}" "$@"
        fi
    fi
done

# 2. Fallback to `uv run` (uses PEP 723 inline dependencies in server.py)
if command -v uv &>/dev/null; then
    exec uv run "${TOOL_DIR}/server.py" --host "${HOST}" --port "${PORT}" "${RELOAD_ARGS[@]}" "$@"
fi

echo "❌ [ERRO] Não foi encontrado ambiente Python com fastapi/uvicorn/httpx nem o binário 'uv'." >&2
exit 1
