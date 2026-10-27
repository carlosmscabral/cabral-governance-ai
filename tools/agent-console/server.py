#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "fastapi>=0.110.0",
#   "uvicorn>=0.27.0",
#   "httpx>=0.27.0",
#   "google-auth>=2.28.0",
# ]
# ///
"""
Agent Console & Wire Inspector — Local Support Tool & Jetski Web UI Sidecar.

Provides:
1. Auto-discovery of demos under `demos/*/` (`.state/agent_info.json`, `env.sh`, `scenarios.json`).
2. Two-layer Authentication Manager:
   - Layer 1 (Transport): Automatic gcloud Access/Identity token minting & TTL caching + manual override.
   - Layer 2 (User/Delegated): Persona selector, custom propagation headers, 3LO `/oauth/callback` receiver.
3. Dual-Path Session Lifecycle Manager (`/api/sessions/create`, `/api/sessions/reset`):
   - Path A (Vertex Reasoning Engine `:query`): invokes `{"class_method": "create_session" | "delete_session"}`.
   - Path B (ADK Passthrough `/api/.../sessions`): invokes `POST .../apps/{id}/users/{u}/sessions` with `{}`.
4. Transparent Wire Proxy (`/api/proxy/stream`) streaming NDJSON events with full HTTP Request/Response
   headers, cURL generation, SSE chunk timeline, tool call extraction, and granular governance verdicts
   (differentiating Request/Ingress blocks vs. Response/DLP blocks).
5. Jetski Web UI Plugin compatibility (`ANTIGRAVITY_SIDECAR_WEB_PORT`, `/preload.js`, `X-Sidecar-Token`).
"""

from __future__ import annotations

import datetime
import json
import os
import re
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
DEMOS_DIR = REPO_ROOT / "demos"
STATIC_DIR = HERE / "static"
JETSKI_PRELOAD_PATH = Path("/google/src/files/head/depot/google3/third_party/jetski/sidecar_sdk/preload.js")

BRT_TZ = datetime.timezone(datetime.timedelta(hours=-3), name="BRT")


def now_brt_str() -> str:
    return datetime.datetime.now(tz=BRT_TZ).strftime("%H:%M:%S.%f")[:-3] + " BRT"


def now_brt_short() -> str:
    return datetime.datetime.now(tz=BRT_TZ).strftime("%Y-%m-%d %H:%M:%S BRT")


# ==============================================================================
# Two-Layer Auth & Token Cache State
# ==============================================================================
FORBIDDEN_GCLOUD_CONFIGS = {"tim"}  # Safety belt aligned with global user rule


class AuthManager:
    def __init__(self) -> None:
        self.gcloud_config: str = self._detect_default_gcloud_config()
        self.token_type: str = "access"  # "access" | "identity" | "manual" | "none"
        self.manual_token: str = ""
        self._cache: dict[str, dict[str, Any]] = {}
        self.token_ttl_seconds: int = 3300

        # Layer 2: User / Delegated Context (3LO / OBO / Cascading permissions)
        self.delegated_context: dict[str, Any] = {
            "enabled": False,
            "mode": "none",
            "subject_token": "",
            "header_name": "X-Forwarded-Authorization",
            "extra_claims": {},
            "oauth_client_id": "",
            "auth_provider": "",
            "last_callback_event": None,
        }

    def _detect_default_gcloud_config(self) -> str:
        env_cfg = os.environ.get("CLOUDSDK_ACTIVE_CONFIG_NAME", "").strip()
        if env_cfg and env_cfg.lower() not in FORBIDDEN_GCLOUD_CONFIGS:
            return env_cfg
        try:
            res = subprocess.run(
                ["gcloud", "config", "configurations", "describe", "argolis"],
                capture_output=True,
                text=True,
                timeout=4,
            )
            if res.returncode == 0:
                return "argolis"
        except Exception:
            pass
        return "default"

    def _cache_key(self, token_type: str, config_name: str) -> str:
        return f"{config_name}:{token_type}"

    def get_token(self, token_type: str | None = None, force_refresh: bool = False) -> dict[str, Any]:
        ttype = token_type or self.token_type
        if ttype == "none":
            return {
                "token": "",
                "masked": "(sem autenticação)",
                "source": "none",
                "ttl_remaining_s": None,
                "fetched_at_brt": None,
                "account": None,
            }
        if ttype == "manual":
            tok = self.manual_token.strip()
            masked = f"{tok[:10]}...{tok[-6:]}" if len(tok) > 20 else ("***" if tok else "(vazio)")
            return {
                "token": tok,
                "masked": masked,
                "source": "manual",
                "ttl_remaining_s": None,
                "fetched_at_brt": now_brt_short(),
                "account": "manual-override",
            }

        cfg = self.gcloud_config
        if cfg.lower() in FORBIDDEN_GCLOUD_CONFIGS:
            raise HTTPException(
                status_code=403,
                detail=f"Configuração gcloud '{cfg}' bloqueada por política de segurança.",
            )

        key = self._cache_key(ttype, cfg)
        now = time.time()
        cached = self._cache.get(key)
        if cached and not force_refresh:
            elapsed = now - cached["fetched_ts"]
            remaining = int(self.token_ttl_seconds - elapsed)
            if remaining > 0:
                return {
                    **cached,
                    "ttl_remaining_s": remaining,
                }

        cmd_verb = "print-identity-token" if ttype == "identity" else "print-access-token"
        cmd = ["gcloud", "auth", cmd_verb, f"--configuration={cfg}"]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=True)
            tok = res.stdout.strip()
        except subprocess.CalledProcessError as exc:
            err_msg = (exc.stderr or exc.stdout or str(exc)).strip()
            raise HTTPException(
                status_code=401,
                detail=f"Falha ao obter token via gcloud ({' '.join(cmd)}): {err_msg}",
            ) from exc

        account = self._get_gcloud_value("core/account", cfg)
        masked = f"{tok[:12]}...{tok[-6:]}" if len(tok) > 22 else "***"
        entry = {
            "token": tok,
            "masked": masked,
            "source": f"gcloud ({cfg} / {ttype})",
            "fetched_ts": now,
            "fetched_at_brt": now_brt_short(),
            "ttl_remaining_s": self.token_ttl_seconds,
            "account": account,
            "gcloud_config": cfg,
            "token_type": ttype,
        }
        self._cache[key] = entry
        return entry

    def _get_gcloud_value(self, prop: str, cfg: str) -> str:
        try:
            res = subprocess.run(
                ["gcloud", "config", "get-value", prop, f"--configuration={cfg}"],
                capture_output=True,
                text=True,
                timeout=4,
            )
            return res.stdout.strip()
        except Exception:
            return ""

    def status_summary(self) -> dict[str, Any]:
        try:
            tok_info = self.get_token(force_refresh=False)
            safe_tok = {k: v for k, v in tok_info.items() if k != "token"}
            safe_tok["ok"] = bool(tok_info.get("token")) or self.token_type == "none"
            safe_tok["error"] = None
        except HTTPException as exc:
            safe_tok = {
                "ok": False,
                "masked": "(erro ao obter token)",
                "source": f"gcloud ({self.gcloud_config})",
                "ttl_remaining_s": 0,
                "fetched_at_brt": now_brt_short(),
                "account": None,
                "error": exc.detail,
            }
        return {
            "gcloud_config": self.gcloud_config,
            "token_type": self.token_type,
            "transport_auth": safe_tok,
            "delegated_context": {
                **self.delegated_context,
                "subject_token": (
                    f"{self.delegated_context['subject_token'][:8]}..."
                    if self.delegated_context.get("subject_token")
                    else ""
                ),
            },
        }


