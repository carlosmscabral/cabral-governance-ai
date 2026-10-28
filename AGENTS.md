# AGENTS.md — Diretrizes de Engenharia, Padrão de Testes e CI Autônomo

Este documento define as regras arquiteturais, convenções de código e o **contrato obrigatório de testes (`test.sh` + `scripts/ci_healthcheck.sh`)** para todas as demonstrações da **Gemini Platform / Agent Platform** neste repositório. Qualquer agente de IA ou engenheiro que crie ou modifique uma demo deve seguir estas regras rigorosamente.

---

## 1. Padrões Globais de Ambiente, Projeto e Modelo (`env.sh`)

Toda demo em `demos/<NN-slug>/` deve possuir um arquivo `env.sh` que respeite os seguintes padrões:

1. **Projeto GCP e Configuração `gcloud` Padrão**:
   - Se `CLOUDSDK_ACTIVE_CONFIG_NAME` não estiver definido e o perfil `argolis` existir na máquina local, ativar automaticamente `export CLOUDSDK_ACTIVE_CONFIG_NAME="argolis"`.
   - O `PROJECT_ID` padrão deve ser **`cabral-governance-ai`** (`export PROJECT_ID="${PROJECT_ID:-cabral-governance-ai}"`), permitindo override via variável de ambiente.
2. **Modelo Gemini e Região de Inferência (`global`)**:
   - **Modelo padrão obrigatório**: `export MODEL_NAME="${MODEL_NAME:-gemini-3.8-flash}"`.
   - **Localização do modelo sempre `global`**: Independentemente da região de infraestrutura/computação (`REGION="${REGION:-us-central1}"`), todas as chamadas de inferência LLM devem usar o endpoint global (`MODEL_LOCATION="global"`, `GOOGLE_CLOUD_LOCATION="global"`, `VERTEX_AI_LOCATION="global"`).
3. **Autenticação Consistente no SDK Python (`deploy_agent.py`)**:
   - Para evitar conflito entre o Application Default Credentials (ADC) global da máquina e a configuração ativa do `gcloud` (`argolis`), scripts Python de deploy/teste devem extrair o token via `gcloud auth print-access-token` e injetar `google.oauth2.credentials.Credentials(token=token)` no `vertexai.init()` e `vertexai.Client()` (com fallback para ADC padrão).
4. **Detecção de Drift e Atualização In-Place**:
   - Os scripts de deploy (`05_deploy_agent.sh`, `03_deploy_orchestrator_and_topology.sh`, `02_deploy_mcp_and_a2a.sh`, `deploy_agent.py`) nunca devem assumir cegamente que um Reasoning Engine ou serviço Cloud Run existente está atualizado apenas porque o recurso existe.
   - No **Vertex AI Reasoning Engine**, devem inspecionar o `MODEL_NAME` e variáveis críticas em `.spec.deploymentSpec.env` e executar `client.agent_engines.update(...)` (preservando o Engine ID e a identidade SPIFFE) sempre que houver divergência.
   - Em **topologias multi-nó no Cloud Run** (`--functional-type=agent` ou `mcp-server`), devem verificar o hash do código-fonte e o `MODEL_NAME` ativo na revisão do serviço para evitar rebuilds desnecessários no Cloud Build em execuções semanais de CI quando não houver mudança, mas garantindo atualização *in-place* (preservando a URL determinística e a identidade SPIFFE) caso haja drift.

---

## 2. Estrutura Obrigatória de Cada Demo (`demos/<NN-slug>/`)

Cada diretório dentro de `demos/` é autocontido e deve conter:

| Arquivo / Pasta | Obrigatoriedade | Responsabilidade |
| :--- | :---: | :--- |
| `env.sh` | Obrigatório | Autodescoberta de configuração `argolis`, `PROJECT_ID=cabral-governance-ai` e `MODEL_NAME=gemini-3.8-flash` (`global`). |
| `deploy.sh` | Obrigatório (`+x`) | Provisionamento 100% idempotente da infraestrutura GCP, políticas de segurança e agente ADK. |
| `test.sh` | Obrigatório (`+x`) | Suíte automatizada de testes ponta a ponta em Português do Brasil (PT-BR). |
| `undeploy.sh` | Obrigatório (`+x`) | Desprovisionamento completo (*Zero Residuals*), removendo recursos e bindings IAM sem deixar resíduos. |
| `README.md` | Obrigatório | Visão geral, diagrama de arquitetura Mermaid, início rápido, tabela de cenários de teste e matriz IAM. |
| `VISUAL_GUIDE.md` | Obrigatório | Guia visual didático (C4 em 3 níveis, sequence diagrams, wire format e código anotado). |
| `DEMO_GUIDE.md` | Obrigatório | Roteiro de apresentação ao vivo para clientes (pitch de 60s, abas pré-abertas com links diretos, coreografia visual por ato, roteiro tela a tela no Console GCP, comandos cURL e FAQ). |
| `scenarios.json` | Recomendado | Manifesto declarativo de personas e cenários (Atos da Demo) carregado automaticamente pelo `tools/agent-console/`. |

