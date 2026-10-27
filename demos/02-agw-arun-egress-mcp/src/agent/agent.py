"""FinOps & Corporate Treasury ADK Agent for Demo 02 (Agent Gateway to Anywhere — Egress).

Uses Gemini 3.8 Flash on the global endpoint (location='global') while routing all outbound
traffic from Vertex AI Agent Runtime through Agent Gateway (AGENT_TO_ANYWHERE):
- Outbound MCP calls to the registered Cloud Run ERP MCP Server are inspected at Layer 7:
  readOnly tools succeed (HTTP 200), while destructive tools are blocked at the gateway (HTTP 403).
- Outbound HTTP calls to unregistered external URLs (exfiltration attempts) are blocked by
  Agent Gateway default-deny (HTTP 403).
"""

import os
import sys
from typing import Any, Dict, Optional
from urllib.parse import urlparse

os.environ.setdefault("GOOGLE_CLOUD_LOCATION", "global")
os.environ.setdefault("VERTEX_AI_LOCATION", "global")
os.environ.setdefault("ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING", "1")

try:
    import urllib3.contrib.pyopenssl
    urllib3.contrib.pyopenssl.extract_from_urllib3()
except Exception:
    pass

import google.auth
import google.auth.impersonated_credentials
import google.auth.transport.requests
import google.oauth2.id_token
from google.adk.agents import LlmAgent
from google.adk.models.google_llm import Gemini
from google.adk.tools import McpToolset
from google.adk.tools.mcp_tool import StreamableHTTPConnectionParams
from google.genai import types
import httpx

MODEL_NAME = os.getenv("MODEL_NAME", "gemini-3.8-flash")
MCP_URL = os.getenv("MCP_URL", "http://localhost:8080/mcp")
MCP_INVOKER_SA = os.getenv("MCP_INVOKER_SA", "")


class GlobalGemini(Gemini):
    """Gemini LLM wrapper pinned to the global endpoint (gemini-3.8-flash requirement)."""

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


def get_mcp_auth_headers(context: Optional[Any] = None) -> Dict[str, str]:
    """Mints a Google-signed OIDC ID token via Service Account impersonation for Cloud Run.

    Reasoning Engine with AGENT_IDENTITY issues a SPIFFE JWT-SVID signed by sts.googleapis.com.
    Impersonating MCP_INVOKER_SA via iamcredentials.googleapis.com (governed through Agent Gateway)
    bridges SPIFFE identity to Cloud Run's OIDC invoker check.
    """
    mcp_url = os.getenv("MCP_URL", MCP_URL)
    invoker_sa = os.getenv("MCP_INVOKER_SA", MCP_INVOKER_SA)
    headers: Dict[str, str] = {
        "Accept": "application/json, text/event-stream",
    }
    if not mcp_url or "localhost" in mcp_url:
        return headers

    parsed = urlparse(mcp_url)
    audience = f"{parsed.scheme}://{parsed.netloc}"

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
            headers["Authorization"] = f"Bearer {token}"
    except Exception as exc:
        print(f"[HeaderProvider] Falha ao obter OIDC token para MCP: {exc}", file=sys.stderr)

    return headers


def enviar_relatorio_webhook_externo(url_destino: str, resumo_dados: str) -> str:
    """Envia um resumo ou relatório financeiro via HTTP POST para um webhook externo informado pelo usuário.

    Em um ambiente governado por Agent Gateway (AGENT_TO_ANYWHERE), destinos externos não catalogados
    no Agent Registry e sem permissão explícita no IAP sofrem bloqueio Zero-Trust (HTTP 403 Forbidden)
    na borda de saída, prevenindo exfiltração de dados.

    Args:
        url_destino: URL completa do endpoint externo (ex.: 'https://example.com/auditoria-externa').
        resumo_dados: Texto resumido a ser transmitido ao endpoint.
    """
    if not url_destino.startswith(("http://", "https://")):
        return "URL inválida: informe um endereço iniciando com https://."

    try:
        with httpx.Client(timeout=10.0, follow_redirects=False) as http_client:
            resp = http_client.post(
                url_destino,
                json={"origem": "agw-egress-agent-finops", "resumo": resumo_dados},
            )
            if resp.status_code == 403:
                return (
                    f"BLOQUEADO PELO AGENT GATEWAY EGRESS (HTTP 403 Forbidden): "
                    f"O destino externo '{url_destino}' não está registrado/autorizado no Agent Registry (IAP DENIED). "
                    f"Detalhe: {resp.text[:200]}"
                )
            resp.raise_for_status()
            return f"Relatório enviado com sucesso (HTTP {resp.status_code})."
    except httpx.HTTPStatusError as exc:
        status = exc.response.status_code
        return (
            f"BLOQUEADO NA SAÍDA PELO AGENT GATEWAY (HTTP {status}): "
            f"A chamada para '{url_destino}' foi negada pela política de Egress Zero-Trust."
        )
    except Exception as exc:
        return (
            f"CONEXÃO EXTERNA BLOQUEADA PELO PERÍMETRO DE EGRESS ('{url_destino}'): {exc}"
        )


erp_mcp_toolset = McpToolset(
    connection_params=StreamableHTTPConnectionParams(
        url=MCP_URL,
        timeout=15.0,
        sse_read_timeout=15.0,
    ),
    header_provider=get_mcp_auth_headers,
)

root_agent = LlmAgent(
    model=GlobalGemini(model=MODEL_NAME),
    name="agent_finops_egress",
    description="Agente de Tesouraria Corporativa e FinOps governado por Agent Gateway to Anywhere (Egress).",
    instruction="""Você é o Agente de Tesouraria Corporativa e FinOps, operando em um ambiente Zero-Trust governado pelo Google Cloud Agent Gateway (modo AGENT_TO_ANYWHERE / Egress).

SUAS CAPACIDADES E REGRAS DE OPERAÇÃO:
1. Sempre responda em Português do Brasil (PT-BR) de maneira clara, executiva e objetiva.
2. Para consultar contas corporativas, titulares, CNPJ, saldos ou status, chame SEMPRE a ferramenta MCP `consultar_contas_corporativas`.
3. Para consultar o histórico de transações de uma conta específica (ex.: `BR-9010`, `US-4420`, `BR-3315`), chame SEMPRE a ferramenta MCP `listar_transacoes_recentes`.
4. Se o usuário pedir explicitamente para encerrar uma conta ou executar estorno total, invoque a ferramenta MCP `executar_estorno_ou_encerramento` passando o `conta_id` e o `motivo` solicitado. Caso a chamada retorne erro `403 Forbidden` / bloqueio de política de governança do Agent Gateway / IAP, relate claramente ao usuário que o **Agent Gateway (Egress + IAP)** interceptou a chamada JSON-RPC `tools/call` na Camada 7 e bloqueou a execução porque a ferramenta é classificada como destrutiva/escrita (`isReadOnly=false`).
5. Se o usuário pedir para enviar ou exportar um resumo/relatório para uma URL ou webhook externo (ex.: `https://example.com/...`), invoque a ferramenta `enviar_relatorio_webhook_externo` com a URL solicitada. Caso o tráfego seja bloqueado (`HTTP 403 Forbidden`), explique claramente que o **Agent Gateway to Anywhere** barrou a tentativa de saída para um destino externo não catalogado no **Agent Registry** (proteção Zero-Trust contra exfiltração de dados).
6. Nunca invente saldos, transações ou titulares que não tenham sido retornados pelas ferramentas.""",
    tools=[erp_mcp_toolset, enviar_relatorio_webhook_externo],
)
