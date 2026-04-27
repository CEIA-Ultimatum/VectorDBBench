#!/bin/bash
#
# Script de Benchmark Sequencial para VectorDBBench
# Sobe um banco por vez, executa um teste por vez
# Uso: ./run_benchmarks_sequential.sh --dataset <50k|500k|1m|10m|1024d> [opcoes]
#

set -e  # Exit on error

# ============================================================================
# CONFIGURACOES GLOBAIS
# ============================================================================

# Diretorios
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# O codigo deste repo expoe elasticcloudhnsw com --host/--port (ES self-hosted). Um
# vectordb-bench antigo no venv so mostra --cloud-id; priorizamos o pacote local.
export PYTHONPATH="${SCRIPT_DIR}${PYTHONPATH:+:$PYTHONPATH}"
# Nao exige 'source .venv/bin/activate' se o venv estiver em SCRIPT_DIR/.venv
if [[ -d "${SCRIPT_DIR}/.venv/bin" ]]; then
    export PATH="${SCRIPT_DIR}/.venv/bin:${PATH}"
fi
DOCKER_DIR="/home/marcos/banco-de-dados-jurisprudencia/docker/benchmark"
RESULTS_BASE_DIR="${SCRIPT_DIR}/results"
LOG_DIR="${RESULTS_BASE_DIR}"

# Configuracoes dos containers
POSTGRES_CONTAINER="bench-postgres"
ELASTICSEARCH_CONTAINER="bench-elasticsearch"
OPENSEARCH_CONTAINER="bench-opensearch"

POSTGRES_PORT=5434
ELASTICSEARCH_PORT=9201
OPENSEARCH_PORT=9200

# Timeouts (em segundos)
HEALTHCHECK_TIMEOUT=600  # 10 minutos (primeira inicialização pode demorar)
HEALTHCHECK_INTERVAL=5

# ============================================================================
# VARIAVEIS DE CONTROLE
# ============================================================================

DATASET=""
TARGET_DB="all"
SKIP_CLEANUP=false
DRY_RUN=false
KEEP_DATA=false
RESULTS_DIR=""
TIMESTAMP=""
LOG_FILE=""

# Mapeamento de datasets para case_types
declare -A DATASET_MAP=(
    ["50k"]="Performance1536D50K"
    ["500k"]="Performance1536D500K"
    ["1m"]="Performance768D1M"
    ["10m"]="Performance768D10M"
    ["1024d"]="Performance1024D1M"
)

# Descricoes dos datasets
declare -A DATASET_DESC=(
    ["50k"]="50K vetores, 1536 dim (OpenAI) - Teste rapido (~5 min)"
    ["500k"]="500K vetores, 1536 dim (OpenAI) - Medio (~20-30 min)"
    ["1m"]="1M vetores, 768 dim (Cohere) - Padrao (~30-60 min)"
    ["10m"]="10M vetores, 768 dim (Cohere) - Grande (~4-8 horas)"
    ["1024d"]="1M vetores, 1024 dim (Bioasq) - Especializado (~30-60 min)"
)

# ============================================================================
# FUNCOES DE UTILIDADE
# ============================================================================

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message"
    if [[ -n "$LOG_FILE" && -d "$(dirname "$LOG_FILE")" ]]; then
        echo "$message" >> "$LOG_FILE"
    fi
}

error() {
    log "ERRO: $1"
    exit 1
}

warning() {
    log "AVISO: $1"
}

info() {
    log "INFO: $1"
}

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] $1"
    else
        log "EXECUTANDO: $1"
        eval "$1"
    fi
}

# ============================================================================
# FUNCAO DE AJUDA
# ============================================================================

