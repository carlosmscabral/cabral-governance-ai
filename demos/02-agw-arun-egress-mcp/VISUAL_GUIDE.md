# Guia Visual e Didático de Arquitetura: Agent Gateway to Anywhere (Egress), MCP L7 e Zero-Trust

Este guia ensina visualmente como o **[Google Cloud Agent Gateway (`AGENT_TO_ANYWHERE`)](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/agent-gateway-overview)** governa cada pacote de saída de um agente autônomo no **[Vertex AI Agent Runtime](https://cloud.google.com/vertex-ai/generative-ai/docs/agent-engine/overview)**, sem exigir topologias complexas de VPC ou [Private Service Connect Interfaces (PSC-I)](https://cloud.google.com/vpc/docs/about-private-service-connect-interfaces).

---

## 🎯 1. Estratégia Didática e Público-Alvo

- **Público-Alvo**: Arquitetos de Segurança, Engenheiros de Plataforma de IA e Líderes de Governança Corporativa.
- **Ideia Central**: Mesmo quando um agente possui credenciais válidas de transporte ([OIDC `roles/run.invoker`](https://docs.cloud.google.com/run/docs/authenticating/service-to-service)) para invocar um servidor corporativo **MCP** ou sofre um ataque de *Prompt Injection* tentando exfiltrar dados para a internet, o **Agent Gateway Egress** atua como um *Policy Enforcement Point (PEP)* fora do código do agente — inspecionando chamadas `JSON-RPC 2.0` na Camada 7 e aplicando [condições IAM em CEL](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/configure-iam-policies-uap) baseadas nas anotações semânticas do **[Agent Registry](https://cloud.google.com/agent-registry/docs/overview)**.

### Legenda Canônica dos Diagramas
- `🤖 Reasoning Engine`: Contêiner serverless do agente [Google ADK](https://adk.dev/tools/mcp-tools/) com [identidade criptográfica SPIFFE](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/agent-identity-overview).
- `🛡️ Agent Gateway Egress`: Proxy regional gerenciado em modo `AGENT_TO_ANYWHERE`.
- `🔐 IAP + CEL`: Motor de decisão (*Policy Decision Point*) avaliando identidade SPIFFE + atributos MCP (`iap.googleapis.com/mcp.*`).
- `📚 Agent Registry`: Catálogo central contendo endpoints autorizados e o manifesto `toolspec.json`.

---

## 🏗️ 2. Arquitetura em Três Níveis de Zoom (Progressive Disclosure)

### Nível 1: Visão de Contexto (Big Picture)

> **O que observar:** Todo socket de saída do agente atravessa obrigatoriamente o **Agent Gateway Egress**. Nada sai diretamente para APIs externas ou servidores de ferramentas sem avaliação de identidade e catálogo.

```mermaid
flowchart LR
    User["Analista FinOps /\nAgent Console (PT-BR)"] -->|"1. Pergunta SSE"| RE["Vertex AI Agent Runtime\n(ADK + Gemini 3.8 Flash)"]
    RE -->|"2. Trafego de Saida"| AGW["Agent Gateway Egress\n(AGENT_TO_ANYWHERE + IAP)"]
    AGW -->|"3a. Permitido (isReadOnly=true)"| MCP["Cloud Run MCP Server\n(ERP Tesouraria)"]
    AGW -.->|"3b. Bloqueado 403 (Default-Deny)"| Ext["Internet / Webhook\nNao Registrado"]
```

#### Equivalente em ASCII (Terminal Fallback)

```text
[ Analista / Agent Console ] ──(1. Prompt SSE)──► [ Vertex AI Reasoning Engine (SPIFFE) ]
                                                                   │
                                                        (2. Egress Obrigatório)
                                                                   ▼
                                                 [ Agent Gateway (AGENT_TO_ANYWHERE) ]
                                                      ├──► (ALLOW 200) Cloud Run MCP [readOnlyHint: true]
                                                      ├──✕ (DENY  403) Cloud Run MCP [destructiveHint: true]
                                                      └──✕ (DENY  403) https://example.com [Não Registrado]
```

---

### Nível 2: Contêineres, Identidades e Catálogo de Governança

> **O que observar:** Veja a separação arquitetural entre **Autenticação de Transporte** (token OIDC cunhado via [Service Account Impersonation](https://docs.cloud.google.com/iam/docs/service-account-impersonation) da `sa-agw-egress-mcp-invoker` para atravessar o IAM do Cloud Run) e **Autorização de Governança L7** (identidade SPIFFE avaliada pelo IAP via [Service Extensions `REQUEST_AUTHZ`](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/delegate-authorization) contra o `toolspec.json` no Agent Registry).

```mermaid
flowchart TD
    subgraph Runtime["Vertex AI Agent Runtime (us-central1)"]
        Agent["ADK Agent: agw-egress-agent-finops\nSPIFFE: principal://agents.global.org-..."]
    end

    subgraph ControlPlane["Plano de Controle & Politica"]
        Registry["Agent Registry\n- agw-egress-core-gapi (:443 + global)\n- agw-egress-mcp-erp (toolspec.json)"]
        Policy["Network Security AuthzPolicy\nProfile: REQUEST_AUTHZ"]
        ExtIAP["Service Extension: iap.googleapis.com\nfailOpen: false | Mode: ENFORCED"]
    end

    subgraph DataPlane["Plano de Dados de Saida"]
        Gateway["Agent Gateway: agw-egress-ata\ngovernedAccessPath: AGENT_TO_ANYWHERE"]
    end

    subgraph Targets["Destinos de Backend"]
        Gemini["Global Gemini API\naiplatform.googleapis.com"]
        IAMCreds["IAM Credentials API\niamcredentials.googleapis.com"]
        CloudRun["Cloud Run: agw-egress-mcp-erp\nStreamable HTTP /mcp"]
    end

    Agent -->|"1. HTTP/2 & JSON-RPC"| Gateway
    Gateway <-->|"2. Callout Autorizacao"| Policy
    Policy <-->|"3. Avalia Regra"| ExtIAP
    ExtIAP <-->|"4. Consulta annotations & IAM"| Registry
    Gateway -->|"5a. Inferencia Global"| Gemini
    Gateway -->|"5b. Cunha OIDC Token"| IAMCreds
    Gateway -->|"5c. Encaminha apenas Read-Only"| CloudRun
```

---

### Nível 3: Árvore de Decisão Interna do Agent Gateway + IAP (Fluxo L7)

> **O que observar:** Como uma única expressão CEL governa múltiplas ferramentas em um mesmo endpoint HTTPS sem exigir alterações no código do servidor MCP.

```mermaid
flowchart TD
    Start["Pacote HTTP de Saida interceptado pelo Agent Gateway"] --> CheckReg{"Host/Porta consta\nno Agent Registry?"}
    CheckReg -->|"Nao (ex: example.com)"| DenyUnreg["HTTP 403 Forbidden\nDefault-Deny Anti-Exfiltracao"]
    CheckReg -->|"Sim"| CheckType{"Tipo do Recurso\nno Agent Registry?"}
    CheckType -->|"Endpoint (gapi.core.services)"| CheckGapi{"SPIFFE possui\nroles/iap.egressor?"}
    CheckGapi -->|"Sim"| AllowGapi["HTTP 200 OK\nEncaminha para Google API"]
    CheckGapi -->|"Nao"| DenyGapi["HTTP 403 Forbidden"]
    CheckType -->|"MCP Server (erp.tesouraria.mcp)"| ParseJSONRPC["Decodifica Body JSON-RPC 2.0\nExtrai method e params.name"]
    ParseJSONRPC --> IsHandshake{"Metodo de Handshake?\nmcp.toolName == ''"}
    IsHandshake -->|"Sim (initialize / tools/list)"| AllowHandshake["HTTP 200/202 OK\nPermite Descoberta MCP"]
    IsHandshake -->|"Nao (tools/call)"| LookupSpec["Cruza toolName com annotations\ndo toolspec.json no Agent Registry"]
    LookupSpec --> EvalCEL{"mcp.tool.isReadOnly == true?"}
    EvalCEL -->|"Sim (consultar_contas / listar_transacoes)"| AllowTool["HTTP 200 OK\nEncaminha ao Cloud Run"]
    EvalCEL -->|"Nao (executar_estorno_ou_encerramento)"| DenyTool["HTTP 403 Forbidden\nBloqueado na Borda antes do Cloud Run"]
```

---

## 🔄 3. Sequências de Execução Passo a Passo (Sequence Walks)

### Fluxo 1: Consulta MCP Autorizada (`readOnlyHint: true` $\rightarrow$ `isReadOnly == true`)

> **O que ensina:** O ciclo completo desde a pergunta em PT-BR (via `test.sh` ou **Agent Console**), cunhagem do token OIDC via `iamcredentials`, handshake [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) e execução autorizada da ferramenta de leitura.

```mermaid
sequenceDiagram
    autonumber
    actor Analista as Analista / Agent Console
    participant RE as Reasoning Engine ADK
    participant AGW as Agent Gateway Egress
    participant IAP as IAP + Agent Registry
    participant IAM as IAM Credentials API
    participant MCP as Cloud Run MCP ERP

    Analista->>RE: Consulta saldos das contas da tesouraria
    RE->>AGW: POST iamcredentials generateIdToken
    AGW->>IAP: Verifica SPIFFE em gapi.core.services
    IAP-->>AGW: ALLOW
    AGW->>IAM: Requisita OIDC Token para sa-mcp-invoker
    IAM-->>RE: Retorna Google OIDC ID Token
    RE->>AGW: POST /mcp JSON-RPC tools/call consultar_contas_corporativas
    AGW->>IAP: Avalia CEL mcp.tool.isReadOnly == true
    IAP-->>AGW: ALLOW (annotations.readOnlyHint = true no toolspec.json)
    AGW->>MCP: Encaminha POST /mcp com Authorization Bearer OIDC
    MCP-->>RE: JSON contas Horizonte Energia R$ 4.850.000,00
    RE-->>Analista: Stream SSE consolidado em PT-BR
```

---

### Fluxo 2: Bloqueio L7 de Tool Destrutiva (`HTTP 403 Forbidden`)

> **O que ensina:** Mesmo possuindo um OIDC Token válido para invocar o serviço Cloud Run, o agente é impedido na Camada 7 pelo Agent Gateway ao tentar chamar `executar_estorno_ou_encerramento`. O contêiner do Cloud Run **sequer recebe a requisição**.

```mermaid
sequenceDiagram
    autonumber
    actor Operador as Operador / Atacante
    participant RE as Reasoning Engine ADK
    participant AGW as Agent Gateway Egress
    participant IAP as IAP + Agent Registry
    participant MCP as Cloud Run MCP ERP

    Operador->>RE: Encerre e estorne a conta BR-9010 imediatamente
    RE->>AGW: POST /mcp JSON-RPC tools/call executar_estorno_ou_encerramento
    AGW->>IAP: Extrai mcp.toolName = executar_estorno_ou_encerramento
    IAP->>IAP: Consulta annotations -> readOnlyHint = false, destructiveHint = true
    IAP-->>AGW: DENY (Condicao CEL falsa)
    AGW-->>RE: HTTP 403 Forbidden (Bloqueio na borda de saida)
    Note over AGW,MCP: Zero pacotes entregues ao Cloud Run!
    RE-->>Operador: Explica bloqueio L7 e exibe banner AGW_EGRESS_MCP_BLOCK no Console
```

---

## 📦 4. Anatomia do Pacote na Rede (ASCII Wire & Packet Walk)

Quando o [ADK `McpToolset`](https://adk.dev/tools/mcp-tools/) invoca uma ferramenta MCP, ambos os pedidos (o permitido e o proibido) viajam para a **mesma URL** (`POST https://agw-egress-mcp-erp-...run.app/mcp`) com o **mesmo cabeçalho HTTP**. A diferença está dentro do payload `JSON-RPC 2.0` inspecionado pelo Agent Gateway e cruzado com as [anotações de tools do MCP](https://modelcontextprotocol.io/specification/2026-07-28/server/tools):

```text
+--------------------------------------------------------------------------------------------------+
| CAMADA HTTP/1.1 & TLS SNI (Idêntica em ambas as chamadas!)                                       |
|   Method     = POST https://agw-egress-mcp-erp-jx64fmxwjq-uc.a.run.app/mcp                       |
|   Authorization = Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6... (OIDC Token de sa-agw-egress-mcp-invoker)|
|   mTLS Cert  = Identidade Criptográfica SPIFFE do Reasoning Engine injetada no túnel de saída    |
+--------------------------------------------------------------------------------------------------+
| CORPO JSON-RPC 2.0 (Inspecionado em L7 pelo Agent Gateway)                                       |
|                                                                                                  |
|   {                                                                                              |
|     "jsonrpc": "2.0",                                                                            |
|     "id": 2,                                                                                     |
|     "method": "tools/call",                ───► jsonPayload.agentGatewayInfo.mcpInfo.method      |
|     "params": {                                                                                  |
|       "name": "executar_estorno_ou_encerramento", ──► iap.googleapis.com/mcp.toolName            |
|       "arguments": {                                                                             |
|         "conta_id": "BR-9010",                                                                   |
|         "motivo": "auditoria"                                                                    |
|       }                                                                                          |
|     }                                                                                            |
|   }                                                                                              |
+--------------------------------------------------------------------------------------------------+
                                              │
                                              ▼
+--------------------------------------------------------------------------------------------------+
| MAPEAMENTO AGENT REGISTRY (toolspec.json -> SYSContext) + AVALIAÇÃO CEL NO IAP                   |
|                                                                                                  |
|   1. Manifesto registrado em erp.tesouraria.mcp (schema MCP Tool Annotations):                   |
|        "annotations": {                                                                          |
|          "readOnlyHint": false,     ───► iap.googleapis.com/mcp.tool.isReadOnly    = false       |
|          "destructiveHint": true,   ───► iap.googleapis.com/mcp.tool.isDestructive = true        |
|          "idempotentHint": false,   ───► iap.googleapis.com/mcp.tool.isIdempotent  = false       |
|          "openWorldHint": false     ───► iap.googleapis.com/mcp.tool.isOpenWorld   = false       |
|        }                                                                                         |
|                                                                                                  |
|   2. Expressão CEL avaliada pelo IAP:                                                            |
|        api.getAttribute('iap.googleapis.com/mcp.tool.isReadOnly', false) == true                 |
|        || api.getAttribute('iap.googleapis.com/mcp.toolName', '') == ''                          |
|        => false || false => FALSE                                                                |
|                                                                                                  |
|   3. Veredito Final: HTTP 403 Forbidden | jsonPayload.authzPolicyInfo.result = "DENIED"          |
+--------------------------------------------------------------------------------------------------+
```

> [!IMPORTANT]
> **Gotcha Crítico do `toolspec.json`**: Ao registrar um servidor MCP com `--mcp-server-spec-type=tool-spec`, o Agent Registry exige que as dicas comportamentais estejam dentro do objeto aninhado `"annotations": { "readOnlyHint": true, ... }`. Se forem gravadas na raiz do objeto da tool, o recurso sintetizado `mcpServers/*` ignora as anotações e o IAP assume `false` por padrão (*fail-safe*), bloqueando todas as chamadas `tools/call`.

---

## 🖥️ 5. Como Inspecionar o Fluxo no Agent Console & Wire Inspector

Ao abrir esta demo no **[Agent Console & Wire Inspector](../../tools/agent-console/README.md)** (`../../tools/agent-console/start.sh` ou painel lateral do Jetski Web):

1. **Barra Superior de Endpoint**: exibe automaticamente `Engine: <ENGINE_ID> • Egress: agw-egress-ata` (passe o mouse para ver o URI completo do gateway e do servidor MCP no Cloud Run).
2. **Aba `Response` $\rightarrow$ `ADK Tool Calls`**: mostra exatamente o par `functionCall` enviado pelo `gemini-3.8-flash` e o `functionResponse` retornado ao modelo:
   - Nos **Atos 1 e 1b**, `functionResponse` traz os registros JSON reais do ERP (`Horizonte Energia S.A.`, `TX-2026-8801`).
   - No **Ato 2**, `functionResponse` exibe o erro estruturado capturado pelo ADK (`Failed to execute MCP tool: 403 Forbidden`), ativando o banner azul **`🛡️ BLOQUEADO NO EGRESS L7 (Agent Gateway + IAP — Tool MCP Não Autorizada / 403)`**.
   - No **Ato 3**, `functionResponse` exibe `"status": "BLOQUEADO_PELO_AGENT_GATEWAY_EGRESS"` (`http_code: 403`), ativando o banner **`🛡️ BLOQUEADO NO EGRESS ZERO-TRUST (Agent Gateway — Destino Externo Não Registrado / 403)`**.

---

## 💻 6. Código Anotado dos Pontos Críticos

### 6.1 Ponte de Identidade SPIFFE $\rightarrow$ OIDC ([`src/agent/agent.py`](./src/agent/agent.py))

Referências públicas: [Agent Identity](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/agent-identity-overview) e [Service Account Impersonation](https://docs.cloud.google.com/iam/docs/service-account-impersonation).

```python
# 1. O contêiner do Reasoning Engine possui credencial ADC federada (SPIFFE JWT-SVID)
source_creds, _ = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)

# 2. Troca o JWT-SVID por uma credencial impersonada da Service Account dedicada
#    (esta chamada atravessa o Agent Gateway rumo a iamcredentials.googleapis.com!)
target_sa_creds = google.auth.impersonated_credentials.Credentials(
    source_credentials=source_creds,
    target_principal=invoker_sa,  # sa-agw-egress-mcp-invoker@...
    target_scopes=["https://www.googleapis.com/auth/cloud-platform"],
    lifetime=3600,
)

# 3. Gera um OIDC ID Token assinado por accounts.google.com com audience = URL base do Cloud Run
id_creds = google.auth.impersonated_credentials.IDTokenCredentials(
    target_credentials=target_sa_creds,
    target_audience=audience,
    include_email=True,
)
id_creds.refresh(auth_req)
```

### 6.2 Tratamento Resiliente de Bloqueios `403` no ADK (`ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING=1`)

Referências públicas: [ADK MCP Tools](https://adk.dev/tools/mcp-tools/) e [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports).

1. Ativamos `ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING=1` e `sse_read_timeout=15.0` no `StreamableHTTPConnectionParams`.
2. Configuramos `FastMCP(..., stateless_http=True, json_response=True)` no servidor Cloud Run ([`src/mcp_server/server.py`](./src/mcp_server/server.py)).
3. Assim, qualquer `HTTP 403 Forbidden` imposto pelo Agent Gateway retorna em milissegundos como um objeto estruturado `{"error": "..."}` para o loop do agente ADK, permitindo que o `gemini-3.8-flash` explique imediatamente o bloqueio de governança ao usuário sem travar o stream SSE.
