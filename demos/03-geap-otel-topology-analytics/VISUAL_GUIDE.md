# Guia Visual de Arquitetura: OTel Distribuído, Topologia Multi-Agente & BigQuery Analytics

Este documento explica visual e didaticamente o funcionamento interno da **Demo 03 (`03-geap-otel-topology-analytics`)**, partindo da visão executiva (C4 Nível 1) até a inspeção byte a byte dos cabeçalhos W3C `traceparent`, envelopes JSON-RPC MCP/A2A e registros do **BigQuery Storage Write API**.

---

## 🗺️ 1. Arquitetura Progressiva em 3 Níveis (C4 Zoom-In)

### Nível 1 — Contexto do Sistema (Quem Interage e Onde Chega o Valor)

```mermaid
flowchart LR
    Operator["Engenheiro SRE / Analista FinOps\n(Agent Console ou CLI)"]
    System["Malha Multi-Agente Observavel\n(GEAP: Reasoning Engine + Cloud Run A2A/MCP)"]
    TraceUI["Cloud Trace & Agent Topology\n(Waterfall Ponta a Ponta + Grafo SRE)"]
    BQUI["BigQuery Agent Analytics\n(FinOps de Tokens, TTFT & Proveniencia)"]

    Operator -->|"1. Consulta Pedido / Lote + traceparent"| System
    System -->|"2. Spans OTLP Costurados (3 Nos)"| TraceUI
    System -->|"3. Eventos Estruturados em Sub-Segundo"| BQUI
    TraceUI -.->|"Join pelo mesmo trace_id"| BQUI
```

### Nível 2 — Contêineres, Identidades SPIFFE e Fluxo entre Runtimes

```mermaid
flowchart TD
    subgraph Client["Camada de Canal"]
        UI["Agent Console & Wire Inspector\ntools/agent-console (Gera traceparent W3C)"]
    end

    subgraph VertexRuntime["Vertex AI Agent Runtime (us-central1)"]
        RE["No 1: o11y-agent-orchestrator\nADK LlmAgent (gemini-3.8-flash @ global)\nIdentidade: AGENT_IDENTITY (SPIFFE)"]
        BQP["BigQueryAgentAnalyticsPlugin\nbatch_size=1 | flush_on_run_end=True"]
        RE --- BQP
    end

    subgraph CloudRunMesh["Cloud Run Agentic Mesh (us-central1, Zero-VPC + OIDC)"]
        MCP["No 3: o11y-mcp-erp-ops\nFastMCP Streamable HTTP\n--functional-type=mcp-server\nSA: sa-o11y-mcp-runtime"]
        A2A["No 2: o11y-a2a-sla-risk\nADK to_a2a() Specialist (gemini-3.8-flash @ global)\n--functional-type=agent\nIdentidade: SPIFFE agent-identity"]
    end

    subgraph DataAndO11y[" Telemetria, Storage & Analytics"]
        TelAPI["telemetry.googleapis.com/v1/traces\n(OTLP HTTP Exporter)"]
        GCS["gs://...-o11y-telemetry/completions\n(Hook GenAI .jsonl + Offload Multimodal)"]
        BQ["BigQuery: geap_o11y_demo03\nagent_events + v_llm_response + v_tool_completed"]
    end

    UI -->|"POST :streamQuery?alt=sse\ntraceparent: 00-T-S0-01"| RE
    RE -->|"POST /mcp (Bearer OIDC)\ntraceparent: 00-T-S1-01"| MCP
    RE -->|"POST / (A2A JSON-RPC + Bearer OIDC)\ntraceparent: 00-T-S2-01"| A2A
    RE -.->|"OTLP Spans (NO_CONTENT)"| TelAPI
    MCP -.->|"OTLP Child Spans (DB / Lock)"| TelAPI
    A2A -.->|"OTLP Child Spans (LLM / Multa)"| TelAPI
    RE -.->|"JSONL Prompts & Completions"| GCS
    BQP ==>|"Storage Write API (gRPC)"| BQ
```

### Nível 3 — Pipeline Interno de Contexto e Plugins no Orquestrador (`src/agent/agent.py`)

```mermaid
flowchart LR
    In["SSE Request\n(traceparent T)"] --> Runner["ADK Runner\n(Span Raiz invoke_agent)"]
    Runner --> LLM1["GlobalGemini\n(gemini-3.8-flash @ global)"]
    LLM1 --> ToolMCP["McpToolset\nget_mcp_auth_and_trace_headers()"]
    LLM1 --> ToolA2A["AgentTool -> RemoteA2aAgent\n_a2a_before_request()"]
    ToolMCP -->|"propagate.inject(headers)\n+ IDTokenCredentials"| OutMCP["Cloud Run FastMCP"]
    ToolA2A -->|"propagate.inject(headers)\n+ IDTokenCredentials"| OutA2A["Cloud Run A2A"]
    Runner --> Plugin["BigQueryAgentAnalyticsPlugin\n_get_tool_origin() -> MCP | A2A"]
```

