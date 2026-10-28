#!/usr/bin/env python3
"""Deploy the Demo 03 Multi-Agent Orchestrator to Vertex AI Reasoning Engine.

Configures:
- `AdkApp(agent=root_agent, plugins=agent_plugins)` with `BigQueryAgentAnalyticsPlugin`
- `identity_type="AGENT_IDENTITY"` (SPIFFE workload identity)
- 2026 OpenTelemetry Semantic Conventions (`gen_ai_latest_experimental`) + GCS JSONL Completion
  Hook (`gs://<TELEMETRY_BUCKET>/completions`) avoiding b/513070561 (`NO_CONTENT` span mode)
- Automatic drift detection and in-place `client.agent_engines.update(...)`
"""

import argparse
import importlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(
        description="Deploy Demo 03 Multi-Agent OTel & BQ Analytics Orchestrator to Reasoning Engine"
    )
    parser.add_argument(
        "--project",
        default=os.getenv("PROJECT_ID"),
        required=not os.getenv("PROJECT_ID"),
        help="GCP Project ID",
    )
    parser.add_argument("--region", default=os.getenv("REGION", "us-central1"), help="GCP Region")
    parser.add_argument(
        "--staging-bucket",
        default=os.getenv("STAGING_BUCKET"),
        required=not os.getenv("STAGING_BUCKET"),
        help="GCS Staging Bucket",
    )
    parser.add_argument(
        "--telemetry-bucket",
        default=os.getenv("TELEMETRY_BUCKET"),
        required=not os.getenv("TELEMETRY_BUCKET"),
        help="GCS Telemetry Bucket for OTel JSONL Completions & BQ Offload",
    )
    parser.add_argument(
        "--model-name",
        default=os.getenv("MODEL_NAME", "gemini-3.8-flash"),
        help="Gemini Model Name (global)",
    )
    parser.add_argument(
        "--mcp-url",
        default=os.getenv("MCP_URL"),
        required=not os.getenv("MCP_URL"),
        help="Cloud Run FastMCP Streamable HTTP URL",
    )
    parser.add_argument(
        "--a2a-card-url",
        default=os.getenv("A2A_AGENT_CARD_URL"),
        required=not os.getenv("A2A_AGENT_CARD_URL"),
        help="Cloud Run Specialist A2A Agent Card URL",
    )
    parser.add_argument(
        "--cr-invoker-sa",
        default=os.getenv("CR_INVOKER_SA", ""),
        help="Service Account email impersonated for Cloud Run OIDC authentication",
    )
    parser.add_argument(
        "--bq-dataset",
        default=os.getenv("BQ_DATASET", "geap_o11y_demo03"),
        help="BigQuery Dataset for BigQueryAgentAnalyticsPlugin",
    )
    parser.add_argument(
        "--bq-table",
        default=os.getenv("BQ_TABLE", "agent_events"),
        help="BigQuery Table for BigQueryAgentAnalyticsPlugin",
    )
    parser.add_argument("--engine-id", default=None, help="Existing Reasoning Engine ID to update in-place")
    parser.add_argument(
        "--display-name",
        default=os.getenv("RE_DISPLAY_NAME", "o11y-agent-orchestrator"),
        help="Reasoning Engine Display Name",
    )
    parser.add_argument(
        "--description",
        default=(
            "Orquestrador ADK Multi-Agente (MCP + A2A) com OpenTelemetry Distribuído, "
            "Topologia Viva e BigQuery Agent Analytics em Tempo Real"
        ),
        help="Reasoning Engine Description",
    )
    parser.add_argument(
        "--src-dir",
        default=os.path.dirname(os.path.abspath(__file__)),
        help="Source directory containing agent package",
    )
    parser.add_argument(
        "--output-json",
        default=None,
        help="Path to write JSON metadata containing engine details",
    )

    args = parser.parse_args()

    print(
        f"🚀 Inicializando cliente Vertex AI para o projeto '{args.project}' na região '{args.region}'..."
    )
    import google.oauth2.credentials
    import vertexai

    creds = None
    try:
        token = subprocess.run(
            ["gcloud", "auth", "print-access-token"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        if token:
            creds = google.oauth2.credentials.Credentials(token=token)
    except Exception:
        pass

    vertexai.init(
        project=args.project,
        location=args.region,
        staging_bucket=f"gs://{args.staging_bucket}",
        credentials=creds,
    )
    client = vertexai.Client(
        project=args.project,
        location=args.region,
        credentials=creds,
        http_options=dict(api_version="v1beta1"),
    )

    # Set environment prior to importing `agent.agent` so pickled defaults match runtime
    os.environ["GOOGLE_CLOUD_PROJECT"] = args.project
    os.environ["PROJECT_ID"] = args.project
    os.environ["MODEL_NAME"] = args.model_name or "gemini-3.8-flash"
    os.environ["MODEL_LOCATION"] = "global"
    os.environ["GOOGLE_CLOUD_LOCATION"] = "global"
    os.environ["VERTEX_AI_LOCATION"] = "global"
    os.environ["MCP_URL"] = args.mcp_url
    os.environ["A2A_AGENT_CARD_URL"] = args.a2a_card_url
    os.environ["CR_INVOKER_SA"] = args.cr_invoker_sa or ""
    os.environ["BQ_DATASET"] = args.bq_dataset
    os.environ["BQ_TABLE"] = args.bq_table
    os.environ["TELEMETRY_BUCKET"] = args.telemetry_bucket
    os.environ["ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING"] = "1"

    sys.path.insert(0, args.src_dir)
    try:
        from vertexai.agent_engines import AdkApp
    except ImportError:
        try:
            from google.adk.agent_engines import AdkApp
        except ImportError as exc:
            raise RuntimeError(
                "Não foi possível importar AdkApp. Instale google-cloud-aiplatform[adk,agent_engines]."
            ) from exc

    agent_module = importlib.import_module("agent.agent")
    root_agent = getattr(agent_module, "root_agent")
    agent_plugins = getattr(agent_module, "agent_plugins", None)

    # Omit `enable_tracing` so Reasoning Engine honors `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true`
    # and keeps `ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false` cleanly without deprecation warnings.
    app = AdkApp(agent=root_agent, plugins=agent_plugins)

    original_cwd = os.getcwd()
    staging_dir = tempfile.mkdtemp(prefix="adk_o11y_stage_")

    try:
        agent_src = os.path.join(args.src_dir, "agent")
        shutil.copytree(
            agent_src,
            os.path.join(staging_dir, "agent"),
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )

        install_dir = os.path.join(staging_dir, "installation_scripts")
        os.makedirs(install_dir, exist_ok=True)
        script_path = os.path.join(install_dir, "create_venv.sh")
        with open(script_path, "w") as f:
            f.write("#!/bin/bash\n")
            f.write("set -e\n")
            f.write("PYTHON3=$(which python3)\n")
            f.write(
                'PY_VER=$($PYTHON3 -c \'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")\')\n'
            )
            f.write("mkdir -p /code/.venv/bin\n")
            f.write("mkdir -p /code/.venv/lib/python${PY_VER}/site-packages\n")
            f.write('ln -sf "$PYTHON3" /code/.venv/bin/python\n')
            f.write('ln -sf "$PYTHON3" /code/.venv/bin/python3\n')
            f.write("cat > /code/.venv/pyvenv.cfg << PYCFG\n")
            f.write("home = $(dirname $PYTHON3)\n")
            f.write("include-system-site-packages = true\n")
            f.write("PYCFG\n")
        os.chmod(script_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)

        os.chdir(staging_dir)

        import importlib.metadata as pkg_meta

        def _pinned_or_min(pkg_name: str, extras: str, fallback_spec: str) -> str:
            try:
                ver = pkg_meta.version(pkg_name)
                return f"{pkg_name}{extras}=={ver}"
            except Exception:
                return fallback_spec

        # Pin exact `.venv` versions for cloudpickle-serialized packages so Reasoning Engine's
        # pre-baked system site-packages (`include-system-site-packages = true`) never shadow
        # or under-resolve newer classes like `google.adk.a2a.agent._remote_a2a_agent`.
        requirements = [
            _pinned_or_min(
                "google-cloud-aiplatform",
                "[adk,agent_engines]",
                "google-cloud-aiplatform[adk,agent_engines]>=2.0.0",
            ),
            _pinned_or_min(
                "google-adk",
                "[bigquery-analytics,a2a]",
                "google-adk[bigquery-analytics,a2a]>=2.12.0",
            ),
            _pinned_or_min("a2a-sdk", "", "a2a-sdk>=1.2.0"),
            _pinned_or_min("mcp", "", "mcp>=1.26.0,<2.0.0"),
            _pinned_or_min(
                "opentelemetry-exporter-otlp-proto-http",
                "",
                "opentelemetry-exporter-otlp-proto-http>=1.37.0",
            ),
            "google-cloud-bigquery>=3.25.0",
            "google-cloud-bigquery-storage>=2.26.0",
            "google-cloud-storage>=2.14.0",
            "fsspec[gcs]>=2024.6.0",
            "gcsfs>=2024.6.0",
            "google-auth>=2.35.0",
            "httpx>=0.28.0",
            "opentelemetry-instrumentation-httpx>=0.48b0",
            "opentelemetry-instrumentation-google-genai>=0.4b0",
            "pydantic>=2.0.0",
            "cloudpickle>=3.0.0",
        ]

        env_vars = {
            "PROJECT_ID": args.project,
            "GOOGLE_GENAI_USE_VERTEXAI": "True",
            "GOOGLE_CLOUD_LOCATION": "global",
            "VERTEX_AI_LOCATION": "global",
            "MODEL_LOCATION": "global",
            "MODEL_NAME": args.model_name or "gemini-3.8-flash",
            "MCP_URL": args.mcp_url,
            "A2A_AGENT_CARD_URL": args.a2a_card_url,
            "CR_INVOKER_SA": args.cr_invoker_sa or "",
            "BQ_DATASET": args.bq_dataset,
            "BQ_TABLE": args.bq_table,
            "TELEMETRY_BUCKET": args.telemetry_bucket,
            "ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING": "1",
            # Golden 2026 GEAP OTel + GCS JSONL Offload Settings (avoids b/513070561)
            "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY": "true",
            "OTEL_SEMCONV_STABILITY_OPT_IN": "gen_ai_latest_experimental",
            "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "NO_CONTENT",
            "OTEL_INSTRUMENTATION_GENAI_COMPLETION_HOOK": "upload",
            "OTEL_INSTRUMENTATION_GENAI_UPLOAD_FORMAT": "jsonl",
            "OTEL_INSTRUMENTATION_GENAI_UPLOAD_BASE_PATH": (
                f"gs://{args.telemetry_bucket}/completions"
            ),
            "ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS": "false",
            "OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED": "true",
            # SPIFFE Agent Identity token sharing for telemetry.googleapis.com & BigQuery
            "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES": "false",
            "GOOGLE_API_USE_CLIENT_CERTIFICATE": "false",
            "GOOGLE_API_USE_MTLS_ENDPOINT": "never",
        }

        deploy_config = {
            "display_name": args.display_name,
            "description": args.description,
            "staging_bucket": f"gs://{args.staging_bucket}",
            "requirements": requirements,
            "extra_packages": [
                "agent",
                "installation_scripts/create_venv.sh",
            ],
            "build_options": {
                "installation_scripts": [
                    "installation_scripts/create_venv.sh",
                ],
            },
            "env_vars": env_vars,
            "identity_type": "AGENT_IDENTITY",
        }

        if args.engine_id:
            engine_resource_name = (
                f"projects/{args.project}/locations/{args.region}/reasoningEngines/{args.engine_id}"
            )
            print(
                f"🔄 Atualizando Reasoning Engine existente '{engine_resource_name}' "
                f"com modelo '{args.model_name}' (global)..."
            )
            update_config = {
                "display_name": args.display_name,
                "description": args.description,
                "staging_bucket": f"gs://{args.staging_bucket}",
                "requirements": requirements,
                "extra_packages": deploy_config["extra_packages"],
                "env_vars": env_vars,
            }
            try:
                engine = client.agent_engines.update(
                    name=engine_resource_name,
                    agent=app,
                    config=update_config,
                )
            except Exception as exc:
                print(
                    f"⚠️ Atualização in-place falhou ({exc}); recriando Reasoning Engine..."
                )
                try:
                    client.agent_engines.delete(name=engine_resource_name, force=True)
                except Exception:
                    pass
                engine = client.agent_engines.create(agent=app, config=deploy_config)
        else:
            print(
                f"📦 Realizando deploy do orquestrador '{args.display_name}' no Vertex AI Reasoning Engine..."
            )
            engine = client.agent_engines.create(agent=app, config=deploy_config)

    finally:
        os.chdir(original_cwd)
        shutil.rmtree(staging_dir, ignore_errors=True)

    reasoning_engine_name = engine.api_resource.name
    engine_id = reasoning_engine_name.split("/")[-1]

    agent_identity = None
    for attr in ("effective_identity", "identity", "runtime_identity"):
        val = getattr(engine.api_resource, attr, None)
        if val:
            agent_identity = val
            break
    if not agent_identity:
        spec = getattr(engine.api_resource, "spec", None)
        if spec:
            agent_identity = getattr(spec, "effective_identity", None)

    print("\n" + "=" * 68)
    print("✅ SUCESSO: Agente Orquestrador (OTel + Topologia + BQ Analytics) implantado!")
    print(f"   Resource Name:  {reasoning_engine_name}")
    print(f"   Engine ID:      {engine_id}")
    if agent_identity:
        print(f"   Agent Identity: {agent_identity}")
    print("=" * 68 + "\n")

    result = {
        "reasoning_engine_name": reasoning_engine_name,
        "engine_id": engine_id,
        "agent_identity": str(agent_identity) if agent_identity else None,
        "project": args.project,
        "region": args.region,
        "mcp_url": args.mcp_url,
        "a2a_card_url": args.a2a_card_url,
        "bq_dataset": args.bq_dataset,
        "bq_table": args.bq_table,
        "telemetry_bucket": args.telemetry_bucket,
    }

    if args.output_json:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)
        print(f"💾 Metadados salvos em: {args.output_json}")


if __name__ == "__main__":
    main()