usage() {
    cat << EOF
Uso: $0 --dataset <DATASET> [OPCOES]

DATASETS OBRIGATORIOS (escolha um):
  --dataset 50k        Performance1536D50K - 50K vetores, 1536 dim (~5 min)
  --dataset 500k       Performance1536D500K - 500K vetores, 1536 dim (~20-30 min)
  --dataset 1m         Performance768D1M - 1M vetores, 768 dim (~30-60 min)
  --dataset 10m        Performance768D10M - 10M vetores, 768 dim (~4-8 horas)
  --dataset 1024d      Performance1024D1M - 1M vetores, 1024 dim (~30-60 min)
  --dataset all        Executa TODOS os datasets sequencialmente (MUITO LENTO!)

OPCOES DE BANCO (padrao: todos):
  --db pgvector        Apenas PostgreSQL/pgvector
  --db elasticsearch   Apenas Elasticsearch
  --db opensearch      Apenas OpenSearch

OUTRAS OPCOES:
  --skip-cleanup       Nao derrubar containers apos os testes
  --keep-data          Manter volumes Docker entre execucoes
  --dry-run            Apenas mostrar comandos, nao executar
  --results-dir DIR    Diretorio customizado para resultados (padrao: results/YYYYMMDD_HHMMSS)
  -h, --help           Mostrar esta ajuda

EXEMPLOS:
  # Teste rapido em todos os bancos
  $0 --dataset 50k

  # Teste medio apenas no PostgreSQL
  $0 --dataset 1m --db pgvector

  # Apenas Elasticsearch e OpenSearch
  $0 --dataset 500k --db elasticsearch --db opensearch

  # Dry-run para validar comandos
  $0 --dataset 50k --dry-run

  # Manter containers rodando apos teste
  $0 --dataset 1m --skip-cleanup

EOF
    exit 0
}

# ============================================================================
# PARSE DE ARGUMENTOS
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dataset)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    DATASET="$2"
                    shift 2
                else
                    error "--dataset requer um valor (50k, 500k, 1m, 10m, 1024d, all)"
                fi
                ;;
            --db)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    if [[ "$2" =~ ^(pgvector|elasticsearch|opensearch)$ ]]; then
                        if [[ "$TARGET_DB" == "all" ]]; then
                            TARGET_DB="$2"
                        else
                            TARGET_DB="${TARGET_DB},$2"
                        fi
                        shift 2
                    else
                        error "Banco invalido: $2. Use: pgvector, elasticsearch, opensearch"
                    fi
                else
                    error "--db requer um valor"
                fi
                ;;
            --skip-cleanup)
                SKIP_CLEANUP=true
                shift
                ;;
            --keep-data)
                KEEP_DATA=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --results-dir)
                if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                    RESULTS_DIR="$2"
                    shift 2
                else
                    error "--results-dir requer um caminho"
                fi
                ;;
            -h|--help)
                usage
                ;;
            *)
                error "Opcao desconhecida: $1"
                ;;
        esac
    done

    # Validacoes
    if [[ -z "$DATASET" ]]; then
        error "Dataset obrigatorio! Use --dataset <50k|500k|1m|10m|1024d|all>"
    fi

    if [[ ! "$DATASET" =~ ^(50k|500k|1m|10m|1024d|all)$ ]]; then
        error "Dataset invalido: $DATASET. Use: 50k, 500k, 1m, 10m, 1024d, all"
    fi

    # Configurar diretorio de resultados
    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    if [[ -z "$RESULTS_DIR" ]]; then
        RESULTS_DIR="${RESULTS_BASE_DIR}/${TIMESTAMP}"
    fi
    LOG_FILE="${RESULTS_DIR}/benchmark.log"

    info "================================================"
    info "BENCHMARK SEQUENCIAL - VectorDBBench"
    info "================================================"
    info "Dataset: $DATASET (${DATASET_DESC[$DATASET]})"
    info "Banco(s): $TARGET_DB"
    info "Results: $RESULTS_DIR"
    info "Dry-run: $DRY_RUN"
    info "Skip-cleanup: $SKIP_CLEANUP"
    info "Keep-data: $KEEP_DATA"
    info "================================================"
    
    if [[ "$KEEP_DATA" == false ]]; then
        info "Modo RESET LIMPO: Containers/volumes serao removidos (mais rapido)"
    else
        info "Modo MANTER DADOS: Volumes preservados (recovery pode demorar se houver muitos dados)"
    fi
}

# ============================================================================
# FUNCOES DOCKER - POSTGRESQL
# ============================================================================

start_postgres() {
    info "=== INICIANDO POSTGRESQL ==="
    
    cd "$DOCKER_DIR" || error "Diretorio Docker nao encontrado: $DOCKER_DIR"
    
    # Verificar se ja esta rodando
    if docker ps --format "{{.Names}}" | grep -q "^${POSTGRES_CONTAINER}$"; then
        info "Container ${POSTGRES_CONTAINER} ja esta rodando"
        return 0
    fi
    
    # Verificar se existe mas esta parado
    if docker ps -a --format "{{.Names}}" | grep -q "^${POSTGRES_CONTAINER}$"; then
        info "Container ${POSTGRES_CONTAINER} existe mas esta parado, iniciando..."
        run_cmd "docker-compose start postgres"
    else
        # Criar novo container
        info "Criando novo container PostgreSQL..."
        info "Nota: Primeira inicialização pode levar 2-3 minutos (download da imagem + setup)"
        run_cmd "docker-compose up -d postgres"
    fi
    
    info "PostgreSQL iniciado. Aguardando healthcheck..."
}

