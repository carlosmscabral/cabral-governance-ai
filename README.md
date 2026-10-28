# Agent Platform Governance Demos

A monorepo containing self-contained, automated demos showcasing **Agent Platform Governance**, security, guardrails, compliance, and observability on Google Cloud Platform (GCP).

---

## 🎯 Purpose & Philosophy

Every directory in this repository represents an isolated, reproducible scenario illustrating practical AI governance patterns for agentic systems.

Each demo follows a strict self-containment contract:
* **Self-Contained**: Contains all necessary agent code, configuration, and infrastructure definitions.
* **Automated Lifecycle**: Includes single-command deployment (`deploy.sh`) and clean teardown (`undeploy.sh`).
* **Zero Residuals**: Tearing down a demo deletes all provisioned resources to avoid lingering costs and project clutter.
* **Documented Scenario**: Features its own `README.md` with architectural diagrams, user journeys, and test assertions.

---

## 📁 Repository Structure

```text
cabral-governance-ai/
├── AGENTS.md                   # Engineering rules, testing contract & weekly self-healing CI spec
├── LICENSE                     # Apache 2.0 License
├── README.md                   # Repository overview and demo directory
├── .gitignore                  # Global ignore rules (credentials, state, build artifacts)
├── scripts/
│   └── ci_healthcheck.sh       # Automated healthcheck, SDK upgrade & drift detector across all demos
├── tools/
│   └── agent-console/          # Local Web UI & Jetski Plugin ("Chat + Lightweight Postman")
│       ├── README.md           # Tool documentation & wire inspection guide
│       ├── start.sh            # Standalone (:8090) & Jetski Sidecar launcher
│       ├── install_jetski_plugin.sh # Installs native Jetski Web UI Plugin AuxPane
│       ├── server.py           # FastAPI streaming proxy, gcloud auth cache & session API
│       └── static/             # Zero-build split-view frontend (HTML/CSS/JS)
│
└── demos/                      # Individual governance demos
    ├── 01-agw-arun-ingress-modar/         # Agent Gateway Ingress + Model Armor + Cloud DLP
    ├── 02-agw-arun-egress-mcp/            # Agent Gateway to Anywhere (Egress) + Agent Registry + IAP CEL MCP
    └── 03-geap-otel-topology-analytics/   # Multi-Agent OTel (MCP + A2A), Live Topology & BigQuery Analytics
        ├── README.md           # Scenario documentation & walkthrough
        ├── VISUAL_GUIDE.md     # Progressive C4 diagrams, sequence walks & wire formats
        ├── DEMO_GUIDE.md       # Live customer presentation script (4 acts) & FAQ
        ├── scenarios.json      # Playbook manifest for Agent Console & Wire Inspector
        ├── env.sh              # Standard environment (cabral-governance-ai + gemini-3.8-flash @ global)
        ├── deploy.sh           # Idempotent deployment script
        ├── test.sh             # Automated PT-BR end-to-end test suite
        ├── undeploy.sh         # Zero-residuals teardown script
        ├── scripts/            # Modular provisioning steps (01..03)
        └── src/                # ADK Orchestrator + Cloud Run A2A Specialist + Cloud Run FastMCP
```

---

## 🛠️ Demo Directory Convention

When adding a new demo under `demos/<demo-name>`, adhere to the contract defined in [`AGENTS.md`](./AGENTS.md):

| File / Directory | Description |
| :--- | :--- |
| `README.md` | Problem statement, architecture diagram, prerequisites, and step-by-step demo steps. |
| `VISUAL_GUIDE.md` | Progressive architecture diagrams, sequence walks, wire formats, and annotated code. |
| `DEMO_GUIDE.md` | Presenter playbook with 60s pitch, live demo acts, cURL commands, and customer FAQ. |
| `scenarios.json` | Demo Playbook manifest (personas, acts, prompts, and presenter notes) auto-loaded by `tools/agent-console/`. |
| `env.sh` | Standard environment variables (`PROJECT_ID=cabral-governance-ai`, `MODEL_NAME=gemini-3.8-flash` on `global`). |
| `deploy.sh` | Idempotent bash script to configure GCP services, deploy agents/policies, and output test endpoints. |
| `test.sh` | Non-interactive PT-BR test suite verifying positive business queries, active guardrails, and audit logs. |
| `undeploy.sh` | Safe cleanup script that tears down all provisioned resources and IAM bindings. |
| `src/` | Agent definitions, tools, evaluation sets, or policy engines. |

