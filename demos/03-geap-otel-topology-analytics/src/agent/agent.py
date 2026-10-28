"""Multi-Agent Operations & FinOps Orchestrator (Demo 03 — Node 1 on Vertex AI Reasoning Engine).

Demonstrates the complete 2026 Gemini Enterprise Agent Platform (GEAP) Observability stack:
1. Distributed OpenTelemetry W3C `traceparent` stitching across 3 independent runtimes:
   - Node 1: Orchestrator ADK Agent on Vertex AI Reasoning Engine (`AGENT_IDENTITY`)
   - Node 2: Specialist A2A Agent on Cloud Run (`--functional-type=agent`, `RemoteA2aAgent` wrapped in `AgentTool`)
   - Node 3: ERP Operations FastMCP Server on Cloud Run (`--functional-type=mcp-server`, `McpToolset`)
2. Real-time BigQuery Agent Analytics (`BigQueryAgentAnalyticsPlugin`) streaming token usage,
   latency (`total_ms`, `ttft_ms`), tool provenance (`tool_origin`: `MCP` vs `A2A`), and A2A metadata
   into BigQuery Storage Write API (`geap_o11y_demo03.agent_events` + semantic views `v_*`), joined by
   the exact same `trace_id` & `span_id` as Cloud Trace (`_AllSpans`).
3. Multimodal / Long-Prompt Offloading (`gcs_bucket_name` + GenAI OTel JSONL Completion Hook) keeping
   Cloud Trace spans lean while archiving full prompt/completion payloads to GCS.
"""

from __future__ import annotations

import os
import sys
import time
from typing import Any, Dict, Optional, Tuple, Union
from urllib.parse import urlparse

os.environ.setdefault("GOOGLE_CLOUD_LOCATION", "global")
os.environ.setdefault("VERTEX_AI_LOCATION", "global")
os.environ.setdefault("ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING", "1")

try:
    import urllib3.contrib.pyopenssl

    urllib3.contrib.pyopenssl.extract_from_urllib3()
except Exception:
    pass

try:
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

    HTTPXClientInstrumentor().instrument()
except Exception:
    pass

import google.auth
import google.auth.impersonated_credentials
import google.auth.transport.requests
import google.oauth2.id_token
from google.adk.a2a import _compat as a2a_compat
from google.adk.a2a.agent.config import A2aCardRequestConfig
from google.adk.a2a.agent.config import A2aRemoteAgentConfig
from google.adk.a2a.agent.config import CardRequestInterceptor
from google.adk.a2a.agent.config import ParametersConfig
from google.adk.a2a.agent.config import RequestInterceptor
from google.adk.agents import LlmAgent
from google.adk.agents.invocation_context import InvocationContext
from google.adk.agents.remote_a2a_agent import RemoteA2aAgent
from google.adk.events.event import Event
from google.adk.models.google_llm import Gemini
from google.adk.plugins.bigquery_agent_analytics_plugin import BigQueryAgentAnalyticsPlugin
from google.adk.plugins.bigquery_agent_analytics_plugin import BigQueryLoggerConfig
from google.adk.tools import AgentTool
from google.adk.tools import McpToolset
from google.adk.tools.mcp_tool import StreamableHTTPConnectionParams
from google.genai import types
from opentelemetry import propagate

PROJECT_ID = os.getenv("PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT", "cabral-governance-ai")
MODEL_NAME = os.getenv("MODEL_NAME", "gemini-3.8-flash")
MCP_URL = os.getenv("MCP_URL", "http://localhost:8080/mcp")
A2A_AGENT_CARD_URL = os.getenv(
    "A2A_AGENT_CARD_URL", "http://localhost:8081/.well-known/agent-card.json"
)
CR_INVOKER_SA = os.getenv("CR_INVOKER_SA", "")
BQ_DATASET = os.getenv("BQ_DATASET", "geap_o11y_demo03")
BQ_TABLE = os.getenv("BQ_TABLE", "agent_events")
TELEMETRY_BUCKET = os.getenv("TELEMETRY_BUCKET", "")

# Process-local cache for short-lived Cloud Run OIDC ID tokens keyed by target audience
_OIDC_TOKEN_CACHE: Dict[str, Tuple[str, float]] = {}


class GlobalGemini(Gemini):
    """Gemini LLM wrapper pinned to the global endpoint (`gemini-3.8-flash` requirement)."""

    @property
    def api_client(self):
        if not hasattr(self, "_global_api_client"):
            from google.genai import Client

            project = os.getenv("PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT")
            self._global_api_client = Client(
                vertexai=True,
                project=project,
                location="global",
                http_options=types.HttpOptions(headers=self._tracking_headers()),
            )
        return self._global_api_client