wait_for_postgres() {
    if [[ "$DRY_RUN" == true ]]; then
        info "=== AGUARDANDO POSTGRESQL (dry-run: sem container, healthcheck ignorado) ==="
        return 0
    fi

    info "=== AGUARDANDO POSTGRESQL ==="
    
    local elapsed=0
    local ready=false
    
    # Primeiro, aguardar container ficar healthy (docker healthcheck)
    info "Verificando healthcheck do container..."
    while [[ $elapsed -lt $HEALTHCHECK_TIMEOUT ]]; do
        local health
        health=$(docker inspect --format="{{.State.Health.Status}}" "$POSTGRES_CONTAINER" 2>/dev/null || echo "none")
        
        if [[ "$health" == "healthy" ]]; then
            info "Container PostgreSQL esta healthy (${elapsed}s)"
            ready=true
            break
        fi
        
        # Mostrar progresso a cada 10s
        if [[ $((elapsed % 10)) -eq 0 && $elapsed -gt 0 ]]; then
            info "Aguardando PostgreSQL... (${elapsed}s) - status: $health"
        fi
        
        sleep $HEALTHCHECK_INTERVAL
        elapsed=$((elapsed + HEALTHCHECK_INTERVAL))
    done
    
    # Se nao ficou healthy, tentar verificar diretamente
    if [[ "$ready" == false ]]; then
        info "Healthcheck nao confirmou, verificando diretamente..."
        if docker exec "$POSTGRES_CONTAINER" pg_isready -U postgres -d psql_jurisprudencia &>/dev/null; then
            info "PostgreSQL respondeu ao pg_isready!"
            ready=true
        fi
    fi
    
    if [[ "$ready" == true ]]; then
        # Aguardar mais 5s para garantir que esta totalmente pronto
        sleep 5
        info "PostgreSQL esta pronto para conexoes!"
        return 0
    fi
    
    # Se chegou aqui, deu timeout
    error "Timeout aguardando PostgreSQL (${HEALTHCHECK_TIMEOUT}s)"
    info "Verificando logs do container..."
    docker logs "$POSTGRES_CONTAINER" --tail 20 || true
    return 1
}

stop_postgres() {
    if [[ "$SKIP_CLEANUP" == true ]]; then
        info "=== MANTENDO POSTGRESQL (skip-cleanup ativo) ==="
        return 0
    fi
    
    info "=== PARANDO POSTGRESQL ==="
    
    cd "$DOCKER_DIR" || return
    
    if [[ "$KEEP_DATA" == true ]]; then
        run_cmd "docker-compose stop postgres"
    else
        run_cmd "docker-compose rm -sf postgres"
    fi
    
    info "PostgreSQL parado"
}

# ============================================================================
# FUNCOES DOCKER - ELASTICSEARCH
# ============================================================================

start_elasticsearch() {
    info "=== INICIANDO ELASTICSEARCH ==="
    
    cd "$DOCKER_DIR" || error "Diretorio Docker nao encontrado: $DOCKER_DIR"
    
    # Verificar se ja esta rodando
    if docker ps --format "{{.Names}}" | grep -q "^${ELASTICSEARCH_CONTAINER}$"; then
        info "Container ${ELASTICSEARCH_CONTAINER} ja esta rodando"
        return 0
    fi
    
    # Verificar se existe mas esta parado
    if docker ps -a --format "{{.Names}}" | grep -q "^${ELASTICSEARCH_CONTAINER}$"; then
        info "Container ${ELASTICSEARCH_CONTAINER} existe mas esta parado, iniciando..."
        run_cmd "docker-compose start elasticsearch"
    else
        info "Criando novo container Elasticsearch..."
        info "Nota: Primeira inicialização pode levar 2-3 minutos"
        run_cmd "docker-compose up -d elasticsearch"
    fi
    
    info "Elasticsearch iniciado. Aguardando healthcheck..."
}

