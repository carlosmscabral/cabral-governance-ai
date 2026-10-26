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
   - Os scripts de deploy (`05_deploy_agent.sh` / `deploy_agent.py`) nunca devem assumir cegamente que um Reasoning Engine existente está atualizado apenas porque o recurso existe. Eles devem inspecionar o `MODEL_NAME` ativo no `.spec.deploymentSpec.env` e executar `client.agent_engines.update(...)` (preservando o Engine ID e a identidade SPIFFE) sempre que houver divergência.

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
| `DEMO_GUIDE.md` | Obrigatório | Roteiro de apresentação ao vivo para clientes (pitch de 60s, atos da demo, comandos cURL e FAQ). |
| `scenarios.json` | Recomendado | Manifesto declarativo de personas e cenários (Atos da Demo) carregado automaticamente pelo `tools/agent-console/`. |

---

## 3. Contrato de Testes Consistentes (`test.sh`)

Para que o **CI Semanal Autônomo** (`scripts/ci_healthcheck.sh`) valide e recupere qualquer demo automaticamente, todo script `test.sh` deve obedecer às seguintes regras:

1. **Execução Não-Interativa e Códigos de Saída Estritos**:
   - `test.sh` deve rodar de ponta a ponta sem prompts interativos.
   - Deve retornar **`exit 0`** somente se 100% das asserções passarem, e **`exit 1`** se qualquer cenário falhar (`((TESTS_FAILED > 0))`).
2. **Cobertura Mínima Obrigatória de Cenários (em PT-BR)**:
   - **Cenário Positivo (Caminho Feliz / Negócio)**: Envia uma pergunta legítima em PT-BR e valida o conteúdo semântico real retornado pelo agente (ex.: nomes ou valores específicos do dataset).
     - *Atenção*: Conexões SSE (`:streamQuery?alt=sse`) podem retornar `HTTP 200` no transporte mesmo quando ocorre erro interno no agente (ex.: `{"error_code": "ClientError", "error_message": "404 NOT_FOUND"}`). Por isso, o teste **sempre** deve validar a presença do dado esperado na resposta e falhar caso receba erro.
   - **Cenário de Governança / Guardrail Ativo**: Valida que a política de segurança da demo atua como esperado:
     - Ex. Ingress: Redação de PII/SSN via Model Armor + Cloud DLP (`[US_SOCIAL_SECURITY_NUMBER]`) e bloqueio de Prompt Injection / Jailbreak na borda (`HTTP 403` / `Model Armor: Prompt violates content security configurations`).
     - Ex. Egress / MCP: Permissão para tool `readOnly` e bloqueio para tool destrutiva/escrita via Agent Gateway / IAM / SGP.
   - **Cenário de Observabilidade / Auditoria**: Verifica nos logs/traces (`Cloud Logging` ou `Cloud Trace`) se o veredito de segurança ou span de telemetria foi devidamente registrado.
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
   - **Upgrade de SDK (`--upgrade-sdk`)**: Atualiza os pacotes Python do `.venv` (`google-cloud-aiplatform[adk,agent_engines]`, `google-cloud-storage`, etc.) para detectar quebras de SDK precocemente.
   - **Execução (`deploy.sh` + `test.sh`)**: Garante que a infraestrutura e o agente estão sincronizados no Argolis e executa todos os testes ponta a ponta.
3. **Protocolo de Auto-Healing (Em Caso de Falha `exit 1`)**:
   - O agente autônomo inspeciona os logs em `.state/ci_logs/`, diagnostica a causa raiz (drift de modelo, depreciação de classe no SDK ADK/Vertex AI ou mudança de flag no `gcloud`), aplica o fix no código, reexecuta `deploy.sh` + `test.sh` para deixar o ambiente de demo 100% operacional no Argolis e registra uma **Issue + Pull Request** no repositório GitHub (`carlosmscabral/cabral-governance-ai`).

---

## 5. Console Visual de Demonstração (`tools/agent-console/`)

Para apresentações ao vivo sem depender apenas de `curl` no terminal, o repositório inclui o **Agent Console & Wire Inspector** ([`tools/agent-console/`](./tools/agent-console/README.md)):

1. **Modos de Uso**:
   - **Plugin Nativo do Jetski Web**: `./tools/agent-console/install_jetski_plugin.sh` instala o painel lateral (`~/.gemini/config/plugins/agent_console/`) servido via ÜberProxy.
   - **Servidor Local Standalone**: `./tools/agent-console/start.sh` inicia em `http://127.0.0.1:8090`.
2. **Integração Automática com Demos**:
   - O console descobre automaticamente qualquer pasta `demos/*` lendo `.state/agent_info.json`, `env.sh` e `scenarios.json`.
   - Sempre que criar uma nova demo, inclua um arquivo `scenarios.json` com os atos da demonstração (`safe`, `dlp`, `attack`) para habilitar o disparo em 1 clique no console.