### 2.1 Contrato Visual Obrigatório do `DEMO_GUIDE.md` (Telas do Console GCP & Coreografia)

Demonstrações executivas dependem fortemente de **impacto visual**. Nunca entregue um `DEMO_GUIDE.md` baseado apenas em comandos de terminal. Todo `DEMO_GUIDE.md` deve conter obrigatoriamente:

1. **Checklist de Abas Pré-Abertas no Navegador (com Deep-Links Diretos)**:
   - Listar na seção de preparação todas as URLs exatas do Google Cloud Console (`https://console.cloud.google.com/...?project=cabral-governance-ai`) que o apresentador deve deixar abertas antes da reunião (ex.: `agent-platform/gateways`, `agent-platform/agent-registry/agents`, `agent-platform/topology`, `agent-platform/security`, `traces/explorer`, `bigquery`, `logs/query`).
   - Documentar explicitamente qualquer janela temporal ou *warm-up* necessário para gráficos visuais (ex.: disparar tráfego 5–10 min antes para popular arestas da janela fixa de 60 min da aba **Topology**).
2. **Coreografia Visual em Duas Telas por Ato (`Agent Console` ⟷ `Console GCP`)**:
   - Em cada Ato do roteiro, indicar claramente **(a) o que clicar e destacar no `Agent Console & Wire Inspector`** (resposta de negócio à esquerda + badges/headers/chunks à direita) e **(b) qual tela/aba específica do Google Cloud Console mostrar em seguida** para comprovar visualmente na infraestrutura da nuvem o que acabou de ocorrer.
3. **Seção Dedicada `🗺️ Roteiro de Navegação Visual no Console GCP (Tela por Tela)`**:
   - Incluir uma tabela estruturada mapeando cada recurso chave da demo com 4 colunas: **Etapa / Recurso**, **Caminho no Menu & URL Direta**, **Aba / Sub-tela para Clicar** (ex.: `Observability`, `Topology`, `Identity`, `Traces`, `Security`) e **O que Apontar Visualmente para o Cliente**.

---

## 3. Contrato de Testes Consistentes (`test.sh`)

Para que o **CI Semanal Autônomo** (`scripts/ci_healthcheck.sh`) valide e recupere qualquer demo automaticamente, todo script `test.sh` deve obedecer às seguintes regras:

1. **Execução Não-Interativa e Códigos de Saída Estritos**:
   - `test.sh` deve rodar de ponta a ponta sem prompts interativos.
   - Deve retornar **`exit 0`** somente se 100% das asserções passarem, e **`exit 1`** se qualquer cenário falhar (`((TESTS_FAILED > 0))`).
2. **Cobertura Mínima Obrigatória de Cenários (em PT-BR)**:
   - **Cenário Positivo (Caminho Feliz / Negócio)**: Envia uma pergunta legítima em PT-BR e valida o conteúdo semântico real retornado pelo agente (ex.: nomes ou valores específicos do dataset).
     - *Atenção*: Conexões SSE (`:streamQuery?alt=sse`) podem retornar `HTTP 200` no transporte mesmo quando ocorre erro interno no agente (ex.: `{"error_code": "ClientError", "error_message": "404 NOT_FOUND"}`). Por isso, o teste **sempre** deve validar a presença do dado esperado na resposta e falhar caso receba erro.
   - **Cenário de Governança / Guardrail / Resiliência Ativa**: Valida que a política de segurança ou resiliência operacional da demo atua como esperado:
     - Ex. Ingress: Redação de PII/SSN via Model Armor + Cloud DLP (`[US_SOCIAL_SECURITY_NUMBER]`) e bloqueio de Prompt Injection / Jailbreak na borda (`HTTP 403` / `Model Armor: Prompt violates content security configurations`).
     - Ex. Egress / MCP: Permissão para tool `readOnly` e bloqueio para tool destrutiva/escrita via Agent Gateway / IAM / SGP.
     - Ex. Observabilidade / Multi-Agente: Diagnóstico gracioso de falha/gargalo operacional (`StatusCode.ERROR` em span filho MCP/WMS) com escalonamento A2A sem queda silenciosa do orquestrador.
   - **Cenário de Observabilidade / Auditoria**: Verifica nos logs, traces e tabelas analíticas (`Cloud Logging`, `Cloud Trace`, `BigQuery Agent Analytics` e `Agent Registry` / `App Topology`) se o veredito de segurança, a costura distribuída W3C `traceparent` entre runtimes, as views semânticas (`v_llm_response`, `v_tool_completed`) e a descoberta de nós foram devidamente registrados.