wait_for_elasticsearch() {
    if [[ "$DRY_RUN" == true ]]; then
        info "=== AGUARDANDO ELASTICSEARCH (dry-run: healthcheck ignorado) ==="
        return 0
    fi

    info "=== AGUARDANDO ELASTICSEARCH ==="
    
    local elapsed=0
    local url="http://localhost:${ELASTICSEARCH_PORT}/_cluster/health"
    local ready=false
    
    while [[ $elapsed -lt $HEALTHCHECK_TIMEOUT ]]; do
        local status
        status=$(curl -s "$url" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        
        if [[ "$status" == "green" || "$status" == "yellow" ]]; then
            info "Elasticsearch esta pronto! (status: $status, ${elapsed}s)"
            ready=true
            break
        fi
        
        # Mostrar progresso a cada 10s
        if [[ $((elapsed % 10)) -eq 0 && $elapsed -gt 0 ]]; then
            info "Aguardando Elasticsearch... (${elapsed}s) - status: ${status:-unknown}"
        fi
        
        sleep $HEALTHCHECK_INTERVAL
        elapsed=$((elapsed + HEALTHCHECK_INTERVAL))
    done
    
    if [[ "$ready" == true ]]; then
        # Aguardar mais 5s para garantir estabilidade
        sleep 5
        return 0
    fi
    
    error "Timeout aguardando Elasticsearch (${HEALTHCHECK_TIMEOUT}s)"
}

stop_elasticsearch() {
    if [[ "$SKIP_CLEANUP" == true ]]; then
        info "=== MANTENDO ELASTICSEARCH (skip-cleanup ativo) ==="
        return 0
    fi
    
    info "=== PARANDO ELASTICSEARCH ==="
    
    cd "$DOCKER_DIR" || return
    
    if [[ "$KEEP_DATA" == true ]]; then
        run_cmd "docker-compose stop elasticsearch"
    else
        run_cmd "docker-compose rm -sf elasticsearch"
    fi
    
    info "Elasticsearch parado"
}

# ============================================================================
# FUNCOES DOCKER - OPENSEARCH
# ============================================================================

start_opensearch() {
    info "=== INICIANDO OPENSEARCH ==="
    
    cd "$DOCKER_DIR" || error "Diretorio Docker nao encontrado: $DOCKER_DIR"
    
    # Verificar se ja esta rodando
    if docker ps --format "{{.Names}}" | grep -q "^${OPENSEARCH_CONTAINER}$"; then
        info "Container ${OPENSEARCH_CONTAINER} ja esta rodando"
        return 0
    fi
    
    # Verificar se existe mas esta parado
    if docker ps -a --format "{{.Names}}" | grep -q "^${OPENSEARCH_CONTAINER}$"; then
        info "Container ${OPENSEARCH_CONTAINER} existe mas esta parado, iniciando..."
        run_cmd "docker-compose start opensearch"
    else
        info "Criando novo container OpenSearch..."
        info "Nota: Primeira inicialização pode levar 2-3 minutos"
        run_cmd "docker-compose up -d opensearch"
    fi
    
    info "OpenSearch iniciado. Aguardando healthcheck..."
}

wait_for_opensearch() {
    if [[ "$DRY_RUN" == true ]]; then
        info "=== AGUARDANDO OPENSEARCH (dry-run: healthcheck ignorado) ==="
        return 0
    fi

    info "=== AGUARDANDO OPENSEARCH ==="
    
    local elapsed=0
    local url="http://localhost:${OPENSEARCH_PORT}/_cluster/health"
    local ready=false
    
    while [[ $elapsed -lt $HEALTHCHECK_TIMEOUT ]]; do
        local status
        status=$(curl -s "$url" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        
        if [[ "$status" == "green" || "$status" == "yellow" ]]; then
            info "OpenSearch esta pronto! (status: $status, ${elapsed}s)"
            ready=true
            break
        fi
        
        # Mostrar progresso a cada 10s
        if [[ $((elapsed % 10)) -eq 0 && $elapsed -gt 0 ]]; then
            info "Aguardando OpenSearch... (${elapsed}s) - status: ${status:-unknown}"
        fi
        
        sleep $HEALTHCHECK_INTERVAL
        elapsed=$((elapsed + HEALTHCHECK_INTERVAL))
    done
    
    if [[ "$ready" == true ]]; then
        # Aguardar mais 5s para garantir estabilidade
        sleep 5
        return 0
    fi
    
    error "Timeout aguardando OpenSearch (${HEALTHCHECK_TIMEOUT}s)"
}

stop_opensearch() {
    if [[ "$SKIP_CLEANUP" == true ]]; then
        info "=== MANTENDO OPENSEARCH (skip-cleanup ativo) ==="
        return 0
    fi
    
    info "=== PARANDO OPENSEARCH ==="
    
    cd "$DOCKER_DIR" || return
    
    if [[ "$KEEP_DATA" == true ]]; then
        run_cmd "docker-compose stop opensearch"
    else
        run_cmd "docker-compose rm -sf opensearch"
    fi
    
    info "OpenSearch parado"
}

# ============================================================================
# FUNCOES DE BENCHMARK
# ============================================================================
# Criterios de alinhamento (comparacao justa entre ES, OpenSearch e pgvector):
# - Mesmos M e ef_construction por faixa de dataset (ver case em cada funcao).
# - Mesma "largura" de busca HNSW: pgvector --ef-search = ES --num-candidates =
#   OpenSearch --ef-search (inclui 10m; todos 200 neste script).
# - Sem quantizacao adicional no pgvector: --quantization-type/--table-quantization-type none
#   (mapeia para tipo vector float, como float32 no ES/OS sem quant in-memory).
# - OpenSearch: engine faiss in-memory alinhado ao uso tipico do knn-plugin; threads
#   de indexacao/force merge explicitos para nao ficar no default baixo da CLI.
# Parametros so de build (maintenance_work_mem, max_parallel_workers no pgvector;
# merge_max_thread_count no ES) nao tem equivalente 1:1 entre motores.

run_pgvector_benchmark() {
    local dataset_key="$1"
    local case_type="${DATASET_MAP[$dataset_key]}"
    
    info "=== BENCHMARK PGVECTOR - $case_type ==="
    
    # Criar diretorio para resultados deste banco
    local pg_results="${RESULTS_DIR}/pgvector_${dataset_key}"
    mkdir -p "$pg_results"
    
    # Parametros baseados no dataset
    local m=16
    local ef_construction=128
    # Alinhado a num_candidates (ES) / ef_search (OpenSearch) em todo o script
    local ef_search=200
    local maintenance_work_mem="4GB"
    local max_parallel_workers=4
    
    # Ajustar parametros para datasets maiores
    case "$dataset_key" in
        "1m"|"1024d")
            ef_construction=200
            ef_search=200
            maintenance_work_mem="16GB"
            max_parallel_workers=8
            ;;
        "10m")
            ef_construction=256
            ef_search=200
            maintenance_work_mem="64GB"
            max_parallel_workers=16
            ;;
    esac
    
    # Construir comando como string unica
    local cmd="vectordbbench pgvectorhnsw"
    cmd="${cmd} --user-name postgres"
    cmd="${cmd} --password postgres"
    cmd="${cmd} --host localhost"
    cmd="${cmd} --port ${POSTGRES_PORT}"
    cmd="${cmd} --db-name psql_jurisprudencia"
    cmd="${cmd} --case-type ${case_type}"
    cmd="${cmd} --m ${m}"
    cmd="${cmd} --ef-construction ${ef_construction}"
    cmd="${cmd} --ef-search ${ef_search}"
    # none -> tipo vector float (equivalente a vetores completos; evita halfvec/bit)
    cmd="${cmd} --quantization-type none"
    cmd="${cmd} --table-quantization-type none"
    cmd="${cmd} --maintenance-work-mem ${maintenance_work_mem}"
    cmd="${cmd} --max-parallel-workers ${max_parallel_workers}"
    cmd="${cmd} --db-label pgvector_${dataset_key}_${TIMESTAMP}"
    
    run_cmd "$cmd"
    
    # Copiar resultados
    if [[ "$DRY_RUN" == false ]]; then
        find "$SCRIPT_DIR/vectordb_bench/results" -name "*pgvector*${TIMESTAMP}*" -exec cp {} "$pg_results/" \; 2>/dev/null || true
    fi
    
    info "Benchmark pgvector concluido"
}

