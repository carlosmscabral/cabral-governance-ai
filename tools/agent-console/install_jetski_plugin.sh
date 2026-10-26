#!/usr/bin/env bash
# ==============================================================================
# Installs / Syncs the Agent Console UI Plugin into ~/.gemini/config/plugins/
# ==============================================================================

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${HOME}/.gemini/config/plugins/agent_console"

mkdir -p "${PLUGIN_DIR}/assets" "${PLUGIN_DIR}/sidecars/inspector"

cat > "${PLUGIN_DIR}/plugin.json" <<EOF
{
  "name": "agent_console",
  "description": "Agent Console & Wire Inspector (Chat + Lightweight Postman) para simular canais e inspecionar chamadas HTTP/SSE, Tool Calls e vereditos do Model Armor / DLP nas demos do repositório cabral-governance-ai.",
  "logo": "assets/logo.svg",
  "suggestedPrompts": [
    "Abra o painel Agent Console & Wire Inspector para testar a Demo 01",
    "Verifique o status do Reasoning Engine e dos cenários da Demo 01",
    "Inspecione os logs do Model Armor após disparar os cenários no Agent Console"
  ]
}
EOF

cat > "${PLUGIN_DIR}/sidecars/inspector/sidecar.json" <<EOF
{
  "command": "${TOOL_DIR}/start.sh",
  "args": [],
  "restart_policy": "always",
  "has_web_ui": true,
  "ui_config": {
    "display_name": "Agent Console & Wire Inspector",
    "views": [
      {
        "path": "/",
        "entrypoint": "SIDECAR_UI_ENTRYPOINT_AUX_PANE",
        "title": "Agent Console"
      }
    ]
  }
}
EOF

echo "✅ Plugin Jetski Web instalado em: ${PLUGIN_DIR}"