3. **Higiene de Shell Script (`set -euo pipefail`)**:
   - Sempre usar pré-incremento aritmético `((++TESTS_PASSED))` e `((++TESTS_FAILED))` (nunca pós-incremento `((TESTS_PASSED++))` partindo de `0`, pois `(( 0 ))` retorna status `1` no Bash e aborta scripts com `set -e` / `trap ERR`).
   - Incluir pequeno *pacing* (`sleep 2`) entre chamadas consecutivas de streaming para evitar bursts desnecessários.

---

## 4. CI Semanal e Auto-Recuperação (Self-Healing via Jetski)

O repositório conta com um orquestrador de CI em [`scripts/ci_healthcheck.sh`](./scripts/ci_healthcheck.sh), acionado automaticamente **toda sexta-feira às 20:00 BRT** pela automação agendada do Jetski (`CI Semanal & Auto-Fix — Governance AI Demos` / `governance-demos-weekly-ci`):

1. **Autodescoberta de Demos**: Qualquer pasta em `demos/*` que possua `deploy.sh` e `test.sh` executáveis é automaticamente incluída no ciclo semanal de testes.
2. **Fluxo do `scripts/ci_healthcheck.sh`**:
   - **Preflight OAuth (`exit 2`)**: Verifica se o token da configuração `argolis` está ativo (`gcloud auth print-access-token --configuration=argolis`). Se tiver expirado, encerra com código `2` (`[AUTH_EXPIRED]`) para que o agente apenas solicite `gcloud auth login --configuration=argolis`, sem abrir issue falsa de bug.
   - **Preflight de Modelo Global**: Valida se `gemini-3.8-flash` responde `HTTP 200` no endpoint `global` da Vertex AI.
   - **Upgrade de SDK (`--upgrade-sdk`)**: Atualiza os pacotes Python do `.venv` (`google-cloud-aiplatform[adk,agent_engines]`, `google-cloud-storage`, mais dependências opcionais detectadas em `src/pyproject.toml` como `mcp`, `google-adk[bigquery-analytics,a2a]`, `opentelemetry-*` e `google-cloud-bigquery*`) para detectar quebras de SDK precocemente.
   - **Execução (`deploy.sh` + `test.sh`)**: Garante que a infraestrutura e o agente estão sincronizados no Argolis e executa todos os testes ponta a ponta.
3. **Protocolo de Auto-Healing (Em Caso de Falha `exit 1`)**:
   - O agente autônomo inspeciona os logs em `.state/ci_logs/`, diagnostica a causa raiz (drift de modelo, depreciação de classe/parâmetro no SDK ADK/Vertex AI, mudança de schema no BigQuery Analytics ou flag no `gcloud`), aplica o fix no código, reexecuta `deploy.sh` + `test.sh` para deixar o ambiente de demo 100% operacional no Argolis e registra uma **Issue + Pull Request** no repositório GitHub (`carlosmscabral/cabral-governance-ai`).

---

## 5. Console Visual de Demonstração (`tools/agent-console/`)

Para apresentações ao vivo sem depender apenas de `curl` no terminal, o repositório inclui o **Agent Console & Wire Inspector** ([`tools/agent-console/`](./tools/agent-console/README.md)):

1. **Modos de Uso**:
   - **Plugin Nativo do Jetski Web**: `./tools/agent-console/install_jetski_plugin.sh` instala o painel lateral (`~/.gemini/config/plugins/agent_console/`) servido via ÜberProxy.
   - **Servidor Local Standalone**: `./tools/agent-console/start.sh` inicia em `http://127.0.0.1:8090`.
2. **Integração Automática com Demos & Cloud Trace**:
   - O console descobre automaticamente qualquer pasta `demos/*` lendo `.state/agent_info.json`, `env.sh` e `scenarios.json`.
   - Injeta automaticamente o cabeçalho W3C `traceparent` em cada turno proxied e renderiza um botão **🔗 Cloud Trace** em 1 clique no Wire Inspector para abrir a cascata distribuída no console do GCP.
   - Sempre que criar uma nova demo, inclua um arquivo `scenarios.json` com os atos da demonstração (`safe`, `dlp`, `attack`) para habilitar o disparo em 1 clique no console.
