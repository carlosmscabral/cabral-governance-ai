"""Cloud Run Specialist A2A Agent for Contractual SLA Risk & Penalty Analysis (Demo 03 — Node 2).

Deployed to Cloud Run with:
  --functional-type=agent --identity-type=agent-identity --no-identity-certificate

Exposes an ADK `LlmAgent` (`sla_risk_specialist`, powered by `gemini-3.8-flash` on `global`)
over the A2A Protocol (`/.well-known/agent-card.json` + JSON-RPC task endpoint) via `to_a2a()`.
Extracts incoming W3C `traceparent` headers from the Reasoning Engine Orchestrator and exports
OpenTelemetry GenAI & custom calculation spans to `telemetry.googleapis.com` using ADK's native
`get_gcp_exporters` + `get_gcp_resource` (including Agent Registry URN enrichment).
"""

from __future__ import annotations

import json
import logging
import os

os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "True")
os.environ.setdefault("GOOGLE_CLOUD_LOCATION", "global")
os.environ.setdefault("VERTEX_AI_LOCATION", "global")
os.environ.setdefault("OTEL_SEMCONV_STABILITY_OPT_IN", "gen_ai_latest_experimental")
os.environ.setdefault("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "EVENT_ONLY")
os.environ.setdefault("ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS", "false")
os.environ.setdefault("GOOGLE_API_USE_CLIENT_CERTIFICATE", "false")
os.environ.setdefault("GOOGLE_API_USE_MTLS_ENDPOINT", "never")
os.environ.setdefault("GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES", "false")

from google.adk.a2a.utils.agent_to_a2a import to_a2a
from google.adk.agents import LlmAgent
from google.adk.models.google_llm import Gemini
from google.adk.telemetry.google_cloud import get_gcp_exporters
from google.adk.telemetry.google_cloud import get_gcp_resource
from google.adk.telemetry.setup import maybe_set_otel_providers
from google.genai import types
from opentelemetry import context as otel_context
from opentelemetry import propagate
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.trace import SpanKind
from starlette.responses import JSONResponse
from starlette.routing import Route
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("a2a-sla-risk")

PROJECT_ID = os.getenv("PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT", "")
MODEL_NAME = os.getenv("MODEL_NAME", "gemini-3.8-flash")
SERVICE_NAME = os.getenv("K_SERVICE", os.getenv("A2A_SERVICE_NAME", "o11y-a2a-sla-risk"))
PUBLIC_HOST = os.getenv("PUBLIC_HOST", "localhost")
PUBLIC_PORT = int(os.getenv("PUBLIC_PORT", "443" if PUBLIC_HOST != "localhost" else "8080"))
PUBLIC_PROTOCOL = os.getenv("PUBLIC_PROTOCOL", "https" if PUBLIC_HOST != "localhost" else "http")


def _setup_cloud_run_agent_telemetry() -> trace.Tracer:
    """Initializes ADK GCP OTLP exporters + Google GenAI SDK instrumentor on Cloud Run."""
    try:
        otel_hooks = get_gcp_exporters(
            enable_cloud_tracing=True,
            enable_cloud_metrics=True,
            enable_cloud_logging=False,
        )
        otel_resource = get_gcp_resource(project_id=PROJECT_ID).merge(
            Resource.create({"service.name": SERVICE_NAME})
        )
        maybe_set_otel_providers([otel_hooks], otel_resource)
        logger.info(
            "ADK OTel inicializado para Cloud Run Agent '%s' (project=%s)",
            SERVICE_NAME,
            PROJECT_ID,
        )
    except Exception as exc:
        logger.warning("Aviso na inicialização OTel do Cloud Run Agent: %s", exc)

    try:
        from opentelemetry.instrumentation.google_genai import GoogleGenAiSdkInstrumentor

        GoogleGenAiSdkInstrumentor().instrument()
    except Exception as exc:
        logger.debug("GoogleGenAiSdkInstrumentor indisponível ou já ativo: %s", exc)

    return trace.get_tracer("a2a.sla_risk.specialist", "1.0.0")


tracer = _setup_cloud_run_agent_telemetry()


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


def calcular_multa_contratual_sla(
    pedido_id: str,
    valor_pedido_brl: float,
    horas_atraso: float,
    cadeia_fria: bool = False,
) -> str:
    """Calcula a exposição financeira de multa contratual de SLA e recomenda plano de mitigação.

    Args:
        pedido_id: Identificador do pedido corporativo (ex.: 'PED-9042' ou 'PED-5503').
        valor_pedido_brl: Valor total do pedido em Reais (BRL).
        horas_atraso: Horas estimadas acima do SLA contratual.
        cadeia_fria: Define se o pedido pertence à cadeia fria hospitalar (multiplicador 2.5x).
    """
    with tracer.start_as_current_span(
        "sla.penalty_matrix_eval",
        kind=SpanKind.INTERNAL,
        attributes={
            "sla.pedido_id": pedido_id,
            "sla.valor_pedido_brl": float(valor_pedido_brl),
            "sla.horas_atraso": float(horas_atraso),
            "sla.cadeia_fria": bool(cadeia_fria),
        },
    ) as span:
        if horas_atraso <= 0:
            multa_brl = 0.0
            nivel_risco = "BAIXO_DENTRO_DO_SLA"
            recomendacao = "Manter expedição padrão sem custo adicional de frete dedicado."
        else:
            taxa_horaria_base = 0.0075  # 0,75% por hora de atraso
            multiplicador = 2.5 if cadeia_fria else 1.0
            teto_percentual = 0.25 if cadeia_fria else 0.15
            multa_bruta = valor_pedido_brl * taxa_horaria_base * horas_atraso * multiplicador
            multa_brl = round(min(multa_bruta, valor_pedido_brl * teto_percentual), 2)
            custo_frete_expresso = 2400.00 if not cadeia_fria else 6800.00

            if cadeia_fria or multa_brl >= 10000:
                nivel_risco = "CRITICO_ACIONAR_CONTINGENCIA_IMEDIATA"
            else:
                nivel_risco = "MODERADO_COMPENSA_FRETE_DEDICADO"

            economia_liquida = round(max(0.0, multa_brl - custo_frete_expresso), 2)
            recomendacao = (
                f"Autorizar frete dedicado imediato (custo R$ {custo_frete_expresso:,.2f}) "
                f"para estancar multa contratual estimada em R$ {multa_brl:,.2f} "
                f"(economia líquida protegida: R$ {economia_liquida:,.2f})."
            )

        span.set_attribute("sla.multa_calculada_brl", multa_brl)
        span.set_attribute("sla.nivel_risco", nivel_risco)

        return json.dumps(
            {
                "pedido_id": pedido_id,
                "valor_pedido_brl": valor_pedido_brl,
                "horas_atraso": horas_atraso,
                "cadeia_fria": cadeia_fria,
                "multa_estimada_brl": multa_brl,
                "nivel_risco": nivel_risco,
                "parecer_mitigacao": recomendacao,
            },
            ensure_ascii=False,
        )


sla_risk_specialist = LlmAgent(
    model=GlobalGemini(model=MODEL_NAME),
    name="sla_risk_specialist",
    description=(
        "Agente Especialista em Risco Contratual de SLA B2B, Cálculo de Multas Logísticas "
        "e Planos de Mitigação Financeira (exposto via protocolo A2A no Cloud Run)."
    ),
    instruction="""Você é o Agente Especialista em Risco de SLA & Governança Logística B2B (operando via protocolo A2A no Cloud Run).

REGRAS DE EXECUÇÃO:
1. Sempre responda em Português do Brasil (PT-BR) de forma objetiva, analítica e executiva.
2. Sempre que receber dados de um pedido corporativo ou lote com horas de atraso, chame OBRIGATORIAMENTE a ferramenta `calcular_multa_contratual_sla` informando `pedido_id`, `valor_pedido_brl`, `horas_atraso` e `cadeia_fria`.
3. Retorne o valor exato da multa estimada em Reais (R$), a classificação de risco e a recomendação financeira de mitigação retornada pela ferramenta, sem inventar números.""",
    tools=[calcular_multa_contratual_sla],
)


class A2ATraceParentMiddleware:
    """Extracts incoming HTTP W3C `traceparent` so Cloud Run A2A spans attach to Reasoning Engine."""

    def __init__(self, inner_app):
        self.inner_app = inner_app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path") == "/healthz":
            await self.inner_app(scope, receive, send)
            return

        headers_dict = {
            k.decode("latin1").lower(): v.decode("latin1")
            for k, v in scope.get("headers", [])
        }
        parent_ctx = propagate.extract(headers_dict)
        path = scope.get("path", "/")
        method = scope.get("method", "POST")
        token = otel_context.attach(parent_ctx)
        status_holder = [200]

        async def wrapped_send(message):
            if message["type"] == "http.response.start":
                status_holder[0] = int(message.get("status", 200))
            await send(message)

        try:
            with tracer.start_as_current_span(
                f"a2a.specialist/{method} {path}",
                kind=SpanKind.SERVER,
                attributes={
                    "http.request.method": method,
                    "url.path": path,
                    "a2a.agent.name": "sla_risk_specialist",
                },
            ) as span:
                await self.inner_app(scope, receive, wrapped_send)
                span.set_attribute("http.response.status_code", status_holder[0])
        finally:
            otel_context.detach(token)


async def healthz(request):
    return JSONResponse(
        {
            "status": "ok",
            "service": SERVICE_NAME,
            "functional_type": "agent",
            "protocol": "a2a",
            "agent_card": "/.well-known/agent-card.json",
            "model": MODEL_NAME,
        }
    )


a2a_starlette = to_a2a(
    sla_risk_specialist,
    host=PUBLIC_HOST,
    port=PUBLIC_PORT,
    protocol=PUBLIC_PROTOCOL,
)
a2a_starlette.routes.insert(0, Route("/healthz", healthz, methods=["GET"]))
app = A2ATraceParentMiddleware(a2a_starlette)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
