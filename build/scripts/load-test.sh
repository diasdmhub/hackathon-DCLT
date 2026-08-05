#!/usr/bin/env bash
# Gerador de carga para a stack SolidaryTech. Simula o público externo
# interagindo com os três serviços, para produzir volume de logs observável
# no Grafana (Loki):
#
#   1. Cria ONGs (ngo-service)
#   2. Registra voluntários para cada ONG (volunteer-service)
#   3. Registra doações para cada ONG (donation-service)
#   4. Intercala consultas GET (listagens) entre os cadastros
#
# Uma fração configurável das requisições de cada tipo é enviada
# propositalmente inválida, para gerar erros conhecidos nos logs:
#   - ngo-service:       campos obrigatórios ausentes (400) ou e-mail duplicado (409)
#   - donation-service:  JSON malformado (400)
#   - volunteer-service: ngo_id não numérico (400)
#
# As requisições são disparadas com um pequeno paralelismo, simulando
# demanda concorrente.
#
# Uso: build/scripts/load-test.sh
# Variáveis de ambiente opcionais (valores padrão entre parênteses):
#   NGO_URL, DONATION_URL, VOLUNTEER_URL - base URLs dos serviços
#   NUM_NGOS           (10)  - quantidade de ONGs a criar
#   VOLUNTEERS_PER_NGO (100) - voluntários por ONG
#   DONATIONS_PER_NGO  (150) - doações por ONG
#   GETS_PER_NGO       (5)   - consultas GET por ONG
#   ERROR_RATE         (5)   - percentual de requisições inválidas por tipo
#   CONCURRENCY        (2)   - requisições simultâneas

set -euo pipefail

NGO_URL="${NGO_URL:-http://localhost:8081}"
DONATION_URL="${DONATION_URL:-http://localhost:8082}"
VOLUNTEER_URL="${VOLUNTEER_URL:-http://localhost:8083}"

NUM_NGOS="${NUM_NGOS:-10}"
VOLUNTEERS_PER_NGO="${VOLUNTEERS_PER_NGO:-100}"
DONATIONS_PER_NGO="${DONATIONS_PER_NGO:-150}"
GETS_PER_NGO="${GETS_PER_NGO:-5}"
ERROR_RATE="${ERROR_RATE:-5}"
CONCURRENCY="${CONCURRENCY:-2}"

SECONDS=0  # cronômetro do bash: mede o tempo total de execução do teste
RUN_ID="$(date +%s)-$$"
WORKDIR="$(mktemp -d)"
RESULTS="$WORKDIR/results"
NGO_IDS_FILE="$WORKDIR/ngo_ids"
: > "$RESULTS"
: > "$NGO_IDS_FILE"
trap 'rm -rf "$WORKDIR"' EXIT

log() { echo "[load-test] $*" >&2; }

# Dados fictícios para variar o conteúdo das requisições
FIRST_NAMES=(Ana Bruno Carla Diego Elisa Fábio Gabriela Hugo Íris João
    Karina Lucas Marina Nícolas Olívia Paulo Quésia Rafael Sofia Tiago
    Úrsula Vinícius Wagner Ximena Yasmin Zeca Beatriz Caio Denise Eduardo)
LAST_NAMES=(Silva Souza Oliveira Pereira Costa Rodrigues Almeida Nascimento Lima Araújo
    Fernandes Carvalho Gomes Martins Rocha Ribeiro Barbosa Cardoso Teixeira Correia
    Vieira Monteiro Moreira Batista Freitas Pinto Cavalcanti Dias Campos Duarte)
CAUSES=("Educação" "Saúde" "Meio Ambiente" "Combate à Fome" "Cultura" "Proteção Animal")
CITIES=("Vale do Ipê" "Porto das Andorinhas" "Santa Clara do Monte" "Nova Aurora do Sul"
    "Ribeirão das Pedras" "Alto da Boa Vista" "Campos do Jequitibá" "Serra dos Ventos"
    "Lagoa Dourada do Norte" "São Bento das Flores" "Recanto das Araras" "Barra do Sossego"
    "Morro da Esperança" "Vila dos Coqueiros" "Fonte do Cerrado")

random_name()  { echo "${FIRST_NAMES[RANDOM % ${#FIRST_NAMES[@]}]} ${LAST_NAMES[RANDOM % ${#LAST_NAMES[@]}]}"; }
random_cause() { echo "${CAUSES[RANDOM % ${#CAUSES[@]}]}"; }
random_city()  { echo "${CITIES[RANDOM % ${#CITIES[@]}]}"; }

