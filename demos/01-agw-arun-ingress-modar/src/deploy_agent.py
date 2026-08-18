#!/usr/bin/env python3
"""Deploy an ADK agent to Vertex AI Agent Runtime (Reasoning Engine) with Agent Gateway Ingress."""

import argparse
import importlib
import json
import logging
import os
import shutil
import stat
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description="Deploy ADK Agent to Vertex AI Reasoning Engine")
    parser.add_argument("--project", default=os.getenv("PROJECT_ID"), required=not os.getenv("PROJECT_ID"), help="GCP Project ID")
    parser.add_argument("--region", default=os.getenv("REGION", "us-central1"), help="GCP Region")
    parser.add_argument("--agent-location", default=os.getenv("AGENT_LOCATION", "global"), help="Vertex AI Agent Location")
    parser.add_argument("--staging-bucket", default=os.getenv("STAGING_BUCKET"), help="GCS Staging Bucket")
    parser.add_argument("--data-bucket", default=os.getenv("DATA_BUCKET"), help="GCS Customer Data Bucket")
    parser.add_argument("--model-name", default=os.getenv("MODEL_NAME", "gemini-flash-latest"), help="Gemini Model Name")
    parser.add_argument("--agent-gateway-ingress", default=os.getenv("AGW_URI"), help="Agent Gateway Resource URI")
    parser.add_argument("--enable-agent-identity", action="store_true", default=True, help="Enable SPIFFE Agent Identity")
    parser.add_argument("--enable-telemetry", action="store_true", default=True, help="Enable OpenTelemetry")
    parser.add_argument("--allow-token-sharing", action="store_true", default=True, help="Allow token sharing for GCP services")
    parser.add_argument("--display-name", default="agent-crm", help="Display Name")
    parser.add_argument("--description", default="Agente CRM de consulta a clientes com governança Agent Gateway", help="Description")
    parser.add_argument("--src-dir", default=os.path.dirname(os.path.abspath(__file__)), help="Source directory containing agent package")
    parser.add_argument("--output-json", default=None, help="Path to write JSON metadata containing engine details")

    args = parser.parse_args()

    print(f"🚀 Initializing Vertex AI client for project '{args.project}' in region '{args.region}'...")
    import vertexai
    from vertexai.preview import reasoning_engines

    vertexai.init(project=args.project, location=args.region, staging_bucket=f"gs://{args.staging_bucket}")
    client = vertexai.Client(project=args.project, location=args.region)

    # Set environment variables for local agent load
    if args.data_bucket:
        os.environ["DATA_BUCKET"] = args.data_bucket
    if args.model_name:
        os.environ["MODEL_NAME"] = args.model_name

    # Import ADK App and Root Agent
    sys.path.insert(0, args.src_dir)
    try:
        from google.adk.agent_engines import AdkApp
    except ImportError:
        try:
            from vertexai.agent_engines import AdkApp
        except ImportError:
            raise RuntimeError("Não foi possível importar AdkApp. Instale google-cloud-aiplatform[adk,agent_engines].")

    # Set environment variables for local agent instantiation
    os.environ["GOOGLE_CLOUD_PROJECT"] = args.project
    os.environ["PROJECT_ID"] = args.project
    os.environ["DATA_BUCKET"] = args.data_bucket or ""
    os.environ["MODEL_NAME"] = args.model_name or "gemini-flash-latest"
    os.environ["MODEL_LOCATION"] = "global"
    os.environ["GOOGLE_CLOUD_LOCATION"] = "global"
    os.environ["VERTEX_AI_LOCATION"] = "global"

    agent_module = importlib.import_module("agent.agent")
    root_agent = getattr(agent_module, "root_agent")
    app = AdkApp(agent=root_agent)

    # Prepare staging directory
    original_cwd = os.getcwd()
    staging_dir = tempfile.mkdtemp(prefix="adk_stage_")

    try:
        # Copy agent package
        agent_src = os.path.join(args.src_dir, "agent")
        shutil.copytree(agent_src, os.path.join(staging_dir, "agent"))

        # Create installation script to satisfy reasoning engines venv structure
        install_dir = os.path.join(staging_dir, "installation_scripts")
        os.makedirs(install_dir, exist_ok=True)
        script_path = os.path.join(install_dir, "create_venv.sh")
        with open(script_path, "w") as f:
            f.write("#!/bin/bash\n")
            f.write("PYTHON3=$(which python3)\n")
            f.write("PY_VER=$($PYTHON3 -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")')\n")
            f.write("mkdir -p /code/.venv/lib/python${PY_VER}/site-packages\n")
            f.write('ln -sf "$PYTHON3" /code/.venv/bin/python\n')
            f.write('ln -sf "$PYTHON3" /code/.venv/bin/python3\n')
            f.write("cat > /code/.venv/pyvenv.cfg << PYCFG\n")
            f.write("home = $(dirname $PYTHON3)\n")
            f.write("include-system-site-packages = true\n")
            f.write("PYCFG\n")
        os.chmod(script_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)

        os.chdir(staging_dir)

        # Requirements
        requirements = [
            "google-cloud-aiplatform[adk,agent_engines]>=1.80.0",
            "google-cloud-storage>=2.14.0",
            "pydantic>=2.0.0",
            "cloudpickle>=3.0.0",
        ]

        # Build deploy configuration
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
                "DATA_BUCKET": args.data_bucket or "",
                "MODEL_NAME": args.model_name or "gemini-flash-latest",
            },
        }

        if args.enable_telemetry:
            deploy_config["env_vars"]["GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY"] = "true"
            deploy_config["env_vars"]["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "true"

        if args.enable_agent_identity:
            deploy_config["identity_type"] = "AGENT_IDENTITY"

        if args.allow_token_sharing:
            deploy_config["env_vars"]["GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES"] = "false"

        if args.agent_gateway_ingress:
            deploy_config["agent_gateway_config"] = {
                "client_to_agent_config": {
                    "agent_gateway": args.agent_gateway_ingress
                }
            }

        print(f"📦 Deploying agent '{args.display_name}' to Vertex AI Reasoning Engines...")
        print(f"🔗 Agent Gateway Ingress bound to: {args.agent_gateway_ingress}")

        engine = client.agent_engines.create(agent=app, config=deploy_config)

    finally:
        os.chdir(original_cwd)
        shutil.rmtree(staging_dir, ignore_errors=True)

    reasoning_engine_name = engine.api_resource.name
    engine_id = reasoning_engine_name.split("/")[-1]

    # Inspect SPIFFE identity if available
    agent_identity = None
    if hasattr(engine.api_resource, "identity") and engine.api_resource.identity:
        agent_identity = engine.api_resource.identity
    elif hasattr(engine.api_resource, "runtime_identity") and engine.api_resource.runtime_identity:
        agent_identity = engine.api_resource.runtime_identity

    print("\n" + "=" * 60)
    print(f"✅ SUCESSO: Agente deployado com sucesso!")
    print(f"   Resource Name: {reasoning_engine_name}")
    print(f"   Engine ID:     {engine_id}")
    if agent_identity:
        print(f"   Agent Identity: {agent_identity}")
    print("=" * 60 + "\n")

    result = {
        "reasoning_engine_name": reasoning_engine_name,
        "engine_id": engine_id,
        "agent_identity": agent_identity,
        "project": args.project,
        "region": args.region,
        "agent_gateway_ingress": args.agent_gateway_ingress,
    }

    if args.output_json:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)
        print(f"💾 Metadados salvos em: {args.output_json}")


if __name__ == "__main__":
    main()