---

## 🔄 2. Sequence Walk Ponta a Ponta (Ato 2 — Diagnóstico de Lock + Multa A2A)

Observe como o mesmo `trace_id` (`4bf92f35...`) atravessa os 3 serviços e aterrissa simultaneamente no Cloud Trace e no BigQuery:

```mermaid
sequenceDiagram
    autonumber
    participant C as Agent Console
    participant O as No 1: Orchestrator (Reasoning Engine)
    participant M as No 3: FastMCP ERP (Cloud Run)
    participant A as No 2: Specialist A2A (Cloud Run)
    participant T as Cloud Trace (telemetry.googleapis.com)
    participant B as BigQuery (Storage Write API)

    C->>O: POST :streamQuery?alt=sse (traceparent 00-TraceA-Span1-01)
    Note over O: Cria span invoke_agent sob TraceA
    O->>M: POST /mcp tools/call conciliar_lote_logistico (traceparent 00-TraceA-Span2-01)
    Note over M: Extrai TraceA e executa span erp.legacy_wms_lock_contention (1350ms ERROR)
    M-->>T: Exporta spans mcp.server + erp.legacy_wms_lock_contention (TraceA)
    M-->>O: JSON PG_LOCK_TIMEOUT_55P03 (BioFarma R$ 410.000, atraso 6h)
    O->>B: Enfileira evento TOOL_COMPLETED (tool_origin=MCP, trace_id=TraceA)
    O->>A: POST / A2A message/send (traceparent 00-TraceA-Span3-01)
    Note over A: Extrai TraceA, roda gemini-3.8-flash + sla.penalty_matrix_eval
    A-->>T: Exporta spans a2a.specialist + sla.penalty_matrix_eval (TraceA)
    A-->>O: Parecer A2A: Multa Cadeia Fria R$ 46.125,00 vs Frete R$ 6.800,00
    O->>B: Enfileira TOOL_COMPLETED (tool_origin=A2A) + LLM_RESPONSE (tokens, TTFT)
    O-->>T: Exporta spans do Orquestrador + upload .jsonl para GCS
    O-->>C: Resposta SSE consolidada + Link 1-clique Cloud Trace (TraceA)
```

---

## 📦 3. Anatomia no Fio (Packet & Schema Walk)

### 3.1 Cabeçalho W3C `traceparent` (RFC W3C Trace Context)

```text
  traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
               ┬─ ────────────────┬─────────────── ────────┬─────── ┬─
               │                  │                        │        └── trace-flags (01 = sampled)
               │                  │                        └─────────── parent-id / span_id (8 bytes / 16 hex)
               │                  │                                     Muda a cada salto (Console -> RE -> MCP/A2A)
               │                  └──────────────────────────────────── trace-id (16 bytes / 32 hex)
               │                                                        IDENTICO nos 3 runtimes e na coluna trace_id do BQ!
               └─────────────────────────────────────────────────────── version (00)
```

### 3.2 Propagação Dupla para o Servidor MCP (HTTP Header + Envelope JSON-RPC `_meta`)

```text
POST /mcp HTTP/1.1
Host: o11y-mcp-erp-ops-933727338685.us-central1.run.app
Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6...   <-- OIDC ID Token (sa-o11y-cr-invoker)
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-8a11c09e4421b901-01  <-- Canal 1: HTTP Header

{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "conciliar_lote_logistico",
    "arguments": { "lote_id": "LOTE-LOCK-503" },
    "_meta": {
      "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-8a11c09e4421b901-01"  <-- Canal 2: MCP _meta
    }
  }
}
```

### 3.3 Correlação Exata entre Cloud Trace (`_AllSpans`) e BigQuery (`agent_events`)

```text
┌─────────────────────────────────────────────┐       ┌──────────────────────────────────────────────────┐
│ Cloud Trace (_AllSpans / Explorer)          │       │ BigQuery (geap_o11y_demo03.agent_events / views) │
├─────────────────────────────────────────────┤       ├──────────────────────────────────────────────────┤
│ trace_id: "4bf92f3577b34da6a3ce929d0e0e4736"│◄─────►│ trace_id:    "4bf92f3577b34da6a3ce929d0e0e4736"  │
│ ├─ invoke_agent finops_ops_orchestrator     │       │ ├─ LLM_RESPONSE (prompt=912, out=184, ttft=420ms)│
│ │  ├─ mcp.server/tools/call                 │       │ ├─ TOOL_COMPLETED                              │
│ │  │  └─ erp.legacy_wms_lock_contention     │       │ │   tool_name="conciliar_lote_logistico"       │
│ │  │     (1350ms, StatusCode.ERROR, 55P03)  │       │ │   tool_origin="MCP"  | total_ms=1492         │
│ │  └─ a2a.specialist/POST /                 │       │ └─ TOOL_COMPLETED                              │
│ │     ├─ generate_content gemini-3.8-flash  │       │     tool_name="sla_risk_specialist"            │
│ │     └─ sla.penalty_matrix_eval            │       │     tool_origin="A2A"  | total_ms=1810         │
└─────────────────────────────────────────────┘       └──────────────────────────────────────────────────┘
```

