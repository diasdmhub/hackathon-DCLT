| [↩️ Voltar](./) |
| --- |

# Teste de fluxo de execução da SolidaryTech

Os testes abaixo servem para evidência de funcionamento e compreensão da execução dos microserviços.

<BR>

## Pré-requisitos

Em um ambiente local, deve-se incializar os serviços com o `docker-compose.yaml`.

> _Pode-se usar `docker` ou `podman`._

```bash
podman compose up --build -d
podman compose ps   # aguarde todos os containers ficarem "healthy"
```

> - **O `ngo-service/db/init.sql` registra 2 ONGs de forma idempotente na primeira inicialização (`Anjos de Patas` e `Educa Mais`), então, `GET /ngos` nunca retorna vazio.**
> - **Recomenda-se utilizar o `jq` para ler as respostas formatadas. Os exemplos abaixo assumem isso.**

<BR>

## Teste

### 1. Health check dos três serviços

```bash
curl -s http://localhost:8081/health | jq
curl -s http://localhost:8082/health | jq
curl -s http://localhost:8083/health | jq
```

**Esperado: `{"status":"ok","service":"<nome-do-serviço>"}` nos três.**

<BR>

### 2. `ngo-service` - Criar a ONG de referência para os demais microserviços

```bash
curl -s -X POST http://localhost:8081/ngos \
    -H "Content-Type: application/json" \
    -d '{"name":"[NOME DA INSTITUIÇÃO]","email":"[EMAIL@DA.INSTITUIÇÃO]","cause":"[CAUSA]","city":"[CIDADE]"}' | jq
```

> **Guarde o `id` retornado, pois ele é usado nas requisições seguintes.**

#### Exemplo:

```bash
NGO_ID=$(curl -s -X POST http://localhost:8081/ngos \
  -H "Content-Type: application/json" \
  -d '{"name":"Instituto Mão Amiga 2","email":"contato2@maoamiga.org","cause":"Fome","city":"São Paulo"}' \
  | jq -r '.id')
echo "NGO_ID=$NGO_ID"
```

#### Listar todas as ONGs:

```bash
curl -s http://localhost:8081/ngos | jq
```

#### Casos negativos:

```bash
# 400 - campo obrigatório ausente (falta "city")
curl -s -X POST http://localhost:8081/ngos \
    -H "Content-Type: application/json" \
    -d '{"name":"X","email":"x@x.org","cause":"Fome"}' | jq

# 409 - e-mail duplicado (repetir o e-mail usado acima)
curl -s -X POST http://localhost:8081/ngos \
    -H "Content-Type: application/json" \
    -d '{"name":"Duplicada","email":"contato2@maoamiga.org","cause":"Fome","city":"SP"}' | jq
```

<BR>

### 3. `donation-service` - Registrar uma doação para a ONG

```bash
curl -s -X POST http://localhost:8082/donations \
    -H "Content-Type: application/json" \
    -d "{\"ngo_id\": $NGO_ID, \"amount\": 150.00, \"donor_name\": \"Fulano de Tal\"}" | jq
```

> **Note que `status` sempre retorna "`APPROVED`", pois o gateway de pagamento é simulado e não há integração real.**

#### Listar todas as doações:

```bash
curl -s http://localhost:8082/donations | jq
```

#### Caso negativo:

> **O microserviço só recusa a requisição quando o ID da ONG é inválido, quando ele não é um número inteiro. Se o ID for válido, ou mesmo se estiver ausente, o registro é aceito e o ID registrado é `0`.**

```bash
# 400 - payload inválido (ID inválido da ONG)
curl -s -X POST http://localhost:8082/donations \
    -H "Content-Type: application/json" \
    -d '{ngo_id: nope}' | jq
```

#### Confirmando a publicação assíncrona no SQS (_ou ElasticMQ_):

> **As portas do ElasticMQ não são expostas ao host por padrão, então, a fila só é visível internamente.**

```bash
# Inspecionar localmente:
podman network ls  # confirme o nome exato da rede gerada pelo compose

podman run --rm --network <nome-da-rede-sol-net> \
    -e AWS_ACCESS_KEY_ID=test \
    -e AWS_SECRET_ACCESS_KEY=test \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli \
    sqs receive-message \
    --endpoint-url http://elasticmq:9324 \
    --queue-url http://elasticmq:9324/queue/solidary-donations
```

<BR>

### 4.4 `volunteer-service` - Registrar um voluntário para a ONG

```bash
curl -s -X POST http://localhost:8083/volunteers \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Ciclana da Silva\", \"email\": \"ciclana@example.com\", \"ngo_id\": $NGO_ID}" | jq
```

#### Buscar voluntários da ONG:

```bash
curl -s http://localhost:8083/volunteers/$NGO_ID | jq
```

> **Essa consulta faz um `Scan` completo da tabela DynamoDB com `FilterExpression`, não uma query por chave. É documentado no próprio código como simplificação, não pensado para volume de produção.**

#### Caso negativo:

> - **O registro ou a consulta de voluntários aceita qualquer número inteiro como ID de ONG, mesmo que não exista no banco-de-dados.**

```bash
# 400 - campo obrigatório ausente ou ID inválido da ONG (não inteiro)
curl -s -X POST http://localhost:8083/volunteers \
    -H "Content-Type: application/json" \
    -d '{"name":"X","email":"x@x.com"}' | jq

# 404 - ID inválido da ONG
curl -s http://localhost:8083/volunteers/nao_inteiro | jq
```

<BR>

## 5. Script consolidado (fluxo completo de ponta a ponta)

```bash
#!/usr/bin/env bash
set -euo pipefail

NGO_ID=$(curl -s -X POST http://localhost:8081/ngos \
    -H "Content-Type: application/json" \
    -d '{"name":"ONG Roteiro E2E","email":"roteiro-e2e@example.com","cause":"Educação","city":"Curitiba"}' \
    | jq -r '.id')
echo "1) ONG criada -> id=$NGO_ID"

DONATION_ID=$(curl -s -X POST http://localhost:8082/donations \
    -H "Content-Type: application/json" \
    -d "{\"ngo_id\": $NGO_ID, \"amount\": 75.50, \"donor_name\": \"Doador Teste\"}" \
    | jq -r '.id')
echo "2) Doação criada -> id=$DONATION_ID"

VOLUNTEER_ID=$(curl -s -X POST http://localhost:8083/volunteers \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Voluntário Teste\", \"email\": \"vol-teste@example.com\", \"ngo_id\": $NGO_ID}" \
    | jq -r '.volunteer_id')
echo "3) Voluntário criado -> volunteer_id=$VOLUNTEER_ID"

echo "4) Voluntários da ONG $NGO_ID:"
curl -s http://localhost:8083/volunteers/$NGO_ID | jq -r '.[].name'
```

<BR>

## 6. Notas e limitações

- **Sem validação cruzada de `ngo_id`**: `donation-service` e `volunteer-service` aceitam qualquer inteiro, mesmo que a ONG não exista no `ngo-service`.
- **Portas internas não expostas**: ElasticMQ (`9324`) e DynamoDB Local (`8000`) só respondem dentro da rede interna; só `ngo` (8081), `donation` (8082) e `volunteer` (8083) estão publicadas no host.
- **"Seed" idempotente**: `ngo-service` já sobe com 2 ONGs cadastradas; `donation-service` e `volunteer-service` não têm seed.
- **`donation-service` sempre aprova**: não existe integração real com gateway de pagamento. Todo `POST /donations` retorna `status: "APPROVED"`.

| [⬆️ Top](#teste-de-fluxo-de-execu%C3%A7%C3%A3o-da-solidarytech) |
| --- |