AUTH_MANAGER = AuthManager()

# ==============================================================================
# Demo Auto-Discovery
# ==============================================================================


def _parse_env_sh(env_path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not env_path.is_file():
        return values
    pattern = re.compile(r'^\s*export\s+([A-Z0-9_]+)="?\$\{[A-Z0-9_]+:-([^"}]+)\}"?')
    simple_pattern = re.compile(r'^\s*export\s+([A-Z0-9_]+)="([^"$]+)"')
    for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = pattern.match(line)
        if m:
            values[m.group(1)] = m.group(2)
            continue
        m2 = simple_pattern.match(line)
        if m2:
            values[m2.group(1)] = m2.group(2)
    return values


def discover_demos() -> list[dict[str, Any]]:
    demos: list[dict[str, Any]] = []
    if not DEMOS_DIR.is_dir():
        return demos

    for demo_dir in sorted(DEMOS_DIR.iterdir()):
        if not demo_dir.is_dir() or demo_dir.name.startswith("."):
            continue

        env_defaults = _parse_env_sh(demo_dir / "env.sh")
        state_file = demo_dir / ".state" / "agent_info.json"
        agent_info: dict[str, Any] = {}
        if state_file.is_file():
            try:
                agent_info = json.loads(state_file.read_text(encoding="utf-8"))
            except Exception:
                agent_info = {}

        scenarios_file = demo_dir / "scenarios.json"
        scenarios_meta: dict[str, Any] = {}
        if scenarios_file.is_file():
            try:
                scenarios_meta = json.loads(scenarios_file.read_text(encoding="utf-8"))
            except Exception:
                scenarios_meta = {}

        project_id = (
            agent_info.get("project")
            or env_defaults.get("PROJECT_ID")
            or os.environ.get("PROJECT_ID")
            or "cabral-governance-ai"
        )
        region = agent_info.get("region") or env_defaults.get("REGION") or "us-central1"
        engine_id = agent_info.get("engine_id") or ""
        re_name = agent_info.get("reasoning_engine_name") or ""
        if not engine_id and re_name:
            engine_id = re_name.split("/")[-1]

        eid_placeholder = engine_id or "{REASONING_ENGINE_ID}"
        base_re_url = (
            f"https://{region}-aiplatform.googleapis.com/v1/projects/{project_id}"
            f"/locations/{region}/reasoningEngines/{eid_placeholder}"
        )
        stream_query_url = f"{base_re_url}:streamQuery?alt=sse"
        query_url = f"{base_re_url}:query"
        adk_run_sse_url = (
            f"https://{region}-aiplatform.googleapis.com/reasoningEngines/v1/projects/{project_id}"
            f"/locations/{region}/reasoningEngines/{eid_placeholder}/api/run_sse"
        )
        adk_sessions_url = (
            f"https://{region}-aiplatform.googleapis.com/reasoningEngines/v1/projects/{project_id}"
            f"/locations/{region}/reasoningEngines/{eid_placeholder}/api/apps/{eid_placeholder}/users/{{user_id}}/sessions"
        )

        demos.append(
            {
                "id": demo_dir.name,
                "title": scenarios_meta.get("title") or demo_dir.name,
                "subtitle": scenarios_meta.get("subtitle") or "",
                "deployed": bool(engine_id),
                "project_id": project_id,
                "region": region,
                "engine_id": engine_id,
                "reasoning_engine_name": re_name,
                "agent_gateway_ingress": agent_info.get("agent_gateway_ingress")
                or agent_info.get("agent_gateway_egress")
                or env_defaults.get("AGW_URI", ""),
                "agent_gateway_egress": agent_info.get("agent_gateway_egress", ""),
                "mcp_url": agent_info.get("mcp_url", ""),
                "default_profile": scenarios_meta.get("default_profile", "vertex_stream_query"),
                "default_user_id": scenarios_meta.get("default_user_id", "cliente-demo"),
                "personas": scenarios_meta.get(
                    "personas",
                    [
                        {
                            "id": "cliente-demo",
                            "label": "cliente-demo (Usuário Padrão)",
                            "role": "Operador padrão de teste",
                        }
                    ],
                ),
                "endpoints": {
                    "vertex_stream_query": stream_query_url,
                    "vertex_query": query_url,
                    "adk_run_sse": adk_run_sse_url,
                    "adk_sessions_template": adk_sessions_url,
                },
                "scenarios": scenarios_meta.get("scenarios", []),
            }
        )
    return demos


# ==============================================================================
# Helper Functions for Wire Inspection & Stream Parsing
# ==============================================================================


def mask_headers(headers: dict[str, str]) -> dict[str, str]:
    masked: dict[str, str] = {}
    for k, v in headers.items():
        kl = k.lower()
        if kl in ("authorization", "x-forwarded-authorization", "proxy-authorization"):
            parts = v.split(" ", 1)
            if len(parts) == 2 and len(parts[1]) > 20:
                tok = parts[1]
                masked[k] = f"{parts[0]} {tok[:12]}...{tok[-6:]}"
            else:
                masked[k] = "Bearer ***"
        else:
            masked[k] = v
    return masked


def build_curl_command(method: str, url: str, headers: dict[str, str], body_obj: Any) -> str:
    lines = [f"curl -i -N -X {method} \\"]
    lines.append(f"  {shlex.quote(url)} \\")
    for k, v in headers.items():
        if k.lower() == "authorization" and v.startswith("Bearer "):
            lines.append('  -H "Authorization: Bearer $(gcloud auth print-access-token)" \\')
        else:
            lines.append(f"  -H {shlex.quote(f'{k}: {v}')} \\")
    if body_obj is not None:
        if isinstance(body_obj, (dict, list)):
            body_str = json.dumps(body_obj, ensure_ascii=False, indent=2)
        else:
            body_str = str(body_obj)
        lines.append(f"  -d {shlex.quote(body_str)}")
    else:
        lines[-1] = lines[-1].rstrip(" \\")
    return "\n".join(lines)


def inspect_chunk_object(obj: Any) -> dict[str, Any]:
    """Extracts text parts, functionCall, functionResponse, errors, and 3LO credential requests."""
    texts: list[str] = []
    tool_calls: list[dict[str, Any]] = []
    tool_responses: list[dict[str, Any]] = []
    auth_cred_req: dict[str, Any] | None = None
    error_info: dict[str, Any] | None = None

    items = obj if isinstance(obj, list) else [obj]
    for item in items:
        if not isinstance(item, dict):
            continue

        parts: list[Any] = []
        if isinstance(item.get("content"), dict) and isinstance(item["content"].get("parts"), list):
            parts.extend(item["content"]["parts"])
        if isinstance(item.get("output"), dict):
            out = item["output"]
            if isinstance(out.get("content"), dict) and isinstance(out["content"].get("parts"), list):
                parts.extend(out["content"]["parts"])
        if isinstance(item.get("candidates"), list):
            for cand in item["candidates"]:
                if isinstance(cand, dict) and isinstance(cand.get("content"), dict):
                    cparts = cand["content"].get("parts")
                    if isinstance(cparts, list):
                        parts.extend(cparts)

        for p in parts:
            if not isinstance(p, dict):
                continue
            if isinstance(p.get("text"), str) and p["text"]:
                texts.append(p["text"])
            if "function_call" in p or "functionCall" in p:
                fc = p.get("function_call") or p.get("functionCall")
                if isinstance(fc, dict):
                    tool_calls.append(fc)
                    if fc.get("name") == "adk_request_credential":
                        auth_cred_req = fc
            if "function_response" in p or "functionResponse" in p:
                fr = p.get("function_response") or p.get("functionResponse")
                if isinstance(fr, dict):
                    tool_responses.append(fr)

        if not parts:
            if isinstance(item.get("text"), str):
                texts.append(item["text"])
            elif isinstance(item.get("error"), dict):
                err_obj = item["error"]
                error_info = err_obj
                msg = err_obj.get("message") or str(err_obj)
                code = err_obj.get("code", "")
                status = err_obj.get("status", "")
                texts.append(f"🛑 [HTTP {code} {status}] {msg}".strip())
            elif isinstance(item.get("error_message"), str):
                code = item.get("error_code", "Error")
                error_info = {"code": code, "message": item["error_message"]}
                texts.append(f"🛑 [{code}] {item['error_message']}")

    return {
        "text": "".join(texts),
        "tool_calls": tool_calls,
        "tool_responses": tool_responses,
        "auth_credential_request": auth_cred_req,
        "error_info": error_info,
    }


def extract_trailing_error_from_raw(raw_full: str) -> dict[str, Any] | None:
    """
    When a streaming response is aborted mid-stream by Agent Gateway / Model Armor (e.g., on
    SANITIZE_MODEL_RESPONSE), a multi-line JSON `{"error": {"code": 403, "message": ...}}` is
    appended after the single-line JSON chunks. This helper extracts it cleanly.
    """
    idx = raw_full.rfind('{\n  "error":')
    if idx == -1:
        idx = raw_full.rfind('{"error":')
    if idx != -1:
        tail = raw_full[idx:].strip()
        try:
            parsed = json.loads(tail)
            if isinstance(parsed, dict) and isinstance(parsed.get("error"), dict):
                return parsed["error"]
        except Exception:
            pass
    return None


def detect_governance_verdict(
    status_code: int,
    raw_body: str,
    consolidated_text: str,
    tool_responses: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    combined = f"{raw_body}\n{consolidated_text}"

    # 1. Model Armor Request / Prompt Block (Ingress)
    if "Prompt violates content security" in combined:
        return {
            "code": "MODEL_ARMOR_PROMPT_BLOCK",
            "stage": "INGRESS_REQUEST",
            "label": "🛡️ BLOQUEADO NO INGRESS (Model Armor Request Guardrail — Prompt Injection)",
            "severity": "danger",
            "leak_warning": None,
        }

    # 2. Model Armor Response / DLP Block (Egress / Output Authorization)
    if "Response violates content security" in combined:
        # Check if an earlier function_response chunk already streamed raw data to the client
        leaked_in_tool = False
        if tool_responses:
            for tr in tool_responses:
                tr_str = json.dumps(tr, ensure_ascii=False)
                if re.search(r"\b\d{3}-\d{2}-\d{4}\b", tr_str):
                    leaked_in_tool = True
                    break
        return {
            "code": "MODEL_ARMOR_RESPONSE_BLOCK",
            "stage": "EGRESS_RESPONSE",
            "label": "🛡️ RESPOSTA DO LLM BARRADA PELO MODEL ARMOR + DLP (HTTP 403 Response Authz)",
            "severity": "info" if not leaked_in_tool else "warning",
            "leak_warning": (
                "⚠️ Achado de Auditoria SSE: O Agent Gateway (CONTENT_AUTHZ) bloqueou com sucesso a resposta final do LLM (403) ao detectar SSN via DLP, porém o Reasoning Engine já havia transmitido o payload intermediário de `function_response` da tool no stream SSE. Veja a aba 'Response' / 'SSE Timeline'."
                if leaked_in_tool
                else None
            ),
        }

    if "Model Armor" in combined:
        return {
            "code": "MODEL_ARMOR_BLOCK",
            "stage": "GATEWAY",
            "label": "🛡️ BLOQUEADO PELO MODEL ARMOR",
            "severity": "danger",
            "leak_warning": None,
        }

    # 3. Agent Gateway Egress (AGENT_TO_ANYWHERE) — L7 MCP Tool Block or Anti-Exfiltration Block
    blocked_tools: list[str] = []
    has_mcp_l7_block = False
    has_egress_exfil_block = False

    for tr in tool_responses or []:
        tr_name = str(tr.get("name") or "")
        tr_blob = json.dumps(tr, ensure_ascii=False)
        is_mcp_err = (
            ("MCP tool execution" in tr_blob or "MCP session" in tr_blob)
            and ("403" in tr_blob or "Forbidden" in tr_blob)
        )
        is_exfil_err = (
            "Egress request is not authorized" in tr_blob
            or "BLOQUEADO PELO AGENT GATEWAY EGRESS" in tr_blob
            or "BLOQUEADO NA SAÍDA PELO AGENT GATEWAY" in tr_blob
            or "CONEXÃO EXTERNA BLOQUEADA PELO PERÍMETRO DE EGRESS" in tr_blob
        )
        if is_mcp_err or is_exfil_err:
            if tr_name and tr_name not in blocked_tools:
                blocked_tools.append(tr_name)
            if is_mcp_err:
                has_mcp_l7_block = True
            if is_exfil_err:
                has_egress_exfil_block = True

    if (
        has_mcp_l7_block
        or has_egress_exfil_block
        or "Egress request is not authorized" in combined
        or "BLOQUEADO PELO AGENT GATEWAY EGRESS" in combined
        or "BLOQUEADO NA SAÍDA PELO AGENT GATEWAY" in combined
    ):
        return {
            "code": "AGW_EGRESS_MCP_BLOCK" if has_mcp_l7_block else "AGW_EGRESS_EXFIL_BLOCK",
            "stage": "EGRESS_GATEWAY",
            "egress_status_code": 403,
            "blocked_tools": blocked_tools,
            "label": (
                "🛑 BLOQUEADO NO EGRESS L7 (Agent Gateway + IAP — Tool MCP 403)"
                if has_mcp_l7_block
                else "🛑 BLOQUEADO NO EGRESS ZERO-TRUST (Agent Gateway — Exfiltração 403)"
            ),
            "severity": "danger",
            "leak_warning": None,
        }

    if status_code >= 400 or '"error_code"' in raw_body or '"error_message"' in raw_body:
        label_code = f"HTTP {status_code}" if status_code >= 400 else "SSE STREAM ERROR"
        return {
            "code": f"ERROR_{status_code}",
            "stage": "TRANSPORT",
            "label": f"⚠️ ERRO DE EXECUÇÃO ({label_code})",
            "severity": "warning" if 400 <= status_code < 500 else "danger",
            "leak_warning": None,
        }

    if (
        "US_SOCIAL_SECURITY_NUMBER" in combined
        or "[REDACTED]" in combined
        or "redigido" in combined.lower()
        or "***-**-" in combined
    ):
        return {
            "code": "DLP_PROTECTED",
            "stage": "EGRESS_RESPONSE",
            "label": "🔒 PROTEÇÃO DLP / PII ATIVA (Dados Sensíveis Redigidos)",
            "severity": "info",
            "leak_warning": None,
        }

    return {
        "code": "ALLOW",
        "stage": "COMPLETE",
        "label": "✅ PERMITIDO (Tráfego Limpo)",
        "severity": "success",
        "leak_warning": None,
    }


# ==============================================================================
# FastAPI Application & Routes
# ==============================================================================

app = FastAPI(
    title="Agent Console & Wire Inspector",
    description="Lightweight Postman + Chat simulator for Agent Platform Governance Demos",
    version="0.4.0",
)


@app.middleware("http")
async def disable_static_cache(request: Request, call_next):
    response = await call_next(request)
    if request.url.path in ("/", "/index.html", "/app.js", "/styles.css"):
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    return response


@app.exception_handler(Exception)
async def global_json_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Guarantees every unexpected backend error returns structured JSON instead of plain-text 'Internal Server Error'."""
    return JSONResponse(
        status_code=500,
        content={
            "ok": False,
            "error": str(exc),
            "error_type": type(exc).__name__,
            "detail": f"{type(exc).__name__}: {exc}",
        },
    )


@app.get("/preload.js")
async def serve_preload_js() -> Response:
    """Serves the Jetski Sidecar preload.js bridge when embedded as a UI Plugin AuxPane."""
    if JETSKI_PRELOAD_PATH.is_file():
        content = JETSKI_PRELOAD_PATH.read_text(encoding="utf-8", errors="ignore")
        return Response(content=content, media_type="application/javascript")
    fallback_js = "window.sidecar = window.sidecar || null;"
    return Response(content=fallback_js, media_type="application/javascript")


@app.post("/_sidecar/get-conversation-metadata")
async def sidecar_conversation_metadata(request: Request) -> dict[str, Any]:
    """Stub for Jetski preload.js metadata handshake so it never returns 405."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    conv_id = body.get("conversationId") or os.environ.get("ANTIGRAVITY_CONVERSATION_ID") or ""
    return {
        "response": {
            "conversationMetadata": {
                "metadata": {
                    "conversationId": conv_id,
                    "projectId": os.environ.get("PROJECT_ID", "cabral-governance-ai"),
                }
            }
        }
    }


@app.get("/api/health")
async def health() -> dict[str, Any]:
    return {"status": "ok", "time_brt": now_brt_short()}


@app.get("/api/demos")
async def get_demos() -> dict[str, Any]:
    return {
        "demos": discover_demos(),
        "auth": AUTH_MANAGER.status_summary(),
        "time_brt": now_brt_short(),
    }


@app.get("/api/auth/status")
async def auth_status() -> dict[str, Any]:
    return AUTH_MANAGER.status_summary()


@app.post("/api/auth/refresh")
async def auth_refresh() -> dict[str, Any]:
    AUTH_MANAGER.get_token(force_refresh=True)
    return AUTH_MANAGER.status_summary()


@app.post("/api/auth/config")
async def auth_config(request: Request) -> dict[str, Any]:
    body = await request.json()
    if "gcloud_config" in body:
        cfg = str(body["gcloud_config"]).strip()
        if cfg.lower() in FORBIDDEN_GCLOUD_CONFIGS:
            raise HTTPException(
                status_code=403,
                detail=f"A configuração '{cfg}' é bloqueada por regra de segurança.",
            )
        if cfg:
            AUTH_MANAGER.gcloud_config = cfg
    if "token_type" in body and body["token_type"] in ("access", "identity", "manual", "none"):
        AUTH_MANAGER.token_type = body["token_type"]
    if "manual_token" in body:
        AUTH_MANAGER.manual_token = str(body["manual_token"]).strip()
    if "delegated_context" in body and isinstance(body["delegated_context"], dict):
        AUTH_MANAGER.delegated_context.update(body["delegated_context"])
    return AUTH_MANAGER.status_summary()


@app.get("/oauth/callback", response_class=HTMLResponse)
async def oauth_callback(request: Request) -> HTMLResponse:
    params = dict(request.query_params)
    event_record = {
        "received_at_brt": now_brt_short(),
        "query_params": params,
    }
    AUTH_MANAGER.delegated_context["last_callback_event"] = event_record
    payload_json = json.dumps(event_record)
    html = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head><meta charset="utf-8"><title>OAuth Callback - Agent Console</title>
<style>body{{background:#0f172a;color:#e2e8f0;font-family:system-ui;padding:2rem;text-align:center;}}
code{{background:#1e293b;padding:0.2rem 0.5rem;border-radius:4px;}}</style></head>
<body>
  <h2>✅ Consentimento OAuth Recebido</h2>
  <p>Retornando os parâmetros para o Agent Console...</p>
  <pre><code>{json.dumps(params, indent=2)}</code></pre>
  <script>
    if (window.opener) {{
      window.opener.postMessage({{ type: "agent_console_oauth_callback", data: {payload_json} }}, "*");
      setTimeout(() => window.close(), 1200);
    }}
  </script>
</body></html>"""
    return HTMLResponse(content=html)


# ==============================================================================
# Dual-Path Session Management (Vertex `:query` & ADK `/sessions`)
# ==============================================================================


def _resolve_session_urls(req_data: dict[str, Any]) -> tuple[str, str, str]:
    """
    Resolves (vertex_query_url, sessions_url, project_id) from request payload,
    current endpoint_url, or server-side demo discovery fallback.
    """
    demo_id = str(req_data.get("demo_id") or "").strip()
    endpoint_url = str(req_data.get("endpoint_url") or "").strip()
    project_id = str(req_data.get("project_id") or "").strip()
    vertex_query_url = str(req_data.get("vertex_query_url") or "").strip()
    sessions_url = str(req_data.get("sessions_url") or "").strip()

    # 1. Derive vertex_query_url directly from endpoint_url if it points to a Reasoning Engine
    if not vertex_query_url and ":streamQuery" in endpoint_url:
        vertex_query_url = endpoint_url.split(":streamQuery")[0] + ":query"

    # 2. Fallback to server-side demo discovery if any field is still missing
    if not vertex_query_url or not sessions_url or not project_id:
        demos = discover_demos()
        matched_demo = None
        if demo_id:
            matched_demo = next((d for d in demos if d.get("id") == demo_id), None)
        if not matched_demo:
            matched_demo = next((d for d in demos if d.get("deployed")), None) or (
                demos[0] if demos else None
            )
        if matched_demo:
            eps = matched_demo.get("endpoints") or {}
            if not vertex_query_url:
                vertex_query_url = str(eps.get("vertex_query") or "")
            if not sessions_url:
                sessions_url = str(eps.get("adk_sessions_template") or "")
            if not project_id:
                project_id = str(matched_demo.get("project_id") or "")

    return vertex_query_url, sessions_url, project_id


@app.post("/api/sessions/create")
async def create_session_endpoint(request: Request) -> JSONResponse:
    """
    Creates a server-side session across either:
    1. Vertex AI Reasoning Engine native `:query` (`{"class_method": "create_session", "input": {"user_id": ...}}`)
    2. ADK Passthrough HTTP (`/apps/{id}/users/{u}/sessions` with `{}`)
    Returns the new session_id AND the exact HTTP wire capture for inspection.
    """
    req_data = await request.json()
    profile = str(req_data.get("profile", "vertex_stream_query")).strip()
    user_id = str(req_data.get("user_id", "cliente-demo")).strip() or "cliente-demo"
    vertex_query_url, sessions_url, project_id = _resolve_session_urls(req_data)

    tok_info = AUTH_MANAGER.get_token()
    headers: dict[str, str] = {"Content-Type": "application/json"}
    if tok_info.get("token"):
        headers["Authorization"] = f"Bearer {tok_info['token']}"
    if project_id:
        headers["x-goog-user-project"] = project_id

    if profile == "adk_run_sse":
        target_url = sessions_url.replace("{user_id}", user_id)
        body_payload: dict[str, Any] = {}
        mechanism = "ADK Passthrough (/api/apps/.../sessions)"
    else:
        target_url = vertex_query_url
        body_payload = {
            "class_method": "create_session",
            "input": {"user_id": user_id},
        }
        mechanism = "Vertex Agent Runtime (:query class_method=create_session)"

    masked = mask_headers(headers)
    if not target_url or not target_url.startswith("http"):
        return JSONResponse(
            status_code=400,
            content={
                "ok": False,
                "session_id": "",
                "mechanism": mechanism,
                "status_code": 400,
                "elapsed_ms": 0.0,
                "error": "URL do endpoint :query não encontrada para criar sessão.",
                "wire": {
                    "request": {
                        "timestamp_brt": now_brt_str(),
                        "method": "POST",
                        "url": target_url or "(vazio)",
                        "headers": masked,
                        "body": body_payload,
                        "curl": "",
                    },
                    "response": {
                        "status_code": 400,
                        "headers": {},
                        "body": {"error": "URL do endpoint :query não encontrada."},
                    },
                },
            },
        )

    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(target_url, headers=headers, json=body_payload)
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        status_code = resp.status_code
        resp_headers = dict(resp.headers)
        try:
            resp_json = resp.json()
        except Exception:
            resp_json = {"raw": resp.text}
    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        status_code = 502
        resp_headers = {}
        resp_json = {"error": f"{type(exc).__name__}: {exc}"}

    session_id = ""
    if isinstance(resp_json, dict):
        out_obj = resp_json.get("output")
        if isinstance(out_obj, dict):
            session_id = str(out_obj.get("id") or "")
        if not session_id:
            raw_id = resp_json.get("id")
            raw_name = resp_json.get("name")
            if raw_id:
                session_id = str(raw_id)
            elif isinstance(raw_name, str) and raw_name:
                session_id = raw_name.split("/")[-1]

    return JSONResponse(
        {
            "ok": status_code < 400 and bool(session_id),
            "session_id": session_id,
            "mechanism": mechanism,
            "status_code": status_code,
            "elapsed_ms": elapsed_ms,
            "wire": {
                "request": {
                    "timestamp_brt": now_brt_str(),
                    "method": "POST",
                    "url": target_url,
                    "headers": masked,
                    "body": body_payload,
                    "curl": build_curl_command("POST", target_url, masked, body_payload),
                },
                "response": {
                    "status_code": status_code,
                    "headers": resp_headers,
                    "body": resp_json,
                },
            },
        }
    )


@app.post("/api/sessions/reset")
async def reset_session_endpoint(request: Request) -> JSONResponse:
    """
    Deletes an active session on the Agent Runtime (if session_id is present) and optionally
    creates a brand-new session or returns to stateless/ephemeral mode.
    """
    req_data = await request.json()
    profile = str(req_data.get("profile", "vertex_stream_query")).strip()
    user_id = str(req_data.get("user_id", "cliente-demo")).strip() or "cliente-demo"
    old_session_id = str(req_data.get("session_id", "")).strip()
    create_new = bool(req_data.get("create_new", False))
    vertex_query_url, _, project_id = _resolve_session_urls(req_data)

    tok_info = AUTH_MANAGER.get_token()
    headers: dict[str, str] = {"Content-Type": "application/json"}
    if tok_info.get("token"):
        headers["Authorization"] = f"Bearer {tok_info['token']}"
    if project_id:
        headers["x-goog-user-project"] = project_id

    delete_wire = None
    if old_session_id and vertex_query_url and profile == "vertex_stream_query":
        del_payload = {
            "class_method": "delete_session",
            "input": {"user_id": user_id, "session_id": old_session_id},
        }
        t0 = time.perf_counter()
        masked = mask_headers(headers)
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.post(vertex_query_url, headers=headers, json=del_payload)
            elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
            status_code = resp.status_code
            resp_headers = dict(resp.headers)
            try:
                del_json = resp.json()
            except Exception:
                del_json = {"raw": resp.text}
        except Exception as exc:
            elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
            status_code = 502
            resp_headers = {}
            del_json = {"error": f"{type(exc).__name__}: {exc}"}

        delete_wire = {
            "status_code": status_code,
            "elapsed_ms": elapsed_ms,
            "request": {
                "timestamp_brt": now_brt_str(),
                "method": "POST",
                "url": vertex_query_url,
                "headers": masked,
                "body": del_payload,
                "curl": build_curl_command("POST", vertex_query_url, masked, del_payload),
            },
            "response": {
                "status_code": status_code,
                "headers": resp_headers,
                "body": del_json,
            },
        }

    if create_new:
        return await create_session_endpoint(request)

    return JSONResponse(
        {
            "ok": True,
            "old_session_id": old_session_id,
            "session_id": "",
            "mode": "ephemeral",
            "delete_wire": delete_wire,
        }
    )


# ==============================================================================
# Transparent Streaming Wire Proxy
# ==============================================================================


@app.post("/api/proxy/stream", response_model=None)
async def proxy_stream(request: Request) -> StreamingResponse:
    req = await request.json()
    method = str(req.get("method", "POST")).upper()
    target_url = str(req.get("url", "")).strip()
    custom_headers: dict[str, str] = dict(req.get("headers") or {})
    body_payload = req.get("body")
    project_id = str(req.get("project_id", "")).strip()
    use_auth = req.get("use_auth", True)

    if not target_url:
        raise HTTPException(status_code=400, detail="URL do endpoint não informada.")

    wire_headers: dict[str, str] = {
        "Content-Type": "application/json",
    }
    if use_auth and AUTH_MANAGER.token_type != "none":
        tok_info = AUTH_MANAGER.get_token()
        if tok_info.get("token"):
            wire_headers["Authorization"] = f"Bearer {tok_info['token']}"

    if project_id and "x-goog-user-project" not in {k.lower() for k in custom_headers}:
        wire_headers["x-goog-user-project"] = project_id

    del_ctx = AUTH_MANAGER.delegated_context
    if del_ctx.get("enabled") and del_ctx.get("subject_token"):
        hdr_name = del_ctx.get("header_name") or "X-Forwarded-Authorization"
        subj_tok = del_ctx["subject_token"]
        if not subj_tok.lower().startswith("bearer "):
            subj_tok = f"Bearer {subj_tok}"
        wire_headers[hdr_name] = subj_tok

    for k, v in custom_headers.items():
        if v is not None and str(v).strip() != "":
            if k.lower() == "authorization" and "..." in str(v):
                continue
            wire_headers[k] = str(v)

    masked_req_headers = mask_headers(wire_headers)
    curl_cmd = build_curl_command(method, target_url, masked_req_headers, body_payload)

    async def event_generator():
        t_start = time.perf_counter()

        yield json.dumps(
            {
                "type": "wire_request",
                "timestamp_brt": now_brt_str(),
                "method": method,
                "url": target_url,
                "headers": masked_req_headers,
                "body": body_payload,
                "curl": curl_cmd,
            },
            ensure_ascii=False,
        ) + "\n"

        ttft_ms: float | None = None
        chunk_index = 0
        raw_lines: list[str] = []
        consolidated_texts: list[str] = []
        all_tool_calls: list[dict[str, Any]] = []
        all_tool_responses: list[dict[str, Any]] = []
        stream_error_obj: dict[str, Any] | None = None

        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=15.0)) as client:
                req_kwargs: dict[str, Any] = {"headers": wire_headers}
                if body_payload is not None and method not in ("GET", "HEAD"):
                    if isinstance(body_payload, (dict, list)):
                        req_kwargs["json"] = body_payload
                    else:
                        req_kwargs["content"] = str(body_payload).encode("utf-8")

                async with client.stream(method, target_url, **req_kwargs) as resp:
                    t_headers = time.perf_counter()
                    ttft_ms = round((t_headers - t_start) * 1000, 1)
                    resp_headers = dict(resp.headers)

                    yield json.dumps(
                        {
                            "type": "wire_response_start",
                            "timestamp_brt": now_brt_str(),
                            "status_code": resp.status_code,
                            "reason_phrase": resp.reason_phrase,
                            "headers": resp_headers,
                            "ttft_ms": ttft_ms,
                        },
                        ensure_ascii=False,
                    ) + "\n"

                    # Buffer for multi-line JSON blocks (e.g. trailing 403 error from Agent Gateway)
                    multiline_buf: list[str] = []

                    async for line in resp.aiter_lines():
                        if line == "":
                            continue
                        raw_lines.append(line)
                        chunk_elapsed = round((time.perf_counter() - t_start) * 1000, 1)

                        clean_str = line
                        is_sse_data = False
                        if line.startswith("data:"):
                            is_sse_data = True
                            clean_str = line[5:].strip()
                        elif line.startswith("event:"):
                            chunk_index += 1
                            yield json.dumps(
                                {
                                    "type": "wire_chunk",
                                    "index": chunk_index,
                                    "timestamp_brt": now_brt_str(),
                                    "elapsed_ms": chunk_elapsed,
                                    "raw_line": line,
                                    "parsed_json": None,
                                    "extracted_text": "",
                                    "tool_calls": [],
                                    "tool_responses": [],
                                    "auth_credential_request": None,
                                },
                                ensure_ascii=False,
                            ) + "\n"
                            continue

                        parsed_json: Any = None
                        extracted = {
                            "text": "",
                            "tool_calls": [],
                            "tool_responses": [],
                            "auth_credential_request": None,
                            "error_info": None,
                        }
                        if clean_str and clean_str != "[DONE]":
                            try:
                                parsed_json = json.loads(clean_str)
                                extracted = inspect_chunk_object(parsed_json)
                                multiline_buf.clear()
                            except Exception:
                                # Could be part of a multi-line JSON block (such as trailing Gateway 403 error)
                                multiline_buf.append(clean_str)
                                joined_candidate = "\n".join(multiline_buf)
                                try:
                                    parsed_json = json.loads(joined_candidate)
                                    extracted = inspect_chunk_object(parsed_json)
                                    clean_str = joined_candidate
                                    line = joined_candidate
                                    multiline_buf.clear()
                                except Exception:
                                    # Wait until complete JSON object is accumulated
                                    continue

                        chunk_index += 1
                        if extracted["text"]:
                            consolidated_texts.append(extracted["text"])
                        if extracted["tool_calls"]:
                            all_tool_calls.extend(extracted["tool_calls"])
                        if extracted["tool_responses"]:
                            all_tool_responses.extend(extracted["tool_responses"])
                        if extracted.get("error_info"):
                            stream_error_obj = extracted["error_info"]

                        yield json.dumps(
                            {
                                "type": "wire_chunk",
                                "index": chunk_index,
                                "timestamp_brt": now_brt_str(),
                                "elapsed_ms": chunk_elapsed,
                                "is_sse": is_sse_data,
                                "raw_line": line,
                                "parsed_json": parsed_json,
                                "extracted_text": extracted["text"],
                                "tool_calls": extracted["tool_calls"],
                                "tool_responses": extracted["tool_responses"],
                                "auth_credential_request": extracted["auth_credential_request"],
                                "error_info": extracted.get("error_info"),
                            },
                            ensure_ascii=False,
                        ) + "\n"

                    raw_full = "\n".join(raw_lines)

                    # Check for trailing multi-line error if not already parsed
                    if not stream_error_obj:
                        stream_error_obj = extract_trailing_error_from_raw(raw_full)
                        if stream_error_obj and not consolidated_texts:
                            code = stream_error_obj.get("code", "")
                            status = stream_error_obj.get("status", "")
                            msg = stream_error_obj.get("message", "")
                            consolidated_texts.append(f"🛑 [HTTP {code} {status}] {msg}".strip())

                    if not consolidated_texts and raw_full.strip():
                        try:
                            whole_json = json.loads(raw_full)
                            ext_whole = inspect_chunk_object(whole_json)
                            if ext_whole["text"]:
                                consolidated_texts.append(ext_whole["text"])
                            if ext_whole["tool_calls"]:
                                all_tool_calls.extend(ext_whole["tool_calls"])
                            if ext_whole["tool_responses"]:
                                all_tool_responses.extend(ext_whole["tool_responses"])
                        except Exception:
                            if resp.status_code >= 400:
                                consolidated_texts.append(raw_full.strip())

                    total_ms = round((time.perf_counter() - t_start) * 1000, 1)
                    final_text = "\n".join(consolidated_texts).strip()
                    verdict = detect_governance_verdict(
                        resp.status_code,
                        raw_full,
                        final_text,
                        all_tool_responses,
                    )

                    yield json.dumps(
                        {
                            "type": "wire_complete",
                            "timestamp_brt": now_brt_str(),
                            "status_code": resp.status_code,
                            "reason_phrase": resp.reason_phrase,
                            "ttft_ms": ttft_ms,
                            "total_ms": total_ms,
                            "chunk_count": chunk_index,
                            "raw_body": raw_full,
                            "consolidated_text": final_text,
                            "tool_calls": all_tool_calls,
                            "tool_responses": all_tool_responses,
                            "stream_error": stream_error_obj,
                            "governance_verdict": verdict,
                        },
                        ensure_ascii=False,
                    ) + "\n"

        except Exception as exc:
            total_ms = round((time.perf_counter() - t_start) * 1000, 1)
            yield json.dumps(
                {
                    "type": "wire_error",
                    "timestamp_brt": now_brt_str(),
                    "total_ms": total_ms,
                    "error": str(exc),
                },
                ensure_ascii=False,
            ) + "\n"

    return StreamingResponse(event_generator(), media_type="application/x-ndjson")


STATIC_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")


if __name__ == "__main__":
    import argparse
    import uvicorn

    default_port = int(os.environ.get("ANTIGRAVITY_SIDECAR_WEB_PORT") or os.environ.get("PORT") or "8090")
    parser = argparse.ArgumentParser(description="Start Agent Console & Wire Inspector")
    parser.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"), help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=default_port, help="Bind port")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload for development")
    args = parser.parse_args()

    print("=" * 72)
    print(f"🚀 Agent Console & Wire Inspector iniciado em http://{args.host}:{args.port}")
    print(f"🕒 Horário local: {now_brt_short()}")
    print("=" * 72)
    uvicorn.run(
        "server:app",
        host=args.host,
        port=args.port,
        reload=args.reload,
        reload_dirs=[str(HERE)] if args.reload else None,
        app_dir=str(HERE),
    )