def _mint_cloud_run_oidc_token(target_url: str) -> Optional[str]:
    """Mints a Google-signed OIDC ID token via `CR_INVOKER_SA` impersonation for Cloud Run."""
    if not target_url or "localhost" in target_url or "127.0.0.1" in target_url:
        return None

    parsed = urlparse(target_url)
    audience = f"{parsed.scheme}://{parsed.netloc}"
    invoker_sa = os.getenv("CR_INVOKER_SA", CR_INVOKER_SA)

    cached = _OIDC_TOKEN_CACHE.get(audience)
    now = time.time()
    if cached and cached[1] > now:
        return cached[0]

    try:
        auth_req = google.auth.transport.requests.Request()
        if invoker_sa:
            source_creds, _ = google.auth.default(
                scopes=["https://www.googleapis.com/auth/cloud-platform"]
            )
            target_sa_creds = google.auth.impersonated_credentials.Credentials(
                source_credentials=source_creds,
                target_principal=invoker_sa,
                target_scopes=["https://www.googleapis.com/auth/cloud-platform"],
                lifetime=3600,
            )
            id_creds = google.auth.impersonated_credentials.IDTokenCredentials(
                target_credentials=target_sa_creds,
                target_audience=audience,
                include_email=True,
            )
            id_creds.refresh(auth_req)
            token = id_creds.token
        else:
            token = google.oauth2.id_token.fetch_id_token(auth_req, audience)

        if token:
            _OIDC_TOKEN_CACHE[audience] = (token, now + 2400.0)
            return token
    except Exception as exc:
        print(
            f"[OIDC] Aviso ao emitir ID Token para audience='{audience}': {exc}",
            file=sys.stderr,
        )
    return None


def get_mcp_auth_and_trace_headers(context: Optional[Any] = None) -> Dict[str, str]:
    """Injects Cloud Run OIDC Bearer token + active W3C `traceparent` into MCP HTTP calls."""
    mcp_url = os.getenv("MCP_URL", MCP_URL)
    headers: Dict[str, str] = {
        "Accept": "application/json, text/event-stream",
    }
    token = _mint_cloud_run_oidc_token(mcp_url)
    if token:
        headers["Authorization"] = f"Bearer {token}"

    try:
        propagate.inject(headers)
    except Exception:
        pass
    return headers


def _build_a2a_headers() -> Dict[str, str]:
    """Builds Cloud Run OIDC + W3C `traceparent` headers for outgoing A2A calls."""
    card_url = os.getenv("A2A_AGENT_CARD_URL", A2A_AGENT_CARD_URL)
    headers: Dict[str, str] = {}
    token = _mint_cloud_run_oidc_token(card_url)
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        propagate.inject(headers)
    except Exception:
        pass
    return headers


async def _a2a_before_card_request(ctx: InvocationContext) -> A2aCardRequestConfig:
    """Injects OIDC + W3C `traceparent` when resolving `/.well-known/agent-card.json`."""
    headers = _build_a2a_headers()
    return A2aCardRequestConfig(headers=headers or None)


async def _a2a_before_request(
    ctx: InvocationContext,
    a2a_request: Any,
    parameters: ParametersConfig,
) -> Tuple[Union[Any, Event], ParametersConfig]:
    """Injects OIDC + W3C `traceparent` into A2A `message/send` HTTP calls."""
    headers = _build_a2a_headers()
    if headers:
        if parameters.client_call_context is None:
            parameters.client_call_context = a2a_compat.ClientCallContext()
        call_ctx = parameters.client_call_context
        if getattr(a2a_compat, "IS_A2A_V1", False):
            call_ctx.service_parameters = {
                **(call_ctx.service_parameters or {}),
                **headers,
            }
        else:
            state = dict(call_ctx.state or {})
            http_kwargs = dict(state.get("http_kwargs") or {})
            http_kwargs["headers"] = {
                **(http_kwargs.get("headers") or {}),
                **headers,
            }
            state["http_kwargs"] = http_kwargs
            call_ctx.state = state
    return a2a_request, parameters


# Node 3 Connector: Streamable HTTP FastMCP Server on Cloud Run (`tool_origin = "MCP"`)
erp_mcp_toolset = McpToolset(
    connection_params=StreamableHTTPConnectionParams(
        url=MCP_URL,
        timeout=20.0,
        sse_read_timeout=20.0,
    ),
    header_provider=get_mcp_auth_and_trace_headers,
)