# Sorteia se a requisição deve ser inválida (ERROR_RATE por cento)
roll_error() { [ $((RANDOM % 100)) -lt "$ERROR_RATE" ]; }

# Executa uma requisição e registra "serviço|modo|status" para o resumo final.
# Corpo da resposta em stdout (usado somente na criação de ONG válida).
fire() {
    local service="$1" mode="$2" method="$3" url="$4" data="${5:-}"
    local status body_file="$WORKDIR/body.$BASHPID"

    if [ -n "$data" ]; then
        status=$(curl -s --connect-timeout 5 --max-time 15 -o "$body_file" -w '%{http_code}' \
          -X "$method" "$url" -H "Content-Type: application/json" -d "$data" || echo 000)
    else
        status=$(curl -s --connect-timeout 5 --max-time 15 -o "$body_file" -w '%{http_code}' \
          -X "$method" "$url" || echo 000)
    fi

    echo "$service|$mode|$status" >> "$RESULTS"
    cat "$body_file" 2>/dev/null || true
    rm -f "$body_file"
}

# Dispara um job em segundo plano respeitando o limite de CONCURRENCY
run_limited() {
    while [ "$(jobs -rp | wc -l)" -ge "$CONCURRENCY" ]; do
        wait -n
    done
    "$@" &
}

# --- Trabalhadores (executados em segundo plano) -----------------------------

create_ngo_valid() {
    local name="$1" email="$2" cause="$3" city="$4" body ngo_id
    body=$(fire ngo valido POST "$NGO_URL/ngos" \
      "{\"name\":\"$name\",\"email\":\"$email\",\"cause\":\"$cause\",\"city\":\"$city\"}")
    ngo_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null || true)
    if [ -n "$ngo_id" ]; then
        echo "$ngo_id" >> "$NGO_IDS_FILE"
    fi
}

create_ngo_invalid() {
    local variant="$1"
    if [ "$variant" = "duplicado" ]; then
        fire ngo invalido POST "$NGO_URL/ngos" \
          "{\"name\":\"ONG Duplicada\",\"email\":\"$DUP_EMAIL\",\"cause\":\"Educação\",\"city\":\"Curitiba\"}" >/dev/null
    else
        fire ngo invalido POST "$NGO_URL/ngos" '{"name":"ONG Incompleta"}' >/dev/null
    fi
}

create_donation() {
    local mode="$1" ngo_id="$2" amount="$3" donor="$4"
    if [ "$mode" = "invalido" ]; then
        # JSON propositalmente malformado (falta fechar a chave)
        fire donation invalido POST "$DONATION_URL/donations" \
          "{\"ngo_id\": $ngo_id, \"amount\": \"muito\", \"donor_name\":" >/dev/null
    else
        fire donation valido POST "$DONATION_URL/donations" \
          "{\"ngo_id\": $ngo_id, \"amount\": $amount, \"donor_name\": \"$donor\"}" >/dev/null
    fi
}

create_volunteer() {
    local mode="$1" ngo_id="$2" name="$3" email="$4"
    if [ "$mode" = "invalido" ]; then
        fire volunteer invalido POST "$VOLUNTEER_URL/volunteers" \
          "{\"name\": \"$name\", \"email\": \"$email\", \"ngo_id\": \"nao-numerico\"}" >/dev/null
    else
        fire volunteer valido POST "$VOLUNTEER_URL/volunteers" \
          "{\"name\": \"$name\", \"email\": \"$email\", \"ngo_id\": $ngo_id}" >/dev/null
    fi
}

do_get() {
    local target="$1" ngo_id="$2"
    case "$target" in
        ngos)       fire ngo       valido GET "$NGO_URL/ngos" >/dev/null ;;
        donations)  fire donation  valido GET "$DONATION_URL/donations" >/dev/null ;;
        volunteers) fire volunteer valido GET "$VOLUNTEER_URL/volunteers/$ngo_id" >/dev/null ;;
    esac
}

# --- 0) Health check e ONG de referência -------------------------------------

log "Verificando /health dos três serviços..."
for pair in "ngo-service $NGO_URL" "donation-service $DONATION_URL" "volunteer-service $VOLUNTEER_URL"; do
    set -- $pair
    status=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "$2/health" || true)
    if [ "$status" != "200" ]; then
        echo "FALHOU: $1 não respondeu HTTP 200 em $2/health (status: ${status:-sem resposta})" >&2
        exit 1
    fi
done
log "Serviços no ar."

