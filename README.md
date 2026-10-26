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
│
└── demos/                      # Individual governance demos
    ├── 01-agw-arun-ingress-modar/
    │   ├── README.md           # Scenario documentation & walkthrough
    │   ├── VISUAL_GUIDE.md     # Progressive C4 diagrams, sequence walks & wire formats
    │   ├── DEMO_GUIDE.md       # Live customer presentation script (4 acts) & FAQ
    │   ├── env.sh              # Standard environment (cabral-governance-ai + gemini-3.8-flash @ global)
    │   ├── deploy.sh           # Idempotent deployment script
    │   ├── test.sh             # Automated PT-BR end-to-end test suite
    │   ├── undeploy.sh         # Zero-residuals teardown script
    │   ├── cfg/                # Gateway, Service Extension & Authz Policy templates
    │   ├── scripts/            # Modular provisioning steps (01..05)
    │   └── src/                # ADK agent source code and CRM datasets
    └── ...
```

---

## 🛠️ Demo Directory Convention

When adding a new demo under `demos/<demo-name>`, adhere to the contract defined in [`AGENTS.md`](./AGENTS.md):

| File / Directory | Description |
| :--- | :--- |
| `README.md` | Problem statement, architecture diagram, prerequisites, and step-by-step demo steps. |
| `VISUAL_GUIDE.md` | Progressive architecture diagrams, sequence walks, wire formats, and annotated code. |
| `DEMO_GUIDE.md` | Presenter playbook with 60s pitch, live demo acts, cURL commands, and customer FAQ. |
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

## 📜 Demos Catalog

| Demo | Focus Area | Status | Description |
| :--- | :--- | :--- | :--- |
| [`01-agw-arun-ingress-modar`](demos/01-agw-arun-ingress-modar) | *Ingress Governance & Guardrails* | 🟢 Ready | Agent Gateway Ingress (`CLIENT_TO_AGENT`) com Vertex AI Reasoning Engine, Model Armor e Cloud DLP para mitigação de prompt injection e redação de PII/SSN. |
| *02-agw-arun-egress-sgp* | *Egress Governance & Semantic Policies* | 📋 Planned | Agent Gateway Egress (`AGENT_TO_ANYWHERE`) com Semantic Governance Policies (SGP), Agent Registry e controle granular de chamadas MCP. |
| *03-agent-observability-trace* | *Observability & Auditability* | 📋 Planned | Cloud Trace, BigQuery Agent Analytics, telemetria OpenTelemetry e auditoria de decisões de sanitização. |


---

## 📄 License

This repository is licensed under the [Apache 2.0 License](./LICENSE).
