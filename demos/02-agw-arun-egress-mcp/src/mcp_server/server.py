#!/usr/bin/env python3
"""Corporate Treasury & FinOps Streamable HTTP MCP Server for Demo 02 (Agent Gateway Egress).

Exposes three MCP tools with explicit security/governance annotations:
1. consultar_contas_corporativas   -> readOnly=True,  destructive=False
2. listar_transacoes_recentes      -> readOnly=True,  destructive=False
3. executar_estorno_ou_encerramento -> readOnly=False, destructive=True
"""

import json
import logging
import os
import mcp.types as types
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("mcp-erp-tesouraria")

# Stateless JSON-RPC Streamable HTTP server for Cloud Run + Agent Gateway L7 inspection
mcp = FastMCP(
    "ERP Tesouraria Corporativa MCP",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    stateless_http=True,
    json_response=True,
)

CONTAS_TESOURARIA = {
    "BR-9010": {
        "conta_id": "BR-9010",
        "titular": "Horizonte Energia S.A.",
        "cnpj": "12.345.678/0001-90",
        "moeda": "BRL",
        "saldo": "R$ 4.850.000,00",
        "status": "ATIVA",
        "centro_custo": "Operações Brasil",
    },
    "US-4420": {
        "conta_id": "US-4420",
        "titular": "Vanguarda Logística Ltda.",
        "cnpj": "98.765.432/0001-10",
        "moeda": "BRL",
        "saldo": "R$ 1.920.000,00",
        "status": "ATIVA",
        "centro_custo": "Reserva Cambial & Comércio Exterior",
    },
    "BR-3315": {
        "conta_id": "BR-3315",
        "titular": "Atlântico Varejo S.A.",
        "cnpj": "45.111.222/0001-55",
        "moeda": "BRL",
        "saldo": "R$ 780.500,00",
        "status": "EM AUDITORIA",
        "centro_custo": "Liquidação PIX Corporativo",
    },
}

TRANSACOES_POR_CONTA = {
    "BR-9010": [
        {
            "tx_id": "TX-2026-8801",
            "data": "2026-10-25",
            "tipo": "CREDITO_LIQUIDACAO",
            "contraparte": "Operadora Nacional de Rede Elétrica",
            "valor": "R$ 650.000,00",
            "status": "LIQUIDADA",
        },
        {
            "tx_id": "TX-2026-8802",
            "data": "2026-10-26",
            "tipo": "PAGAMENTO_FORNECEDOR",
            "contraparte": "TurbinaTech Engenharia Ltda.",
            "valor": "-R$ 120.000,00",
            "status": "LIQUIDADA",
        },
    ],
    "US-4420": [
        {
            "tx_id": "TX-2026-9104",
            "data": "2026-10-26",
            "tipo": "FECHAMENTO_CAMBIO",
            "contraparte": "Mesa Câmbio Corporativo SP",
            "valor": "R$ 420.000,00",
            "status": "LIQUIDADA",
        }
    ],
    "BR-3315": [
        {
            "tx_id": "TX-2026-7710",
            "data": "2026-10-24",
            "tipo": "LOTE_PIX_VAREJO",
            "contraparte": "Adquirente Sul Pagamentos",
            "valor": "R$ 95.500,00",
            "status": "EM_CONCILIACAO",
        }
    ],
}


@mcp.tool(
    annotations=types.ToolAnnotations(
        title="Consultar Contas Corporativas",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    )
)
async def consultar_contas_corporativas() -> str:
    """Lista todas as contas corporativas da tesouraria, titulares, saldos e status atual.

    Ferramenta estritamente de leitura (readOnly=True).
    """
    logger.info("Executando tool readOnly: consultar_contas_corporativas")
    return json.dumps(
        {"contas": list(CONTAS_TESOURARIA.values())},
        ensure_ascii=False,
        indent=2,
    )


@mcp.tool(
    annotations=types.ToolAnnotations(
        title="Listar Transações Recentes",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    )
)
async def listar_transacoes_recentes(conta_id: str) -> str:
    """Lista o histórico recente de transações financeiras auditadas de uma conta corporativa.

    Args:
        conta_id: Identificador da conta corporativa (ex.: 'BR-9010', 'US-4420', 'BR-3315').
    """
    chave = (conta_id or "").strip().upper()
    logger.info("Executando tool readOnly: listar_transacoes_recentes(%s)", chave)
    conta = CONTAS_TESOURARIA.get(chave)
    if not conta:
        return json.dumps(
            {
                "erro": f"Conta '{conta_id}' não encontrada.",
                "contas_disponiveis": list(CONTAS_TESOURARIA.keys()),
            },
            ensure_ascii=False,
        )
    return json.dumps(
        {
            "conta": conta,
            "transacoes": TRANSACOES_POR_CONTA.get(chave, []),
        },
        ensure_ascii=False,
        indent=2,
    )


@mcp.tool(
    annotations=types.ToolAnnotations(
        title="Executar Estorno ou Encerramento de Conta",
        readOnlyHint=False,
        destructiveHint=True,
        idempotentHint=False,
        openWorldHint=False,
    )
)
async def executar_estorno_ou_encerramento(conta_id: str, motivo: str) -> str:
    """OPERAÇÃO DESTRUTIVA DE ESCRITA: executa estorno total e encerramento irreversível de conta corporativa.

    Args:
        conta_id: Identificador da conta corporativa a encerrar/estornar (ex.: 'BR-9010').
        motivo: Justificativa operacional para o encerramento irreversível.
    """
    logger.warning(
        "ALERTA CRITICO: Tool destrutiva executar_estorno_ou_encerramento(%s) atingiu o backend!",
        conta_id,
    )
    return json.dumps(
        {
            "status": "ENCERRADA_IRREVERSIVELMENTE",
            "conta_id": conta_id,
            "motivo": motivo,
        },
        ensure_ascii=False,
    )


app = mcp.streamable_http_app()


async def healthz(request: Request) -> PlainTextResponse:
    return PlainTextResponse("ok", status_code=200)


async def info(request: Request) -> JSONResponse:
    return JSONResponse(
        {
            "service": "agw-egress-mcp-erp",
            "protocol": "MCP Streamable HTTP (JSON-RPC 2.0)",
            "endpoint": "/mcp",
        }
    )


app.add_route("/healthz", healthz, methods=["GET"])
app.add_route("/", info, methods=["GET"])

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    logger.info("Iniciando ERP Tesouraria MCP Server na porta %d", port)
    uvicorn.run(app, host="0.0.0.0", port=port)