# ONG de referência: garante ao menos um id válido e fornece o e-mail
# usado nos cadastros duplicados (erro 409 conhecido)
DUP_EMAIL="load-test-ref-$RUN_ID@example.com"
create_ngo_valid "ONG Referência Load Test" "$DUP_EMAIL" "$(random_cause)" "$(random_city)"
if [ ! -s "$NGO_IDS_FILE" ]; then
    echo "FALHOU: não foi possível criar a ONG de referência" >&2
    exit 1
fi

# --- 1) Criação das ONGs ------------------------------------------------------

log "Criando $NUM_NGOS ONGs (taxa de erro: $ERROR_RATE%)..."
for i in $(seq 1 "$NUM_NGOS"); do
    if roll_error; then
        if [ $((RANDOM % 2)) -eq 0 ]; then
            run_limited create_ngo_invalid duplicado
        else
            run_limited create_ngo_invalid incompleto
        fi
    else
        run_limited create_ngo_valid \
          "ONG $(random_cause) $i" "ngo-$RUN_ID-$i@example.com" "$(random_cause)" "$(random_city)"
    fi
done
wait

mapfile -t NGO_IDS < "$NGO_IDS_FILE"
log "ONGs disponíveis: ${#NGO_IDS[@]} (ids: ${NGO_IDS[*]})"

# --- 2) Doações, voluntários e consultas, embaralhados ------------------------

# As tarefas são pré-geradas (com o sorteio de erro e os dados aleatórios
# decididos aqui, no processo pai) e embaralhadas, para que os tipos de
# requisição se intercalem como em tráfego real.
TASKS="$WORKDIR/tasks"
: > "$TASKS"
seq_n=0
for ngo_id in "${NGO_IDS[@]}"; do
    for _ in $(seq 1 "$DONATIONS_PER_NGO"); do
        seq_n=$((seq_n + 1))
        mode=valido; roll_error && mode=invalido
        amount="$((RANDOM % 490 + 10)).$(printf '%02d' $((RANDOM % 100)))"
        echo "donation|$mode|$ngo_id|$amount|$(random_name)" >> "$TASKS"
    done
    for _ in $(seq 1 "$VOLUNTEERS_PER_NGO"); do
        seq_n=$((seq_n + 1))
        mode=valido; roll_error && mode=invalido
        echo "volunteer|$mode|$ngo_id|$(random_name)|vol-$RUN_ID-$seq_n@example.com" >> "$TASKS"
    done
    for _ in $(seq 1 "$GETS_PER_NGO"); do
        case $((RANDOM % 3)) in
            0) echo "get|ngos|$ngo_id" >> "$TASKS" ;;
            1) echo "get|donations|$ngo_id" >> "$TASKS" ;;
            2) echo "get|volunteers|$ngo_id" >> "$TASKS" ;;
        esac
    done
done

total_tasks=$(wc -l < "$TASKS")
log "Disparando $total_tasks requisições (concorrência: $CONCURRENCY)..."
while IFS='|' read -r kind f2 f3 f4 f5; do
    case "$kind" in
        donation)  run_limited create_donation "$f2" "$f3" "$f4" "$f5" ;;
        volunteer) run_limited create_volunteer "$f2" "$f3" "$f4" "$f5" ;;
        get)       run_limited do_get "$f2" "$f3" ;;
    esac
done < <(shuf "$TASKS")
wait

# --- 3) Resumo ----------------------------------------------------------------

ELAPSED="$SECONDS"
TEMPO_TOTAL="$((ELAPSED / 60))m$((ELAPSED % 60))s"

log "Resumo por serviço:"
awk -F'|' '
{
    total[$1]++
    if ($2 == "valido" && ($3 == 200 || $3 == 201)) ok[$1]++
    else if ($2 == "invalido" && ($3 == 400 || $3 == 409)) erro_esperado[$1]++
    else { inesperado[$1]++; detalhe[$1] = detalhe[$1] " " $2 ":" $3 }
}
END {
    printf "%-12s %8s %10s %16s %12s\n", "servico", "total", "sucesso", "erro esperado", "inesperado"
    for (s in total) {
        printf "%-12s %8d %10d %16d %12d\n", s, total[s], ok[s] + 0, erro_esperado[s] + 0, inesperado[s] + 0
        if (inesperado[s] > 0) printf "  respostas inesperadas (%s):%s\n", s, detalhe[s]
        falhas += inesperado[s]
    }
    exit (falhas > 0 ? 1 : 0)
}' "$RESULTS" >&2 || {
    log "Tempo total de execução: $TEMPO_TOTAL"
    log "ATENÇÃO: houve respostas fora do esperado."
    exit 1
}

log "Tempo total de execução: $TEMPO_TOTAL"
log "Carga concluída sem respostas inesperadas."
