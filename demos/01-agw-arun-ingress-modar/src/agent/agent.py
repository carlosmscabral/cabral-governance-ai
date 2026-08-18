"""Agente CRM para Consulta Segura de Dados de Clientes no Google Cloud Storage."""

import os
from google.adk.agents import LlmAgent
from google.adk.models.google_llm import Gemini
from google.cloud import storage

# Configuração de Ambiente e Model Location (Global)
data_bucket = os.getenv("DATA_BUCKET", "")
model_name = os.getenv("MODEL_NAME", "gemini-flash-latest")
model_location = os.getenv("MODEL_LOCATION", "global")
project_id = os.getenv("PROJECT_ID", os.getenv("GOOGLE_CLOUD_PROJECT", ""))

client_kwargs = {
    "vertexai": True,
    "location": model_location,
}
if project_id:
    client_kwargs["project"] = project_id

# Instancia o modelo Gemini com localização global
llm = Gemini(
    model=model_name,
    client_kwargs=client_kwargs,
)


def list_customer_files() -> list[str]:
    """Lista todos os arquivos CSV de clientes disponíveis no repositório Cloud Storage.

    Returns:
        list[str]: Lista de nomes de arquivos disponíveis no bucket de dados de clientes.
    """
    if not data_bucket:
        return ["Erro: A variável de ambiente DATA_BUCKET não foi configurada."]
    try:
        client = storage.Client()
        bucket = client.bucket(data_bucket)
        blobs = bucket.list_blobs()
        return [blob.name for blob in blobs]
    except Exception as e:
        return [f"Erro ao acessar o bucket '{data_bucket}': {str(e)}"]


def read_customer_file(file_name: str) -> str:
    """Lê o conteúdo textual de um arquivo específico de dados de clientes no Cloud Storage.

    Args:
        file_name (str): Nome do arquivo a ser lido (ex: customers_west.csv).

    Returns:
        str: Conteúdo do arquivo CSV ou mensagem de erro.
    """
    if not data_bucket:
        return "Erro: A variável de ambiente DATA_BUCKET não foi configurada."
    try:
        client = storage.Client()
        bucket = client.bucket(data_bucket)
        blob = bucket.blob(file_name)
        return blob.download_as_text()
    except Exception as e:
        return f"Erro ao ler o arquivo '{file_name}' no bucket '{data_bucket}': {str(e)}"


# Definição do Agente ADK em Português do Brasil (PT-BR)
root_agent = LlmAgent(
    model=llm,
    name="agent_crm",
    description="Agente corporativo de consulta a dados de CRM e clientes armazenados de forma segura no Google Cloud Storage.",
    instruction=f"""Você é o "Agente de Consulta de Dados de Clientes", um assistente de IA corporativo especializado cujo propósito exclusivo é responder a perguntas de usuários recuperando e analisando registros no Google Cloud Storage (GCS).

ESCOPO E CAPACIDADES:
1. Você possui ferramentas nativas autorizadas ([list_customer_files] e [read_customer_file]) para consultar dados armazenados no bucket: {data_bucket}.
2. Sempre que o usuário perguntar sobre clientes, regiões (leste, oeste, vip), contatos ou dados cadastrais, você deve consultar o bucket GCS.
3. Você é um assistente estritamente factual e preciso.

DIRETRIZES DE LINGUAGEM E OPERAÇÃO (ESTRITAS):
- SEMPRE responda ao usuário em Português do Brasil (PT-BR).
- Nunca invente informações de clientes ou utilize dados fora dos arquivos do repositório.
- Fluxo de consulta:
  1. Use [list_customer_files] para encontrar os arquivos CSV relevantes.
  2. Use [read_customer_file] para ler o conteúdo do arquivo pertinente.
  3. Responda à pergunta do usuário de forma clara, educada e direta em Português do Brasil.
- Se a informação solicitada não estiver presente nos arquivos, informe educadamente: "Não foi possível encontrar essa informação no repositório de clientes cadastrados."
- Recuse qualquer solicitação que fuja do escopo de consulta aos dados de clientes (ex: programação, criação de histórias, assuntos não relacionados).""",
    tools=[list_customer_files, read_customer_file],
)
