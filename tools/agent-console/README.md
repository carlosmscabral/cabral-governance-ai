# 🛡️ Agent Console & Wire Inspector (`tools/agent-console`)

Interface web local (**"Chat + Lightweight Postman"**) construída para conduzir demonstrações ao vivo das arquiteturas de governança de agentes deste repositório, combinando a experiência de um **canal de chat** (visão de negócio) com um **inspetor de tráfego HTTP/SSE em tempo real** (visão de arquitetura e segurança).

---

## 🚀 Modos de Execução

### Opção 1: Plugin Nativo do Jetski Web (Recomendado no Cloudtop)

Para abrir o **Agent Console & Wire Inspector** diretamente no painel lateral direito (**Auxiliary Pane**) do Jetski Web — aproveitando o proxy autenticado do próprio Jetski (ÜberProxy) sem precisar configurar túneis SSH:

```bash
./tools/agent-console/install_jetski_plugin.sh
```

- Instala o bundle em `~/.gemini/config/plugins/agent_console/` (`plugin.json` + `sidecars/inspector/sidecar.json`).
- O Jetski gerencia o ciclo de vida do servidor automaticamente (`restart_policy: "always"`), injetando `ANTIGRAVITY_SIDECAR_WEB_PORT` e sincronizando variáveis de tema via `/preload.js`.
- Basta clicar no ícone **🛡️ Agent Console & Wire Inspector** na barra lateral direita do Jetski Web.

### Opção 2: Servidor Standalone Local (`127.0.0.1:8090`)

A partir da raiz do repositório:

```bash
./tools/agent-console/start.sh
```

Acesse **`http://127.0.0.1:8090`** no navegador local (ou via **Chrome Remote Desktop** / SSH Port Forwarding `ssh -L 8090:127.0.0.1:8090 <seu-cloudtop>`).

---

## ✨ Funcionalidades Principais

### 1. Auto-Discovery de Demos (`demos/*/`)
- Lê automaticamente `.state/agent_info.json`, `env.sh` e `scenarios.json` de cada demo do repositório.
- Preenche `PROJECT_ID`, `REGION`, `REASONING_ENGINE_ID` e monta os botões de **Atos da Demo (Playbook)** com notas de apresentador.

### 2. Layout Split-View Redimensionável (Chat  Left ⟷ Wire Inspector Right)
- **Divisor Central Arrastável (`#paneResizer`)**: arraste a barra central para dar foco ao Chat ou ao Wire Inspector (com persistência em `localStorage`).
- **Presets Rápidos de Foco**: botões **`70/30`**, **`50/50`** e **`30/70`** na barra do Inspector para alternar o foco instantaneamente durante a apresentação.

### 3. Ciclo de Vida de Sessões (`+ Nova Sessão` & `🔄 Zerar Sessão`)
- **Por que isso importa no Vertex AI Agent Runtime (`:streamQuery`)**:
  - No `AdkApp.async_stream_query`, enviar um payload **sem `session_id`** faz o container chamar `create_session(user_id=...)` no `VertexAiSessionService` **a cada turno**, criando uma sessão nova (e órfã) por mensagem e nunca retornando o `session_id` nos eventos SSE — tornando a conversa *stateless* (turno único).
- **Botão `+ Nova Sessão`**:
  - No perfil **Vertex `:streamQuery`**, invoca o endpoint `:query` com `{"class_method": "create_session", "input": {"user_id": "..."}}`, captura o `output.id` real criado no `VertexAiSessionService`, exibe a chamada HTTP completa no Wire Inspector e injeta automaticamente `input.session_id` nas próximas mensagens.
  - No perfil **ADK Passthrough (`/api/run_sse`)**, invoca `POST /apps/{id}/users/{u}/sessions`.
- **Botão `🔄 Zerar Sessão`**:
  - Invoca `{"class_method": "delete_session", "input": {"user_id": "...", "session_id": "..."}}` no `:query` para remover a sessão ativa no servidor e retorna o canal ao modo **Efêmero (stateless)**.