---

## 🚀 General Prerequisites

Before deploying any demo:

1. **Google Cloud SDK (`gcloud`)**: Installed and authenticated.
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```
2. **GCP Project**: Set an active project with billing enabled.
   ```bash
   gcloud config set project <YOUR_PROJECT_ID>
   ```
3. **Required Tools**: `bash`, `jq`, `curl`, and optionally `terraform` depending on the demo.

---

## 🖥️ Interactive Demo UI: Agent Console & Wire Inspector

Instead of relying solely on terminal `curl` commands during customer presentations, use the built-in **Agent Console & Wire Inspector** ([`tools/agent-console/`](tools/agent-console)):

### Option A: Native Jetski Web UI Plugin (Cloudtop Auxiliary Pane)
```bash
./tools/agent-console/install_jetski_plugin.sh
```
Click the **🛡️ Agent Console & Wire Inspector** icon in the right-hand sidebar of Jetski Web to open the interactive split-pane directly inside your workspace.

### Option B: Standalone Local Server (`http://127.0.0.1:8090`)
```bash
./tools/agent-console/start.sh
```

Key capabilities:
* **Auto-Discovered Demo Playbooks**: One-click scenario buttons (`scenarios.json`) and automatic `.state/agent_info.json` endpoint discovery.
* **Resizable Split-View & Live Wire Inspector ("Lightweight Postman")**: Draggable central divider (`70/30`, `50/50`, `30/70` presets) with real-time inspection of Request Headers, JSON Payloads, Response Latency (`TTFT` + `Total ms`), ADK Tool Calls (`function_call`/`function_response`), SSE Chunk Timelines, and Governance Verdict banners (`ALLOW`, `DLP REDACT`, `MODEL ARMOR INGRESS/EGRESS BLOCK`, `AGW EGRESS L7 MCP BLOCK`, plus streaming leak warnings).
* **Distributed W3C `traceparent` Injection & 1-Click Cloud Trace**: Automatically stamps outgoing requests with a deterministic W3C `traceparent` header and renders a **🔗 Cloud Trace** deep-link pill in the Wire Inspector to inspect multi-agent waterfalls (Reasoning Engine + Cloud Run A2A + Cloud Run MCP) in one click.
* **Server-Side Session Lifecycle (`+ Nova Sessão` / `🔄 Zerar Sessão`)**: Creates and deletes persistent sessions on `VertexAiSessionService` via `:query` (`create_session` / `delete_session`) or switches to stateless/ephemeral mode.
* **Two-Layer Auth & 3LO Readiness**: Automatic `gcloud` token caching (`argolis`) plus delegated user identity headers (`X-Forwarded-Authorization`) and local `/oauth/callback` receiver.

---

## 📜 Demos Catalog

| Demo | Focus Area | Status | Description |
| :--- | :--- | :--- | :--- |
| [`01-agw-arun-ingress-modar`](demos/01-agw-arun-ingress-modar) | *Ingress Governance & Guardrails* | 🟢 Ready | Agent Gateway Ingress (`CLIENT_TO_AGENT`) com Vertex AI Reasoning Engine, Model Armor e Cloud DLP para mitigação de prompt injection e redação de PII/SSN. |
| [`02-agw-arun-egress-mcp`](demos/02-agw-arun-egress-mcp) | *Egress Governance & Zero-Trust MCP* | 🟢 Ready | Agent Gateway to Anywhere (`AGENT_TO_ANYWHERE`) sem VPC/PSC-I, com Agent Registry, identidade SPIFFE + OIDC no Cloud Run e IAP CEL L7 (`isReadOnly == true`) bloqueando tools MCP destrutivas e exfiltração para domínios não registrados. |
| [`03-geap-otel-topology-analytics`](demos/03-geap-otel-topology-analytics) | *Multi-Agent OTel, Live Topology & FinOps Analytics* | 🟢 Ready | Costura OpenTelemetry (`W3C traceparent`) em 3 runtimes (Reasoning Engine + Cloud Run A2A `--functional-type=agent` + Cloud Run FastMCP `--functional-type=mcp-server`), topologia viva auto-descoberta e BigQuery Agent Analytics em tempo real (`MCP` vs `A2A`, tokens e offload `.jsonl` no GCS). |


---

## 📄 License

This repository is licensed under the [Apache 2.0 License](./LICENSE).
