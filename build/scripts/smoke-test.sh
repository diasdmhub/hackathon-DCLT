#!/usr/bin/env bash
# Valida o fluxo de cadastro e consulta de cada serviço (caminho positivo) contra
# uma stack já no ar (docker compose up --wait), além da publicação
# assíncrona no SQS/ElasticMQ.
#
# Uso: build/scripts/smoke-test.sh
# Variáveis de ambiente opcionais:
#   NGO_URL, DONATION_URL, VOLUNTEER_URL - base URLs dos serviços
#   SQS_NETWORK                          - rede docker onde o ElasticMQ está acessível
#                                           (por padrão, detectada a partir do
#                                           container donation-service)

set -euo pipefail

NGO_URL="${NGO_URL:-http://localhost:8081}"
DONATION_URL="${DONATION_URL:-http://localhost:8082}"
VOLUNTEER_URL="${VOLUNTEER_URL:-http://localhost:8083}"

if [ -z "${SQS_NETWORK:-}" ]; then
    SQS_NETWORK=$(docker inspect donation-service \
      --format '{{range $net, $_ := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null || true)
    if [ -z "$SQS_NETWORK" ]; then
        echo "FALHOU: não foi possível detectar a rede docker do container donation-service (defina SQS_NETWORK manualmente)" >&2
        exit 1
    fi
fi

# Todo log de diagnóstico vai para stderr, para que stdout possa ser
# capturado com segurança via $(...) e conter somente o corpo JSON da resposta.
log() { echo "[smoke-test]     $*" >&2; }

# Título de uma nova etapa do roteiro
_first_section=1
section() {
    if [ "$_first_section" -eq 0 ]; then
        echo >&2
    fi
    _first_section=0
    echo "[smoke-test] $*" >&2
}

# Executa uma requisição HTTP e valida o status code esperado.
# Em caso de sucesso, ecoa o corpo da resposta em stdout (para captura via $(...)).
expect_status() {
    local desc="$1" expected="$2" method="$3" url="$4" data="${5:-}"
    local status
  
    if [ -n "$data" ]; then
        status=$(curl -s -o /tmp/smoke_body -w '%{http_code}' -X "$method" "$url" \
          -H "Content-Type: application/json" -d "$data")
    else
        status=$(curl -s -o /tmp/smoke_body -w '%{http_code}' -X "$method" "$url")
    fi
  
    if [ "$status" != "$expected" ]; then
        echo "FALHOU: $desc (esperado HTTP $expected, recebido $status)" >&2
        cat /tmp/smoke_body >&2
        echo >&2
        return 1
    fi
  
    log "OK: $desc (HTTP $status)"
    cat /tmp/smoke_body
}

section "1) Health check dos três serviços"
expect_status "ngo-service /health" 200 GET "$NGO_URL/health" >/dev/null
expect_status "donation-service /health" 200 GET "$DONATION_URL/health" >/dev/null
expect_status "volunteer-service /health" 200 GET "$VOLUNTEER_URL/health" >/dev/null


section "2) ngo-service - criar ONG de referência"
NGO_EMAIL="smoke-test-$(date +%s)@example.com"
NGO_BODY=$(expect_status "POST /ngos (válido)" 201 POST "$NGO_URL/ngos" \
  "{\"name\":\"ONG Smoke Test\",\"email\":\"$NGO_EMAIL\",\"cause\":\"Educação\",\"city\":\"Curitiba\"}")
NGO_ID=$(echo "$NGO_BODY" | jq -r '.id')
log "NGO_ID=$NGO_ID"
[ "$NGO_ID" != "null" ] && [ -n "$NGO_ID" ]

expect_status "GET /ngos" 200 GET "$NGO_URL/ngos" >/dev/null


section "3) donation-service - registrar doação para a ONG"
DONATION_BODY=$(expect_status "POST /donations (válido)" 201 POST "$DONATION_URL/donations" \
  "{\"ngo_id\": $NGO_ID, \"amount\": 150.00, \"donor_name\": \"Doador Smoke Test\"}")
DONATION_ID=$(echo "$DONATION_BODY" | jq -r '.id')
DONATION_STATUS=$(echo "$DONATION_BODY" | jq -r '.status')
log "DONATION_ID=$DONATION_ID status=$DONATION_STATUS"
[ "$DONATION_STATUS" = "APPROVED" ]

expect_status "GET /donations" 200 GET "$DONATION_URL/donations" >/dev/null


section "3.1) Confirmando a publicação assíncrona no SQS (ElasticMQ)"
sqs_received=0
for i in 1 2 3 4 5; do
  response=$(docker run --rm --network "$SQS_NETWORK" \
    -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli sqs receive-message \
    --endpoint-url http://elasticmq:9324 \
    --queue-url http://elasticmq:9324/queue/solidary-donations 2>/dev/null || true)
  if echo "$response" | grep -q '"Body"'; then
    sqs_received=1
    log "Mensagem recebida na fila solidary-donations"
    break
  fi
  log "Fila ainda vazia, tentativa $i/5..."
  sleep 2
done
if [ "$sqs_received" -ne 1 ]; then
  echo "FALHOU: nenhuma mensagem de doação encontrada na fila solidary-donations" >&2
  exit 1
fi

section "4) volunteer-service - registrar voluntário para a ONG"
VOLUNTEER_BODY=$(expect_status "POST /volunteers (válido)" 201 POST "$VOLUNTEER_URL/volunteers" \
  "{\"name\": \"Voluntário Smoke Test\", \"email\": \"vol-smoke-test@example.com\", \"ngo_id\": $NGO_ID}")
VOLUNTEER_ID=$(echo "$VOLUNTEER_BODY" | jq -r '.volunteer_id')
log "VOLUNTEER_ID=$VOLUNTEER_ID"
[ "$VOLUNTEER_ID" != "null" ] && [ -n "$VOLUNTEER_ID" ]

expect_status "GET /volunteers/{ngo_id}" 200 GET "$VOLUNTEER_URL/volunteers/$NGO_ID" >/dev/null

section "Todos os testes passaram."