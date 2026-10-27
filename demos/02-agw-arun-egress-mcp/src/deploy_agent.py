#!/usr/bin/env python3
"""Deploy an ADK agent to Vertex AI Agent Runtime (Reasoning Engine) with Agent Gateway Egress (AGENT_TO_ANYWHERE)."""

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
    parser = argparse.ArgumentParser(description="Deploy ADK Agent to Vertex AI Reasoning Engine (Egress Governed)")
    parser.add_argument("--project", default=os.getenv("PROJECT_ID"), required=not os.getenv("PROJECT_ID"), help="GCP Project ID")
    parser.add_argument("--region", default=os.getenv("REGION", "us-central1"), help="GCP Region")
    parser.add_argument("--staging-bucket", default=os.getenv("STAGING_BUCKET"), required=not os.getenv("STAGING_BUCKET"), help="GCS Staging Bucket")
    parser.add_argument("--model-name", default=os.getenv("MODEL_NAME", "gemini-3.8-flash"), help="Gemini Model Name (global)")
    parser.add_argument("--mcp-url", default=os.getenv("MCP_URL"), required=not os.getenv("MCP_URL"), help="MCP Server Streamable HTTP URL")
    parser.add_argument("--mcp-invoker-sa", default=os.getenv("MCP_INVOKER_SA", ""), help="Service Account email for OIDC impersonation")
    parser.add_argument("--agent-gateway-egress", default=os.getenv("AGW_URI"), required=not os.getenv("AGW_URI"), help="Agent Gateway Resource URI (AGENT_TO_ANYWHERE)")
    parser.add_argument("--engine-id", default=None, help="Existing Reasoning Engine ID to update in-place")
    parser.add_argument("--enable-agent-identity", action="store_true", default=True, help="Enable SPIFFE Agent Identity")
    parser.add_argument("--enable-telemetry", action="store_true", default=True, help="Enable OpenTelemetry")
    parser.add_argument("--allow-token-sharing", action="store_true", default=True, help="Allow token sharing for GCP services")
    parser.add_argument("--display-name", default="agw-egress-agent-finops", help="Display Name")
    parser.add_argument("--description", default="Agente FinOps governado por Agent Gateway to Anywhere (Egress + MCP + IAP)", help="Description")
    parser.add_argument("--src-dir", default=os.path.dirname(os.path.abspath(__file__)), help="Source directory containing agent package")
    parser.add_argument("--output-json", default=None, help="Path to write JSON metadata containing engine details")

    args = parser.parse_args()

    print(f"🚀 Inicializando cliente Vertex AI para o projeto '{args.project}' na região '{args.region}'...")
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

    os.environ["GOOGLE_CLOUD_PROJECT"] = args.project
    os.environ["PROJECT_ID"] = args.project
    os.environ["MODEL_NAME"] = args.model_name or "gemini-3.8-flash"
    os.environ["MODEL_LOCATION"] = "global"
    os.environ["GOOGLE_CLOUD_LOCATION"] = "global"
    os.environ["VERTEX_AI_LOCATION"] = "global"
    os.environ["MCP_URL"] = args.mcp_url
    os.environ["MCP_INVOKER_SA"] = args.mcp_invoker_sa or ""
    os.environ["ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING"] = "1"

    sys.path.insert(0, args.src_dir)
    try:
        from google.adk.agent_engines import AdkApp
    except ImportError:
        try:
            from vertexai.agent_engines import AdkApp
        except ImportError:
            raise RuntimeError("Não foi possível importar AdkApp. Instale google-cloud-aiplatform[adk,agent_engines].")

    agent_module = importlib.import_module("agent.agent")
    root_agent = getattr(agent_module, "root_agent")
    app = AdkApp(agent=root_agent)

    original_cwd = os.getcwd()
    staging_dir = tempfile.mkdtemp(prefix="adk_egress_stage_")

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
            f.write("PY_VER=$($PYTHON3 -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")')\n")
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

        requirements = [
            "google-cloud-aiplatform[adk,agent_engines]>=1.80.0",
            "google-auth>=2.35.0",
            "mcp>=1.26.0,<2.0.0",
            "httpx>=0.28.0",
            "pydantic>=2.0.0",
            "cloudpickle>=3.0.0",
        ]

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
            "env_vars": {
                "PROJECT_ID": args.project,
                "GOOGLE_GENAI_USE_VERTEXAI": "True",
                "GOOGLE_CLOUD_LOCATION": "global",
                "VERTEX_AI_LOCATION": "global",
                "MODEL_LOCATION": "global",
                "MODEL_NAME": args.model_name or "gemini-3.8-flash",
                "MCP_URL": args.mcp_url,
                "MCP_INVOKER_SA": args.mcp_invoker_sa or "",
                "ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING": "1",
                "GOOGLE_API_USE_CLIENT_CERTIFICATE": "false",
                "GOOGLE_API_USE_MTLS_ENDPOINT": "never",
            },
        }

        if args.enable_telemetry:
            deploy_config["env_vars"]["GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY"] = "true"
            deploy_config["env_vars"]["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "true"

        if args.enable_agent_identity:
            deploy_config["identity_type"] = "AGENT_IDENTITY"

        if args.allow_token_sharing:
            deploy_config["env_vars"]["GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES"] = "false"

        if args.agent_gateway_egress:
            deploy_config["agent_gateway_config"] = {
                "agent_to_anywhere_config": {
                    "agent_gateway": args.agent_gateway_egress
                }
            }

        if args.engine_id:
            engine_resource_name = f"projects/{args.project}/locations/{args.region}/reasoningEngines/{args.engine_id}"
            print(f"🔄 Atualizando Reasoning Engine existente '{engine_resource_name}' com modelo '{args.model_name}' (global)...")
            update_config = {
                "display_name": args.display_name,
                "description": args.description,
                "staging_bucket": f"gs://{args.staging_bucket}",
                "requirements": requirements,
                "extra_packages": deploy_config["extra_packages"],
                "env_vars": deploy_config["env_vars"],
            }
            try:
                engine = client.agent_engines.update(
                    name=engine_resource_name,
                    agent=app,
                    config=update_config,
                )
            except Exception as exc:
                print(f"⚠️ Atualização in-place falhou ({exc}); recriando Reasoning Engine...")
                try:
                    client.agent_engines.delete(name=engine_resource_name, force=True)
                except Exception:
                    pass
                engine = client.agent_engines.create(agent=app, config=deploy_config)
        else:
            print(f"📦 Realizando deploy do agente '{args.display_name}' no Vertex AI Reasoning Engine...")
            print(f"🔗 Agent Gateway Egress (AGENT_TO_ANYWHERE): {args.agent_gateway_egress}")
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

    print("\n" + "=" * 60)
    print("✅ SUCESSO: Agente FinOps (Egress Governado) implantado!")
    print(f"   Resource Name: {reasoning_engine_name}")
    print(f"   Engine ID:     {engine_id}")
    if agent_identity:
        print(f"   Agent Identity: {agent_identity}")
    print("=" * 60 + "\n")

    result = {
        "reasoning_engine_name": reasoning_engine_name,
        "engine_id": engine_id,
        "agent_identity": str(agent_identity) if agent_identity else None,
        "project": args.project,
        "region": args.region,
        "mcp_url": args.mcp_url,
        "agent_gateway_egress": args.agent_gateway_egress,
    }

    if args.output_json:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)
        print(f"💾 Metadados salvos em: {args.output_json}")


if __name__ == "__main__":
    main()