### 3.4 Do Span Físico ao Grafo de Topologia (`Cloud Trace` + `App Hub` + `App Topology`)

```text
1. Spans OTLP brutos chegam em telemetry.googleapis.com com o mesmo trace_id:
   Span Pai (Reasoning Engine) : cloud.resource_id = "//aiplatform.googleapis.com/.../reasoningEngines/<ID>"
   Span Filho 1 (Cloud Run MCP): cloud.resource_id = "//run.googleapis.com/.../revisions/o11y-mcp-erp-ops-00002"
   Span Filho 2 (Cloud Run A2A): cloud.resource_id = "//run.googleapis.com/.../revisions/o11y-a2a-sla-risk-00002"
                                        │
                                        ▼  (Janela agregadora de ~5 min -> Horizonte movel fixo de 60 min)
2. App Hub (apphub.googleapis.com) + Agent Registry (agentregistry.googleapis.com) resolvem a identidade logica:
   Revisao efemera Cloud Run  ──► DiscoveredService + Base/MCPServer (urn:mcp:...:o11y-mcp-erp-ops)
   Revisao efemera Cloud Run  ──► DiscoveredService + Base/Agent     (urn:agent:...:o11y-a2a-sla-risk)
   Reasoning Engine           ──► DiscoveredWorkload + Base/Agent    (urn:agent:...:reasoningEngines/<ID>)
                                        │
                                        ▼
3. App Topology (apptopology.googleapis.com) materializa arestas Observability/SENDS_TRAFFIC:
   [o11y-agent-orchestrator] ──(p95Latency, errorRate)──► [o11y-mcp-erp-ops]
   [o11y-agent-orchestrator] ──(p95Latency, errorRate)──► [o11y-a2a-sla-risk]
```

---

## 🔍 4. Código Anotado dos Pontos-Chave

### 4.1 Injeção OIDC + `traceparent` no Orquestrador ([`src/agent/agent.py`](./src/agent/agent.py))
- **`get_mcp_auth_and_trace_headers()`**: Cunhar um OIDC ID Token via `IDTokenCredentials` (personificando `sa-o11y-cr-invoker`) permite chamar o Cloud Run privado (`--no-allow-unauthenticated`) a partir da identidade SPIFFE do Reasoning Engine sem chaves estáticas, enquanto `propagate.inject(headers)` serializa o span ativo da ADK em `headers["traceparent"]`.
- **`_a2a_before_card_request()` & `_a2a_before_request()`**: Usa os interceptors oficiais do `A2aRemoteAgentConfig` (`CardRequestInterceptor` e `RequestInterceptor`) sem guardar clientes HTTP abertos em atributos de instância — garantindo compatibilidade 100% com a serialização `cloudpickle` do Reasoning Engine!
- **`AgentTool(agent=sla_risk_remote_agent)`**: Envolver o `RemoteA2aAgent` em `AgentTool` faz o Orquestrador manter o controle da conversa (chamando MCP e A2A no mesmo turno) **e** faz o `BigQueryAgentAnalyticsPlugin` classificar automaticamente a chamada como `tool_origin = "A2A"`.

### 4.2 Extração Híbrida de Contexto no FastMCP ([`src/mcp_server/server.py`](./src/mcp_server/server.py))
- **`W3CTraceContextASGIMiddleware`**: Lê o `traceparent` do header HTTP e, caso um cliente MCP envie apenas via JSON-RPC `params._meta.traceparent`, reconstrói o contexto a partir do corpo sem consumir o stream ASGI (`replay_receive`), criando um span `SpanKind.SERVER` pai antes das tools rodarem.

### 4.3 Enriquecimento Automático de URN no Cloud Run A2A ([`src/a2a_specialist/server.py`](./src/a2a_specialist/server.py))
- **`get_gcp_resource(project_id=PROJECT_ID)`**: Detecta `K_SERVICE`/`K_REVISION` no Cloud Run e consulta o Resource Manager (`roles/browser`) para estampar `gen_ai.main_agent.id = urn:agent:projects-<NUM>:projects:<NUM>:locations:us-central1:run:services:o11y-a2a-sla-risk`, conectando os spans diretamente ao nó registrado no Agent Registry e no Agent Topology.