run_elasticsearch_benchmark() {
    local dataset_key="$1"
    local case_type="${DATASET_MAP[$dataset_key]}"
    
    info "=== BENCHMARK ELASTICSEARCH - $case_type ==="
    
    # Criar diretorio para resultados deste banco
    local es_results="${RESULTS_DIR}/elasticsearch_${dataset_key}"
    mkdir -p "$es_results"
    
    # HNSW alinhado a run_opensearch_benchmark: mesmo M, ef_construction, e
    # num_candidates equivalente a ef_search no OpenSearch.
    local m=16
    local ef_construction=128
    local num_candidates=200
    local num_shards=1
    
    # Ajustar parametros para datasets maiores
    case "$dataset_key" in
        "1m"|"1024d")
            ef_construction=200
            num_candidates=200
            ;;
        "10m")
            ef_construction=256
            num_candidates=200
            num_shards=3
            ;;
    esac
    
    # Construir comando como string unica (evita problemas com argumentos vazios)
    local cmd="vectordbbench elasticcloudhnsw"
    cmd="${cmd} --host localhost"
    cmd="${cmd} --port ${ELASTICSEARCH_PORT}"
    cmd="${cmd} --scheme http"
    cmd="${cmd} --user elastic"
    cmd="${cmd} --password=''"
    cmd="${cmd} --case-type ${case_type}"
    cmd="${cmd} --m ${m}"
    cmd="${cmd} --ef-construction ${ef_construction}"
    cmd="${cmd} --num-candidates ${num_candidates}"
    # float32: alinhado ao pgvector (vector float) e OS (sem quantizacao)
    cmd="${cmd} --element-type float"
    cmd="${cmd} --number-of-shards ${num_shards}"
    cmd="${cmd} --number-of-replicas 0"
    cmd="${cmd} --refresh-interval 30s"
    # Explicito: garante force merge ligado (post-load graph optimization)
    cmd="${cmd} --use-force-merge True"
    # 8 threads de merge: simetrico ao index_thread_qty_during_force_merge do OS
    cmd="${cmd} --merge-max-thread-count 8"
    cmd="${cmd} --db-label es_${dataset_key}_${TIMESTAMP}"
    
    run_cmd "$cmd"
    
    # Copiar resultados
    if [[ "$DRY_RUN" == false ]]; then
        find "$SCRIPT_DIR/vectordb_bench/results" -name "*elastic*${TIMESTAMP}*" -exec cp {} "$es_results/" \; 2>/dev/null || true
    fi
    
    info "Benchmark Elasticsearch concluido"
}

