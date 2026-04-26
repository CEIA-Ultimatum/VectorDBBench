# Guia Passo-a-Passo: Benchmarks com VectorDBBench + UV

Este guia detalhado vai te ajudar a configurar o ambiente com `uv` (gerenciador de pacotes Python ultrarrápido) e executar benchmarks para **pgvector**, **Elasticsearch** e **OpenSearch**.

---

## 📋 Sumário

1. [Instalar UV](#1-instalar-uv)
2. [Configurar Ambiente](#2-configurar-ambiente)
3. [Repositório Git e submódulo `banco-de-dados-jurisprudencia`](#3-repositório-git-e-submódulo-banco-de-dados-jurisprudencia)
4. [Instalar Dependências](#4-instalar-dependências)
5. [Configurar Variáveis de Ambiente](#5-configurar-variáveis-de-ambiente)
6. [Preparar Bancos de Dados](#6-preparar-bancos-de-dados)
7. [Executar Benchmarks](#7-executar-benchmarks)
8. [Onde estão e como ver os resultados](#8-onde-estão-e-como-ver-os-resultados)

---

## 1. Instalar UV

### Linux/macOS

```bash
# Instalar UV usando o script oficial
curl -LsSf https://astral.sh/uv/install.sh | sh

# Ou usando pip (se já tiver Python)
pip install uv

# Verificar instalação
uv --version  # Deve mostrar algo como uv 0.5.x
```

### Windows (PowerShell)

```powershell
# Usando PowerShell
powershell -c "irm https://astral.sh/uv/install.ps1 | iex"

# Verificar
uv --version
```

---

## 2. Configurar Ambiente

### 2.1 Criar diretório de trabalho

```bash
# Clone o repositório (ou fork deste guia) e, se fizer parte do vosso fluxo, os submódulos
git clone <url-do-repositório>
cd vectordbbench
git submodule update --init --recursive

# Exemplo de caminho local
cd /home/marcos/vectordbbench

# Verificar arquivos
ls -la
```

### 2.2 Inicializar projeto UV

```bash
# Inicializar o projeto (cria pyproject.toml se não existir)
uv init

# OU se já tiver pyproject.toml, apenas sincronize:
uv sync
```

### 2.3 Criar virtual environment

```bash
# Criar e ativar ambiente virtual
uv venv

# Ativar no Linux/macOS
source .venv/bin/activate

# Ativar no Windows (PowerShell)
.venv\Scripts\Activate.ps1

# Ativar no Windows (CMD)
.venv\Scripts\activate.bat
```

---

## 3. Repositório Git e submódulo `banco-de-dados-jurisprudencia`

O script `run_benchmarks_sequential.sh` sobe os bancos de benchmark a partir de **Docker Compose** no projeto **`banco-de-dados-jurisprudencia`** (caminho esperado na raiz deste repositório: `banco-de-dados-jurisprudencia/docker/benchmark`).

Clonar esse repositório **como submódulo** (substitua a URL pelo remoto do seu time ou do fork):

```bash
# Na raiz de vectordbbench
git submodule add <URL-DO-REPO-banco-de-dados-jurisprudencia> banco-de-dados-jurisprudencia
git submodule update --init --recursive
```

Quem já clonou o bench **sem** submódulo:

```bash
git submodule update --init --recursive
```

Depois, confirme o compose:

```bash
test -d banco-de-dados-jurisprudencia/docker/benchmark && echo "OK" || echo "Ajuste o submódulo ou o path no script"
```

> **Nota:** Se `run_benchmarks_sequential.sh` apontar para outro path absoluto no teu ambiente, alinha a variável `DOCKER_DIR` no script ou coloca o clone em `banco-de-dados-jurisprudencia/` na raiz.

---

## 4. Instalar Dependências

### 4.1 Instalar VectorDBBench com todos os clientes necessários

```bash
# Instalar versão base
uv pip install vectordb-bench

# Instalar com suporte a pgvector
uv pip install 'vectordb-bench[pgvector]'

# Instalar com suporte a Elasticsearch
uv pip install 'vectordb-bench[elastic]'

# Instalar com suporte a OpenSearch
uv pip install 'vectordb-bench[opensearch]'

# Ou instalar TUDO de uma vez (desenvolvimento)
uv pip install -e '.[test]'

# Instalar dependências adicionais para o script de automação
uv pip install pyyaml python-dotenv
```

### 4.2 Verificar instalação

```bash
# Listar pacotes instalados
uv pip list | grep -E "(vector|elastic|open|pg)"

# Verificar se o comando funciona
vectordbbench --help
```

---

## 5. Configurar Variáveis de Ambiente

### 5.1 Copiar arquivo de exemplo

```bash
# Copiar arquivo de exemplo
cp .env.example .env

# Editar com seus valores
nano .env
# ou
vim .env
# ou use seu editor preferido
```

### 5.2 Preencher o arquivo .env

```bash
# Exemplo de configuração mínima para testes locais:

# PostgreSQL (pgvector)
PG_USER=postgres
PG_PASSWORD=sua_senha_segura
PG_HOST=localhost
PG_PORT=5432
PG_DB=vectordb

# Elasticsearch (self-hosted)
ES_HOST=localhost
ES_PORT=9200
ES_SCHEME=https
ES_USER=elastic
ES_PASSWORD=senha_do_elastic

# OpenSearch (self-hosted)
OS_HOST=localhost
OS_PORT=9200
OS_USER=admin
OS_PASSWORD=admin
```

### 5.3 Carregar variáveis automaticamente

```bash
# Instalar autoenv (opcional, mas recomendado)
# Ou simplesmente carregue antes de executar:
source .env
```

---

## 6. Preparar Bancos de Dados

### 6.1 PostgreSQL com pgvector

```bash
# Usando Docker (mais fácil)
docker run -d \
  --name postgres-pgvector \
  -e POSTGRES_PASSWORD=${PG_PASSWORD} \
  -e POSTGRES_DB=${PG_DB} \
  -p ${PG_PORT}:5432 \
  pgvector/pgvector:pg16

# Ou instalação local (Ubuntu/Debian)
# sudo apt-get install postgresql-16-pgvector

# Criar extensão pgvector no banco
docker exec -it postgres-pgvector psql -U ${PG_USER} -d ${PG_DB} -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

### 6.2 Elasticsearch

```bash
# Usando Docker (versão com suporte a vetores)
docker run -d \
  --name elasticsearch \
  -e discovery.type=single-node \
  -e xpack.security.enabled=true \
  -e ELASTIC_PASSWORD=${ES_PASSWORD} \
  -p ${ES_PORT}:9200 \
  -p 9300:9300 \
  docker.elastic.co/elasticsearch/elasticsearch:8.15.0

# Aguardar inicialização (pode levar 30-60s)
sleep 30

# Testar conexão
curl -k -u ${ES_USER}:${ES_PASSWORD} https://localhost:${ES_PORT}
```

### 6.3 OpenSearch

```bash
# Usando Docker
docker run -d \
  --name opensearch \
  -e discovery.type=single-node \
  -e plugins.security.disabled=false \
  -e OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OS_PASSWORD} \
  -p ${OS_PORT}:9200 \
  -p 9600:9600 \
  opensearchproject/opensearch:2.15.0

# Aguardar inicialização
sleep 45

# Testar conexão
curl -k -u ${OS_USER}:${OS_PASSWORD} https://localhost:${OS_PORT}
```

---

## 7. Executar Benchmarks

### 7.1 Listar testes disponíveis

```bash
# Usando o script de automação
python run_benchmarks.py --list

# Ou usando UV
uv run python run_benchmarks.py --list
```

### 7.2 Executar testes específicos

```bash
# Executar apenas pgvector (teste rápido)
python run_benchmarks.py --db pgvector --dry-run

# Executar de verdade (sem dry-run)
python run_benchmarks.py --db pgvector

# Executar apenas Elasticsearch
python run_benchmarks.py --db elasticsearch

# Executar apenas OpenSearch
python run_benchmarks.py --db opensearch

# Executar TODOS
python run_benchmarks.py --db all
```

### 7.3 Usar vectordbbench diretamente

```bash
# Ver ajuda geral
vectordbbench --help

# Ver ajuda de um comando específico
vectordbbench pgvectorhnsw --help

# Executar batch diretamente (sem script)
vectordbbench batchcli --batch-config-file benchmark_config.yaml.expanded
```

### 7.4 Executar teste individual

```bash
# Teste rápido - 50K vetores (pgvector)
vectordbbench pgvectorhnsw \
  --user-name ${PG_USER} \
  --password ${PG_PASSWORD} \
  --host ${PG_HOST} \
  --port ${PG_PORT} \
  --db-name ${PG_DB} \
  --case-type Performance1536D50K \
  --m 16 \
  --ef-construction 128 \
  --ef-search 128

# Teste médio - 1M vetores (Elasticsearch)
vectordbbench elasticcloudhnsw \
  --host ${ES_HOST} \
  --port ${ES_PORT} \
  --user ${ES_USER} \
  --password ${ES_PASSWORD} \
  --scheme ${ES_SCHEME} \
  --case-type Performance768D1M \
  --m 16 \
  --ef-construction 100 \
  --num-candidates 100

# Teste médio - 1M vetores (OpenSearch)
vectordbbench ossopensearch \
  --host ${OS_HOST} \
  --port ${OS_PORT} \
  --user ${OS_USER} \
  --password ${OS_PASSWORD} \
  --case-type Performance768D1M \
  --m 16 \
  --ef-construction 200 \
  --engine faiss
```

### 7.5 `run_benchmarks_sequential.sh` (pgvector, Elasticsearch, OpenSearch)

O script sobe **um banco de cada vez** via Docker (requer o [submódulo](#3-repositório-git-e-submódulo-banco-de-dados-jurisprudencia) e o path `docker/benchmark` resolvido), executa o bench e, opcionalmente, grava um diretório de lote com logs e resumo.

Exemplos:

```bash
# Todos os bancos, dataset 50K
./run_benchmarks_sequential.sh --dataset 50k

# Todos, dataset 1M, diretório de saída explícito
./run_benchmarks_sequential.sh --dataset 1m --results-dir results/meu_lote_001

# Ajuda
./run_benchmarks_sequential.sh --help
```

Cada execução gera (ou adiciona) ficheiros JSON em **`vectordb_bench/results/`**. O diretório de lote em `results/` (ex.: `results/batch_50k_1m_*`) reúne `benchmark.log` e `summary.txt`; a **UI** usa preferencialmente os JSON em `vectordb_bench/results/` (ver [§8](#8-onde-estão-e-como-ver-os-resultados)).

---

## 8. Onde estão e como ver os resultados

### 8.1 Fonte principal: JSONs do VectorDBBench

A referência deste repositório é a pasta **`vectordb_bench/results/`**, com um subdiretório por backend:

- `vectordb_bench/results/PgVector/` — pgvector
- `vectordb_bench/results/ElasticCloud/` — Elasticsearch (naming upstream; o client local pode apontar para *self-hosted*)
- `vectordb_bench/results/OSSOpenSearch/` — OpenSearch

Padrão de ficheiro: `result_YYYYMMDD_<id>_<sufixo>.json` (métricas, latências, *recall*, etc., normalmente em uma linha JSON).

```bash
find vectordb_bench/results -name 'result_*.json' -type f
python -m json.tool "vectordb_bench/results/PgVector/result_20260101_exemplo_pgvector.json" | less
```

**Cache dos datasets** (ficheiros `.parquet`, etc.): por omissão muitas vezes em `/tmp/vectordb_bench/dataset/`. Pode definir-se `VDBBENCH_DATASET_PATH` para outro sítio.

### 8.2 Pastas de lote (execução com `run_benchmarks_sequential.sh`)

Diretórios como `results/20260425_155524` (timestamp) ou `results/batch_50k_1m_*` (com `--results-dir` ou nome por defeito) contêm **`benchmark.log`**, **`summary.txt`** e, consoante o padrão de cópia do script, subpastas `pgvector_50k/`, `elasticsearch_1m/`, etc. (algumas destas subpastas podem ficar vazias: os JSON oficiais continuam em [8.1](#81-fonte-principal-jsons-do-vectordbbench)). **A comparação em gráficos (Streamlit) usa sempre a pasta** `vectordb_bench/results/`.

### 8.3 Gráficos e comparação entre bancos (Streamlit)

O *frontend* lê **todos** os `result_*.json` em `vectordb_bench/results/` e mostra comparação por *case* (QPS, latência, *recall*, etc.). A comparação é feita no browser, não gera relatorio PNG predefinido nessa pasta.

```bash
uv run python -m vectordb_bench
# ou
streamlit run vectordb_bench/frontend/vdbbench.py
# se existir
init_bench
```

1. No browser: **http://localhost:8501** (padrão Streamlit)  
2. Na **barra lateral**, seleciona os *runs* e o *case*; os gráficos comparam *labels* (p.ex. pgvector vs OpenSearch vs Elasticsearch) no mesmo *dataset*  
3. Usa o botão de partilhar/exportar na página, se a tua build o expuser

### 8.4 Logs de execução (CLI do bench)

```bash
ls -la vectordb_bench/logs/
tail -f vectordb_bench/logs/*.log
```

---

## 🔧 Troubleshooting

### Problema: `banco-de-dados-jurisprudencia` ou `docker/benchmark` em falta

O `run_benchmarks_sequential.sh` espera o repositório em `banco-de-dados-jurisprudencia/` (tipicamente submódulo; ver [§3](#3-repositório-git-e-submódulo-banco-de-dados-jurisprudencia)). Sem isso, o *compose* do benchmark não encontra os ficheiros. Confirma `ls banco-de-dados-jurisprudencia/docker/benchmark` após `git submodule update --init --recursive`.

### Problema: `command not found: uv`

```bash
# Adicionar ao PATH
export PATH="$HOME/.cargo/bin:$PATH"

# Ou recarregar shell
source ~/.bashrc  # ou ~/.zshrc
```

### Problema: Datasets não baixam

```bash
# Diretório padrão de datasets
mkdir -p ~/vectordb_bench/dataset

# Ou definir variável de ambiente
export VDBBENCH_DATASET_PATH=/caminho/customizado
```

### Problema: Erro de conexão com Elasticsearch/OpenSearch

```bash
# Verificar se containers estão rodando
docker ps

# Verificar logs
docker logs elasticsearch
docker logs opensearch

# Testar conexão manual
curl -k -u elastic:senha https://localhost:9200
curl -k -u admin:admin https://localhost:9200
```

### Problema: Out of Memory (OOM)

```bash
# Para testes grandes, aumentar swap ou usar datasets menores
# Use Performance1536D50K em vez de Performance768D10M

# Ou configure limites de memória do Docker
docker update --memory=32g --memory-swap=64g postgres-pgvector
```

---

## 📊 Resumo dos Datasets

| Dataset | Case Type | Tamanho | Dimensões | Tempo Estimado |
|---------|-----------|---------|-----------|----------------|
| OpenAI Small | Performance1536D50K | 50K | 1536 | ~5 min |
| Cohere 1M | Performance768D1M | 1M | 768 | ~30-60 min |
| OpenAI 500K | Performance1536D500K | 500K | 1536 | ~20-30 min |
| Cohere 10M | Performance768D10M | 10M | 768 | ~4-8 horas |
| OpenAI 5M | Performance1536D5M | 5M | 1536 | ~3-6 horas |

---

## 🚀 Fluxo Rápido (Cheat Sheet)

```bash
# 1. Instalar UV
curl -LsSf https://astral.sh/uv/install.sh | sh

# 2. Clonar o repositório (e submódulo, se usares run_benchmarks_sequential.sh)
cd /home/marcos/vectordbbench
git submodule update --init --recursive

# 3. Configurar ambiente
uv venv && source .venv/bin/activate

# 4. Instalar dependências
uv pip install 'vectordb-bench[pgvector,elastic,opensearch]' pyyaml python-dotenv

# 5. Configurar .env
cp .env.example .env
# (editar .env com suas credenciais)

# 6. Subir bancos (exemplo manual; alternativa: run_benchmarks_sequential.sh)
docker run -d --name pgvector -e POSTGRES_PASSWORD=postgres -p 5432:5432 pgvector/pgvector:pg16
docker run -d --name elastic -e ELASTIC_PASSWORD=elastic -e discovery.type=single-node -p 9200:9200 docker.elastic.co/elasticsearch/elasticsearch:8.15.0

# 7. Executar teste rápido
python run_benchmarks.py --db pgvector --dry-run  # primeiro teste
python run_benchmarks.py --db pgvector             # executar de verdade

# 8. Ver resultados (JSON em vectordb_bench/results/; gráficos: Streamlit)
# ver secção 8 do README
init_bench  # ou: streamlit run vectordb_bench/frontend/vdbbench.py
```

---

## 📝 Notas Importantes

1. **Datasets são baixados automaticamente** na primeira execução (pode demorar)
2. **Timeout padrão**: 2.5 horas para 1M vetores, 25 horas para 10M
3. **Ficheiros de resultado (JSON):** `vectordb_bench/results/<Backend>/result_*.json` — comparação em gráfico: **Streamlit** (ver [§8.3](#83-gráficos-e-comparação-entre-bancos-streamlit)). Lotes com `run_benchmarks_sequential.sh` podem ainda criar `results/batch_*` com `benchmark.log` e resumo; a UI lê a pasta do VectorDBBench, não o lote.
4. **Submódulo** `banco-de-dados-jurisprudencia` necessário para o Docker usado por `run_benchmarks_sequential.sh` (ver [§3](#3-repositório-git-e-submódulo-banco-de-dados-jurisprudencia))
5. **Use `--dry-run`** para validar configuração antes de executar
6. **Teste primeiro com 50K** (Performance1536D50K) para validar o setup

---

## 📚 Recursos Adicionais

- [Documentação oficial VectorDBBench](https://github.com/zilliztech/VectorDBBench)
- [UV Documentation](https://docs.astral.sh/uv/)
- [pgvector Documentation](https://github.com/pgvector/pgvector)
- [Elasticsearch Vector Search](https://www.elastic.co/guide/en/elasticsearch/reference/current/knn-search.html)
- [OpenSearch k-NN](https://opensearch.org/docs/latest/search-plugins/knn/index/)
