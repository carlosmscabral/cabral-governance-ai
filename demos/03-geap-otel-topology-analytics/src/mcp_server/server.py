"""Streamable HTTP FastMCP Server for Corporate ERP & Logistics Operations (Demo 03 — Node 3).

Deployed to Cloud Run with `--functional-type=mcp-server` for native Agent Registry and
SRE Application Topology discovery. Implements full W3C Trace Context (`traceparent` via
HTTP headers and JSON-RPC `params._meta.traceparent`) extraction and exports child spans
(`erp.postgres_order_lookup`, `erp.wms_batch_reconciliation`, `erp.legacy_wms_lock_contention`)
to `https://telemetry.googleapis.com/v1/traces` so every MCP tool execution stitches seamlessly
into the parent Vertex AI Reasoning Engine Cloud Trace waterfall.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

os.environ.setdefault("GOOGLE_API_USE_CLIENT_CERTIFICATE", "false")
os.environ.setdefault("GOOGLE_API_USE_MTLS_ENDPOINT", "never")

try:
    import urllib3.contrib.pyopenssl

    urllib3.contrib.pyopenssl.extract_from_urllib3()
except Exception:
    pass

import google.auth
from google.auth.transport.requests import AuthorizedSession
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from opentelemetry import context as otel_context
from opentelemetry import propagate
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind
from opentelemetry.trace import Status
from opentelemetry.trace import StatusCode
from starlette.responses import JSONResponse
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("erp-ops-mcp")

PROJECT_ID = os.getenv("PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT", "")
SERVICE_NAME = os.getenv("K_SERVICE", os.getenv("MCP_SERVICE_NAME", "o11y-mcp-erp-ops"))
REGION = os.getenv("CLOUD_RUN_REGION", os.getenv("REGION", "us-central1"))


def _init_otel_tracer() -> trace.Tracer:
    """Configures OTLP-over-HTTP span export to Google Cloud Telemetry API."""
    base_attrs: dict[str, Any] = {
        "service.name": SERVICE_NAME,
        "service.version": os.getenv("K_REVISION", "1.0.0"),
        "cloud.provider": "gcp",
        "cloud.platform": "gcp_cloud_run",
        "cloud.region": REGION,
        "faas.name": SERVICE_NAME,
    }
    if PROJECT_ID:
        base_attrs["gcp.project_id"] = PROJECT_ID
        base_attrs["cloud.account.id"] = PROJECT_ID

    resource = Resource.create(base_attrs)
    try:
        from opentelemetry.resourcedetector.gcp_resource_detector import (
            GoogleCloudResourceDetector,
        )

        detected = GoogleCloudResourceDetector(raise_on_error=False).detect()
        resource = resource.merge(detected).merge(
            Resource.create(
                {
                    "service.name": SERVICE_NAME,
                    **(
                        {"gcp.project_id": PROJECT_ID, "cloud.account.id": PROJECT_ID}
                        if PROJECT_ID
                        else {}
                    ),
                }
            )
        )
    except Exception as exc:
        logger.warning("GCP resource detector fallback: %s", exc)

    provider = TracerProvider(resource=resource)
    try:
        creds, detected_project = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        if hasattr(creds, "with_quota_project"):
            creds = creds.with_quota_project(None)
        session = AuthorizedSession(credentials=creds)
        exporter = OTLPSpanExporter(
            session=session,
            endpoint="https://telemetry.googleapis.com/v1/traces",
        )
        provider.add_span_processor(
            BatchSpanProcessor(
                exporter,
                schedule_delay_millis=400,
                max_export_batch_size=64,
            )
        )
        logger.info(
            "OTLP Trace Exporter ativo -> telemetry.googleapis.com (project=%s, service=%s)",
            PROJECT_ID or detected_project,
            SERVICE_NAME,
        )
    except Exception as exc:
        logger.warning("Não foi possível inicializar OTLPSpanExporter: %s", exc)

    trace.set_tracer_provider(provider)
    return trace.get_tracer("erp.ops.mcp", "1.0.0")


tracer = _init_otel_tracer()

mcp = FastMCP(
    "erp-ops-mcp",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    stateless_http=True,
    json_response=True,
)

# Dataset sintético realista de Pedidos B2B & Lotes Logísticos
ORDERS_DB: dict[str, dict[str, Any]] = {
    "PED-9042": {
        "pedido_id": "PED-9042",
        "cliente": "Metalúrgica Aurora S.A.",
        "cnpj": "14.882.901/0001-55",
        "segmento": "Indústria Pesada B2B",
        "valor_pedido_brl": 185000.00,
        "valor_formatado": "R$ 185.000,00",
        "lote_logistico": "LOTE-2026-10",
        "rota": "Guarulhos/SP -> Contagem/MG",
        "sla_contratual_horas": 24,
        "horas_em_fila": 28,
        "horas_atraso_estimado": 4.0,
        "cadeia_fria": False,
        "status_erp": "RETIDO_CONFERENCIA_FISCAL",
        "prioridade": "ALTA",
    },
    "PED-7710": {
        "pedido_id": "PED-7710",
        "cliente": "Vanguarda Sistemas Elétricos Ltda.",
        "cnpj": "29.401.330/0001-12",
        "segmento": "Infraestrutura & Energia",
        "valor_pedido_brl": 62400.00,
        "valor_formatado": "R$ 62.400,00",
        "lote_logistico": "LOTE-2026-10",
        "rota": "Curitiba/PR -> Campinas/SP",
        "sla_contratual_horas": 48,
        "horas_em_fila": 9,
        "horas_atraso_estimado": 0.0,
        "cadeia_fria": False,
        "status_erp": "EM_SEPARACAO_NORMAL",
        "prioridade": "PADRAO",
    },
    "PED-5503": {
        "pedido_id": "PED-5503",
        "cliente": "BioFarma Logística Integrada S.A.",
        "cnpj": "08.119.450/0001-90",
        "segmento": "Hospitalar & Cadeia Fria",
        "valor_pedido_brl": 410000.00,
        "valor_formatado": "R$ 410.000,00",
        "lote_logistico": "LOTE-LOCK-503",
        "rota": "Itapevi/SP -> Rio de Janeiro/RJ",
        "sla_contratual_horas": 12,
        "horas_em_fila": 18,
        "horas_atraso_estimado": 6.0,
        "cadeia_fria": True,
        "status_erp": "BLOQUEADO_LOCK_WMS_LEGADO",
        "prioridade": "CRITICA_CADEIA_FRIA",
    },
}

BATCHES_DB: dict[str, dict[str, Any]] = {
    "LOTE-2026-10": {
        "lote_id": "LOTE-2026-10",
        "doca_expedicao": "DOCA-SP-04",
        "transportadora": "Expresso Sudeste S.A.",
        "status_wms": "CONCILIADO_COM_RESSALVA_FISCAL",
        "pedidos_vinculados": ["PED-9042", "PED-7710"],
        "telemetria_iot": "Temperatura ambiente (22.4 C), manifesto MDF-e aguardando liberação de PED-9042.",
    },
}


def _normalize_id(raw: str) -> str:
    return raw.strip().upper().lstrip("#")


@mcp.tool(
    name="consultar_pedido_corporativo",
    description=(
        "Consulta os dados completos de um pedido corporativo B2B no ERP (cliente, CNPJ, "
        "valor em R$, lote logístico, SLA contratual e horas de atraso). Operação somente leitura."
    ),
    annotations=ToolAnnotations(
        title="Consultar Pedido Corporativo B2B",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
def consultar_pedido_corporativo(pedido_id: str) -> str:
    """Retorna os detalhes do pedido corporativo a partir do ERP PostgreSQL."""
    norm_id = _normalize_id(pedido_id)
    with tracer.start_as_current_span(
        "erp.postgres_order_lookup",
        kind=SpanKind.INTERNAL,
        attributes={
            "db.system": "postgresql",
            "db.name": "erp_corporativo_prod",
            "db.operation": "SELECT",
            "erp.pedido_id": norm_id,
            "mcp.tool.name": "consultar_pedido_corporativo",
        },
    ) as span:
        time.sleep(0.06)  # Simula latência realista de consulta indexada no ERP
        order = ORDERS_DB.get(norm_id)
        if not order:
            span.set_attribute("erp.order_found", False)
            return json.dumps(
                {
                    "erro": f"Pedido '{norm_id}' não localizado.",
                    "pedidos_disponiveis": list(ORDERS_DB.keys()),
                },
                ensure_ascii=False,
            )

        span.set_attribute("erp.order_found", True)
        span.set_attribute("erp.cliente", order["cliente"])
        span.set_attribute("erp.valor_pedido_brl", order["valor_pedido_brl"])
        span.set_attribute("erp.horas_atraso_estimado", order["horas_atraso_estimado"])
        return json.dumps({"sistema": "ERP-Ops-v4", "pedido": order}, ensure_ascii=False)


@mcp.tool(
    name="listar_pedidos_criticos",
    description=(
        "Lista todos os pedidos corporativos ativos na fila logística do ERP e destaca "
        "quais possuem risco ou atraso de SLA. Operação somente leitura."
    ),
    annotations=ToolAnnotations(
        title="Listar Fila de Pedidos B2B",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
def listar_pedidos_criticos() -> str:
    """Lista o resumo executivo de todos os pedidos monitorados no ERP."""
    with tracer.start_as_current_span(
        "erp.postgres_list_critical_orders",
        kind=SpanKind.INTERNAL,
        attributes={
            "db.system": "postgresql",
            "db.name": "erp_corporativo_prod",
            "db.operation": "SELECT",
            "mcp.tool.name": "listar_pedidos_criticos",
        },
    ) as span:
        time.sleep(0.05)
        span.set_attribute("erp.orders_count", len(ORDERS_DB))
        return json.dumps(
            {
                "sistema": "ERP-Ops-v4",
                "total_pedidos": len(ORDERS_DB),
                "pedidos": list(ORDERS_DB.values()),
            },
            ensure_ascii=False,
        )


@mcp.tool(
    name="conciliar_lote_logistico",
    description=(
        "Verifica o status de expedição e conciliação de um lote logístico no WMS "
        "(ex.: LOTE-2026-10 ou LOTE-LOCK-503). Diagnostica contenção de lock e gargalos de doca."
    ),
    annotations=ToolAnnotations(
        title="Conciliar Lote Logístico WMS",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
def conciliar_lote_logistico(lote_id: str) -> str:
    """Concilia um lote de expedição no WMS e captura telemetria de latência/lock."""
    norm_lote = _normalize_id(lote_id)

    # Caso especial para demonstração de observabilidade de gargalo/anomalia no Cloud Trace
    if norm_lote in ("LOTE-LOCK-503", "PED-5503"):
        with tracer.start_as_current_span(
            "erp.legacy_wms_lock_contention",
            kind=SpanKind.INTERNAL,
            attributes={
                "db.system": "postgresql",
                "db.name": "wms_expedicao_legado",
                "db.sql.table": "wms_expedicao_fria",
                "erp.lote_id": "LOTE-LOCK-503",
                "mcp.tool.name": "conciliar_lote_logistico",
                "erp.anomaly_simulated": True,
            },
        ) as span:
            # Pausa intencional de 1.35s para destacar visualmente a barra vermelha no Cloud Trace Waterfall
            time.sleep(1.35)
            err_msg = (
                "PG_LOCK_TIMEOUT (55P03): Contenção severa de lock exclusivo na tabela "
                "'wms_expedicao_fria' após 1350ms para o lote LOTE-LOCK-503 (Pedido PED-5503 / BioFarma)."
            )
            span.set_attribute("db.lock_wait_ms", 1350)
            span.set_attribute("erp.lock_holder_pid", 48291)
            span.add_event(
                "db.lock_contention_detected",
                {
                    "table": "wms_expedicao_fria",
                    "wait_ms": 1350,
                    "blocking_job": "nightly_cold_chain_sync",
                },
            )
            span.set_status(Status(StatusCode.ERROR, err_msg))
            return json.dumps(
                {
                    "status_conciliacao": "DEGRADADO_LOCK_TIMEOUT",
                    "codigo_erro_wms": "PG_LOCK_TIMEOUT_55P03",
                    "lote_id": "LOTE-LOCK-503",
                    "pedido_impactado": "PED-5503",
                    "cliente_impactado": "BioFarma Logística Integrada S.A.",
                    "valor_pedido_brl": 410000.00,
                    "horas_atraso_estimado": 6.0,
                    "cadeia_fria": True,
                    "latencia_lock_ms": 1350,
                    "diagnostico_tecnico": err_msg,
                    "acao_recomendada": (
                        "Acionar especialista de risco de SLA para quantificar multa de cadeia fria "
                        "e encerrar sessão bloqueadora PID 48291 (nightly_cold_chain_sync)."
                    ),
                },
                ensure_ascii=False,
            )

    with tracer.start_as_current_span(
        "erp.wms_batch_reconciliation",
        kind=SpanKind.INTERNAL,
        attributes={
            "db.system": "postgresql",
            "db.name": "wms_expedicao_legado",
            "erp.lote_id": norm_lote,
            "mcp.tool.name": "conciliar_lote_logistico",
        },
    ) as span:
        time.sleep(0.08)
        batch = BATCHES_DB.get(norm_lote)
        if not batch:
            span.set_attribute("erp.batch_found", False)
            return json.dumps(
                {
                    "erro": f"Lote '{norm_lote}' não encontrado no WMS.",
                    "lotes_disponiveis": ["LOTE-2026-10", "LOTE-LOCK-503"],
                },
                ensure_ascii=False,
            )
        span.set_attribute("erp.batch_found", True)
        return json.dumps({"status_conciliacao": "OK", "lote": batch}, ensure_ascii=False)


class W3CTraceContextASGIMiddleware:
    """Extracts W3C `traceparent` from HTTP headers OR MCP JSON-RPC `params._meta`."""

    def __init__(self, inner_app):
        self.inner_app = inner_app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path") == "/healthz":
            await self.inner_app(scope, receive, send)
            return

        headers_dict: dict[str, str] = {}
        for k, v in scope.get("headers", []):
            headers_dict[k.decode("latin1").lower()] = v.decode("latin1")

        # Buffer request body once so we can inspect JSON-RPC `params._meta.traceparent`
        # as a fallback when an MCP client only populates `_meta` instead of HTTP headers,
        # and also label the span with the exact MCP method & tool name!
        body_chunks: list[bytes] = []
        more_body = True
        while more_body:
            msg = await receive()
            if msg["type"] == "http.request":
                body_chunks.append(msg.get("body", b""))
                more_body = msg.get("more_body", False)
            else:
                more_body = False
        raw_body = b"".join(body_chunks)

        rpc_method = ""
        mcp_tool_name = ""
        if raw_body:
            try:
                parsed_json = json.loads(raw_body.decode("utf-8"))
                if isinstance(parsed_json, dict):
                    rpc_method = str(parsed_json.get("method") or "")
                    params = parsed_json.get("params") or {}
                    if isinstance(params, dict):
                        mcp_tool_name = str(params.get("name") or "")
                        meta = params.get("_meta") or {}
                        if isinstance(meta, dict) and "traceparent" not in headers_dict:
                            if isinstance(meta.get("traceparent"), str):
                                headers_dict["traceparent"] = meta["traceparent"]
                            if isinstance(meta.get("tracestate"), str):
                                headers_dict["tracestate"] = meta["tracestate"]
            except Exception:
                pass

        replayed = False

        async def replay_receive():
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": raw_body, "more_body": False}
            return await receive()

        parent_ctx = propagate.extract(headers_dict)
        span_name = (
            f"mcp.server/{rpc_method}:{mcp_tool_name}"
            if mcp_tool_name
            else f"mcp.server/{rpc_method or scope.get('method', 'POST')}"
        )

        token = otel_context.attach(parent_ctx)
        status_code_holder = [200]

        async def wrapped_send(message):
            if message["type"] == "http.response.start":
                status_code_holder[0] = int(message.get("status", 200))
            await send(message)

        try:
            with tracer.start_as_current_span(
                span_name,
                kind=SpanKind.SERVER,
                attributes={
                    "http.request.method": scope.get("method", "POST"),
                    "url.path": scope.get("path", "/mcp"),
                    "mcp.method.name": rpc_method or "http",
                    **({"gen_ai.tool.name": mcp_tool_name} if mcp_tool_name else {}),
                },
            ) as span:
                await self.inner_app(scope, replay_receive, wrapped_send)
                span.set_attribute("http.response.status_code", status_code_holder[0])
        finally:
            otel_context.detach(token)


async def healthz(request):
    return JSONResponse(
        {
            "status": "ok",
            "service": SERVICE_NAME,
            "functional_type": "mcp-server",
            "mcp_endpoint": "/mcp",
            "tools": [
                "consultar_pedido_corporativo",
                "listar_pedidos_criticos",
                "conciliar_lote_logistico",
            ],
        }
    )


inner_starlette = mcp.streamable_http_app()
inner_starlette.add_route("/healthz", healthz, methods=["GET"])
app = W3CTraceContextASGIMiddleware(inner_starlette)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