run_opensearch_benchmark() {
    local dataset_key="$1"
    local case_type="${DATASET_MAP[$dataset_key]}"
    
    info "=== BENCHMARK OPENSEARCH - $case_type ==="
    
    # Criar diretorio para resultados deste banco
    local os_results="${RESULTS_DIR}/opensearch_${dataset_key}"
    mkdir -p "$os_results"
    
    # HNSW alinhado a run_elasticsearch_benchmark; engine faiss in-memory costuma
    # ter melhor throughput que lucene neste cliente; ef_search = num_candidates no ES.
    local m=16
    local ef_construction=128
    local ef_search=200
    local engine="faiss"
    local num_shards=1
    local index_threads=8
    local index_threads_force_merge=8
    
    # Ajustar parametros para datasets maiores
    case "$dataset_key" in
        "1m"|"1024d")
            ef_construction=200
            ef_search=200
            ;;
        "10m")
            ef_construction=256
            ef_search=200
            num_shards=3
            ;;
    esac
    
    # Construir comando como string unica
    local cmd="vectordbbench ossopensearch"
    cmd="${cmd} --host localhost"
    cmd="${cmd} --port ${OPENSEARCH_PORT}"
    cmd="${cmd} --user admin"
    cmd="${cmd} --password admin"
    # OpenAI/Cohere/Bioasq neste script: metrica COSINE (alinhado aos cases Performance*)
    cmd="${cmd} --metric-type cosine"
    cmd="${cmd} --case-type ${case_type}"
    cmd="${cmd} --m ${m}"
    cmd="${cmd} --ef-construction ${ef_construction}"
    cmd="${cmd} --ef-search ${ef_search}"
    cmd="${cmd} --engine ${engine}"
    cmd="${cmd} --index-thread-qty ${index_threads}"
    cmd="${cmd} --index_thread_qty_during_force_merge ${index_threads_force_merge}"
    cmd="${cmd} --number-of-shards ${num_shards}"
    cmd="${cmd} --number-of-replicas 0"
    # Mesmo refresh do Elasticsearch (30s) para carga/visibilidade comparavel
    cmd="${cmd} --refresh-interval 30s"
    # ossopensearch: apenas None | LuceneSQ | FaissSQfp16 (sem quantizacao in-memory = None)
    cmd="${cmd} --quantization-type None"
    cmd="${cmd} --db-label os_${dataset_key}_${TIMESTAMP}"
    
    run_cmd "$cmd"
    
    # Copiar resultados
    if [[ "$DRY_RUN" == false ]]; then
        find "$SCRIPT_DIR/vectordb_bench/results" -name "*opensearch*${TIMESTAMP}*" -exec cp {} "$os_results/" \; 2>/dev/null || true
    fi
    
    info "Benchmark OpenSearch concluido"
}