# Node 2 Connector: Remote A2A Specialist Agent on Cloud Run (`tool_origin = "A2A"`)
sla_risk_remote_agent = RemoteA2aAgent(
    name="sla_risk_specialist",
    description=(
        "Agente Especialista remoto (A2A no Cloud Run) que calcula multas contratuais de SLA "
        "em Reais (R$) e elabora pareceres financeiros de mitigação para pedidos/lotes atrasados."
    ),
    agent_card=A2A_AGENT_CARD_URL,
    timeout=60.0,
    config=A2aRemoteAgentConfig(
        card_request_interceptors=[
            CardRequestInterceptor(before_request=_a2a_before_card_request)
        ],
        request_interceptors=[
            RequestInterceptor(before_request=_a2a_before_request)
        ],
    ),
)

sla_risk_a2a_tool = AgentTool(agent=sla_risk_remote_agent)

# Real-Time BigQuery Agent Analytics Plugin (Storage Write API + Semantic Views, WITHOUT Eval)
_bq_cfg_kwargs: Dict[str, Any] = {
    "enabled": True,
    "gcs_bucket_name": TELEMETRY_BUCKET or None,
    "batch_size": 1,
    "batch_flush_interval": 0.5,
    "flush_on_run_end": True,
    "create_views": True,
    "enable_otel_correlation": True,
    "custom_tags": {
        "demo": "03-geap-otel-topology-analytics",
        "cost_center": "operacoes-b2b-logistica",
        "architecture": "reasoning-engine-mcp-a2a",
    },
}
if "create_eval_views" in getattr(BigQueryLoggerConfig, "__dataclass_fields__", {}):
    _bq_cfg_kwargs["create_eval_views"] = False

bq_logger_config = BigQueryLoggerConfig(**_bq_cfg_kwargs)

bq_analytics_plugin = BigQueryAgentAnalyticsPlugin(
    project_id=PROJECT_ID,
    dataset_id=BQ_DATASET,
    table_id=BQ_TABLE,
    config=bq_logger_config,
    location="US",
)

agent_plugins = [bq_analytics_plugin]

root_agent = LlmAgent(
    model=GlobalGemini(model=MODEL_NAME),
    name="finops_ops_orchestrator",
    description=(
        "Agente Orquestrador de Operações Logísticas B2B & FinOps com observabilidade "
        "distribuída OpenTelemetry (MCP + A2A) e BigQuery Agent Analytics em tempo real."
    ),
    instruction="""Você é o Agente Orquestrador Executivo de Operações B2B & FinOps da plataforma corporativa.

SUA ARQUITETURA MULTI-AGENTE E REGRAS DE EXECUÇÃO:
1. Sempre responda em Português do Brasil (PT-BR) de forma estruturada, executiva e direta.
2. Quando o usuário perguntar sobre um pedido corporativo específico (ex.: `PED-9042`, `PED-7710`, `PED-5503`) ou sobre a fila crítica:
   - PASSO A (MCP): Consulte os dados reais no servidor MCP `erp-ops-mcp` usando `consultar_pedido_corporativo` (ou `listar_pedidos_criticos`).
   - PASSO B (A2A): Caso o pedido apresente atraso de SLA (`horas_atraso_estimado > 0`) ou o usuário peça análise de risco/multa/mitigação, acione OBRIGATORIAMENTE o agente especialista remoto `sla_risk_specialist` (via protocolo A2A) enviando o `pedido_id`, `valor_pedido_brl`, `horas_atraso` e `cadeia_fria` para obter o cálculo oficial da multa e a recomendação financeira.
3. Quando o usuário pedir para diagnosticar ou conciliar um lote logístico no WMS (ex.: `LOTE-2026-10` ou `LOTE-LOCK-503`):
   - PASSO A (MCP): Chame `conciliar_lote_logistico` para inspecionar o status no WMS.
   - PASSO B (A2A): Se o lote apresentar contenção/lock ou pedido impactado com atraso (como `LOTE-LOCK-503` / `PED-5503` da BioFarma), delegue imediatamente ao especialista `sla_risk_specialist` (via A2A) para quantificar o impacto financeiro da multa de cadeia fria e consolidar o plano de ação técnico + financeiro.
4. Consolide na resposta final: (a) Dados do Cliente e Pedido vindos do ERP (MCP), (b) Status Logístico/Diagnóstico Técnico de banco/WMS, e (c) Multa Contratual em R$ e Parecer de Mitigação vindos do Especialista A2A. Nunca invente valores.""",
    tools=[erp_mcp_toolset, sla_risk_a2a_tool],
)