### 4. Wire Inspector & Telemetria de Eventos ADK (`function_call` / `function_response`)
Clique em qualquer turno do chat para inspecionar as 4 abas do **Wire Inspector**:
- **Request (`OUT`)**: método, URL exata, cabeçalhos enviados (com Bearer Token mascarado) e JSON body formatado.
- **Response (`IN`)**:
  - Status HTTP, latência **TTFT (ms)** e **Total (ms)**.
  - **Banner de Veredito de Governança**: diferencia claramente **`ALLOW`**, **`CLOUD DLP REDACT`** (`[US_SOCIAL_SECURITY_NUMBER]`), **`MODEL ARMOR INGRESS BLOCK`**, **`MODEL ARMOR EGRESS BLOCK`**, **`AGW EGRESS L7 MCP BLOCK`** (ferramenta MCP barrada na Camada 7 via IAP CEL) e **`AGW EGRESS ZERO-TRUST BLOCK`** (anti-exfiltração *default-deny* para destinos fora do Agent Registry).
  - **Visibilidade de Tool Calls (`function_call` / `function_response`)**: o endpoint `:streamQuery?alt=sse` transmite cada `google.adk.events.Event` gerado pelo `Runner.run_async()` do ADK (incluindo chamadas de ferramentas MCP e subagentes A2A e seus retornos brutos).
  - **Rastreamento Distribuído W3C (`traceparent`) & Deep-Link Cloud Trace**: o proxy gera e injeta automaticamente um cabeçalho W3C `traceparent: 00-<trace_id>-<span_id>-01` em cada requisição (caso o cliente não envie um), exibe o badge `🔍 trace=<8hex>…` no card do turno e disponibiliza o botão **🔗 Cloud Trace (`<8hex>…`)** na barra de métricas do Wire Inspector para abrir a cascata distribuída diretamente no console do GCP.
  - **Alerta de Segurança em Streaming (Audit Leak Warning)**: quando um guardrail de saída (`SANITIZE_MODEL_RESPONSE`) bloqueia apenas o último chunk textual do LLM com `403`, mas os chunks anteriores de `function_response` já trafegaram no stream SSE com dados brutos do bucket, o console exibe um alerta explícito explicando por que um BFF de produção deve filtrar eventos internos ou aplicar DLP na camada da tool.
- **SSE Timeline (`CHUNKS`)**: lista cronológica de cada frame SSE recebido com delta de tempo (`+ms`), badges de delta (`💬 texto`, `🔧 function_call`, `📦 function_response`, `🛑 erro`) e JSON formatado.
- **cURL (`CLI`)**: comando `curl` pronto para copiar (`$(gcloud auth print-access-token)`) e reproduzir no terminal.

### 5. Autenticação em 2 Camadas (Preparada para 3LO / OBO)
- **Camada 1 — Autenticação de Transporte (Client ➔ Gateway / Runtime)**:
  - Extrai e faz cache em memória (TTL de 50 min) do token da configuração `gcloud` **`argolis`** (`gcloud auth print-access-token --configuration=argolis` ou `print-identity-token`), com suporte a token manual ou requisição sem auth.
  - Inclui trava determinística que proíbe o uso de perfis restritos (`tim`).
- **Camada 2 — Identidade Delegada do Usuário (3LO / On-Behalf-Of)**:
  - Permite injetar cabeçalhos adicionais de propagação de identidade (ex.: `X-Forwarded-Authorization`) e expõe o endpoint local `/oauth/callback` (`http://localhost:8090/oauth/callback`) para capturar redirecionamentos OAuth 2.0 Authorization Code (`HTTP 302`) diretamente no navegador local.

---

## 📄 Contrato de Playbook (`demos/<slug>/scenarios.json`)

Para que qualquer nova demo apareça com botões de **Atos da Demo** pré-configurados no Agent Console, basta adicionar um arquivo `scenarios.json` na pasta da demo:

```json
{
  "title": "Demo 01: Agent Gateway Ingress + Model Armor + Cloud DLP",
  "subtitle": "Governança de Borda (CLIENT_TO_AGENT) no Vertex AI Reasoning Engine",
  "default_profile": "vertex_stream_query",
  "default_user_id": "cliente-demo",
  "personas": [
    {
      "id": "cliente-demo",
      "label": "cliente-demo (Operador CRM Normal)",
      "role": "Atendente autorizado consultando base regional"
    }
  ],
  "scenarios": [
    {
      "id": "act-1-safe-west",
      "act": "Ato 1",
      "title": "Consulta Segura (Região Oeste)",
      "category": "safe",
      "badge": "ALLOW",
      "user_id": "cliente-demo",
      "prompt": "Quais são os nomes dos nossos clientes da região Oeste?",
      "expected_behavior": "Model Armor aprova o prompt (ALLOW) e o agente lista os clientes.",
      "presenter_notes": "Mostre no Wire Inspector o status HTTP 200 e os chunks SSE."
    }
  ]
}
```

---

## 📁 Estrutura de Arquivos

```text
tools/agent-console/
├── README.md                   # Documentação da ferramenta e arquitetura do Wire Inspector
├── start.sh                    # Launcher unificado (Standalone :8090 + Jetski Sidecar)
├── install_jetski_plugin.sh    # Instalador do plugin nativo Jetski Web (~/.gemini/config/plugins/agent_console)
├── server.py                   # Backend FastAPI + Proxy Streaming HTTP/SSE + Auth Cache + Session API
└── static/
    ├── index.html              # Interface Split-View (Chat + Wire Inspector + Auth Modal)
    ├── styles.css              # Tema escuro adaptativo (compatível com tokens CSS do Jetski Host)
    └── app.js                  # Motor cliente ES6 (Splitter, Sessões, SSE Timeline e Vereditos)
```