# ============================================================================
# FUNCOES DE UTILITARIO
# ============================================================================

cleanup_existing_containers() {
    info "=== VERIFICANDO E LIMPANDO CONTAINERS EXISTENTES ==="
    
    local containers=("$POSTGRES_CONTAINER" "$ELASTICSEARCH_CONTAINER" "$OPENSEARCH_CONTAINER")
    local found_any=false
    
    # Verificar se algum container esta rodando
    for container in "${containers[@]}"; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            warning "Container $container ja esta rodando"
            found_any=true
        fi
    done
    
    # Se encontrou containers rodando, perguntar (ou auto-limpar em dry-run)
    if [[ "$found_any" == true ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            info "Parando containers existentes para evitar conflitos..."
            cd "$DOCKER_DIR" || return
            
            # Parar todos os containers do compose
            run_cmd "docker-compose stop postgres elasticsearch opensearch"
            
            # Se NAO usar --keep-data, remover volumes tambem (limpeza completa)
            if [[ "$KEEP_DATA" == false ]]; then
                info "Removendo containers E volumes para reset limpo..."
                run_cmd "docker-compose down -v --remove-orphans"
                info "Containers e volumes removidos (reset limpo - proximo start sera mais rapido)"
            else
                run_cmd "docker-compose rm -sf postgres elasticsearch opensearch"
                info "Containers parados (volumes mantidos com --keep-data - recovery pode demorar)"
            fi
        else
            info "[DRY-RUN] Containers existentes seriam parados/removidos"
        fi
    else
        info "Nenhum container de benchmark encontrado rodando"
    fi
    
    # Verificar se portas estao em uso
    local ports=("$POSTGRES_PORT" "$ELASTICSEARCH_PORT" "$OPENSEARCH_PORT")
    local port_names=("PostgreSQL" "Elasticsearch" "OpenSearch")
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local name="${port_names[$i]}"
        
        if command -v lsof &> /dev/null; then
            if lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
                warning "Porta $port ($name) ja esta em uso por outro processo"
                warning "Pode haver conflito ao iniciar o container"
            fi
        elif command -v netstat &> /dev/null; then
            if netstat -tuln 2>/dev/null | grep -q ":$port "; then
                warning "Porta $port ($name) ja esta em uso"
            fi
        fi
    done
}

check_dependencies() {
    info "=== VERIFICANDO DEPENDENCIAS ==="
    
    # Verificar Docker
    if ! command -v docker &> /dev/null; then
        error "Docker nao encontrado. Instale o Docker primeiro."
    fi
    
    # Verificar docker-compose
    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose nao encontrado."
    fi
    
    # Verificar curl
    if ! command -v curl &> /dev/null; then
        error "curl nao encontrado."
    fi
    
    # Verificar VectorDBBench
    if ! command -v vectordbbench &> /dev/null; then
        warning "vectordbbench nao encontrado no PATH"
        warning "Certifique-se de ativar o ambiente virtual: source .venv/bin/activate"
    elif ! vectordbbench elasticcloudhnsw --help 2>/dev/null | grep -q -- '--host'; then
        warning "vectordbbench elasticcloudhnsw sem opcao --host (pacote antigo no venv)."
        warning "Corrija com: cd \"${SCRIPT_DIR}\" && pip install -e '.[elastic]'"
        warning "Ou confira se PYTHONPATH aponta para este clone (ja exportado pelo script)."
    fi
    
    # Verificar diretorio Docker
    if [[ ! -d "$DOCKER_DIR" ]]; then
        error "Diretorio Docker nao encontrado: $DOCKER_DIR"
    fi
    
    info "Todas as dependencias verificadas"
}

setup_results_dir() {
    info "=== CONFIGURANDO DIRETORIO DE RESULTADOS ==="
    
    mkdir -p "$RESULTS_DIR"
    
    # Criar arquivo de log
    touch "$LOG_FILE"
    
    info "Diretorio de resultados: $RESULTS_DIR"
    info "Arquivo de log: $LOG_FILE"
}

generate_summary() {
    info "=== GERANDO RESUMO ==="
    
    local summary_file="${RESULTS_DIR}/summary.txt"
    
    cat > "$summary_file" << EOF
============================================================
RESUMO DO BENCHMARK
============================================================
Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')
Dataset: $DATASET (${DATASET_DESC[$DATASET]})
Banco(s): $TARGET_DB

CONFIGURACAO:
- PostgreSQL: localhost:${POSTGRES_PORT}
- Elasticsearch: localhost:${ELASTICSEARCH_PORT}
- OpenSearch: localhost:${OPENSEARCH_PORT}
- Skip Cleanup: $SKIP_CLEANUP
- Keep Data: $KEEP_DATA

RESULTADOS:
Diretorio: $RESULTS_DIR

Arquivos:
EOF
    
    # Listar arquivos de resultados
    find "$RESULTS_DIR" -type f -name "*.json" >> "$summary_file" 2>/dev/null || echo "Nenhum arquivo JSON encontrado" >> "$summary_file"
    
    info "Resumo gerado: $summary_file"
}

run_single_dataset() {
    local dataset_key="$1"
    
    info ""
    info "============================================================"
    info "EXECUTANDO DATASET: $dataset_key"
    info "CASE TYPE: ${DATASET_MAP[$dataset_key]}"
    info "DESCRICAO: ${DATASET_DESC[$dataset_key]}"
    info "============================================================"
    
    # Verificar se deve executar pgvector
    if [[ "$TARGET_DB" == "all" || "$TARGET_DB" =~ "pgvector" ]]; then
        start_postgres
        wait_for_postgres
        run_pgvector_benchmark "$dataset_key"
        stop_postgres
        info ""
    fi
    
    # Verificar se deve executar elasticsearch
    if [[ "$TARGET_DB" == "all" || "$TARGET_DB" =~ "elasticsearch" ]]; then
        start_elasticsearch
        wait_for_elasticsearch
        run_elasticsearch_benchmark "$dataset_key"
        stop_elasticsearch
        info ""
    fi
    
    # Verificar se deve executar opensearch
    if [[ "$TARGET_DB" == "all" || "$TARGET_DB" =~ "opensearch" ]]; then
        start_opensearch
        wait_for_opensearch
        run_opensearch_benchmark "$dataset_key"
        stop_opensearch
        info ""
    fi
}

# ============================================================================
# FUNCAO PRINCIPAL
# ============================================================================

main() {
    # Parse de argumentos
    parse_args "$@"
    
    # Limpar containers existentes (evita conflitos)
    cleanup_existing_containers
    
    # Verificar dependencias
    check_dependencies
    
    # Configurar diretorio de resultados
    setup_results_dir
    
    # Executar benchmarks
    if [[ "$DATASET" == "all" ]]; then
        info "Modo 'all' selecionado. Executando todos os datasets..."
        for ds in "50k" "500k" "1m" "1024d"; do
            run_single_dataset "$ds"
        done
        # 10m e opcional e muito lento, nao incluir em 'all' por padrao
        info "Dataset 10m nao incluido no modo 'all' (muito lento). Execute manualmente se necessario."
    else
        run_single_dataset "$DATASET"
    fi
    
    # Gerar resumo
    generate_summary
    
    # Finalizacao
    info ""
    info "============================================================"
    info "BENCHMARK CONCLUIDO!"
    info "============================================================"
    info "Resultados em: $RESULTS_DIR"
    info "Log completo: $LOG_FILE"
    info "============================================================"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "MODO DRY-RUN: Nenhum teste foi realmente executado"
    fi
}

# ============================================================================
# TRAP PARA LIMPEZA EM CASO DE ERRO
# ============================================================================

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        warning "Script interrompido com erro (codigo: $exit_code)"
        
        if [[ "$SKIP_CLEANUP" == false && "$DRY_RUN" == false ]]; then
            info "Limpando containers..."
            cd "$DOCKER_DIR" 2>/dev/null || true
            docker-compose stop postgres elasticsearch opensearch 2>/dev/null || true
        fi
    fi
    exit $exit_code
}

trap cleanup_on_error EXIT

# ============================================================================
# INICIO
# ============================================================================

main "$@"
