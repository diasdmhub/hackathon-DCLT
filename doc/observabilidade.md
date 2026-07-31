| [↩️ Voltar](./) |
| --- |

# Observabilidade

> ⚠️ **_Em construção_**

Este é um resumo da stack de observabilidade da SolidaryTech e de como configurá-la no Grafana.

<BR>

## Visão geral

| Sinal | Coleta | Armazenamento | Consulta |
| --- | --- | --- | --- |
| Métricas | Zabbix Agent | Zabbix (pré-existente, fora deste repositório) | Zabbix |
| Logs | Grafana Alloy (DaemonSet, tail dos arquivos CRI em `/var/log/pods`) | Loki | Grafana |
| Traces | SDK OpenTelemetry nos 3 microserviços, export OTLP ao Alloy, que roteia ao Tempo | Grafana Tempo | Grafana |

Os manifestos de Loki, Alloy e Tempo vivem em [`observe/`](/observe) e são aplicados pelo Flux através da Kustomization `observe`.

O Alloy é o único ponto de entrada de telemetria do cluster: coleta os logs de todos os pods (tail dos arquivos CRI) e recebe os traces OTLP dos microserviços, roteando cada sinal ao seu backend (Loki e Tempo, respectivamente).

<BR>

## Traces

### Instrumentação

- **`ngo-service` e `volunteer-service` (Python/Flask)**: auto-instrumentação via `opentelemetry-instrument` (wrapper no `CMD` dos Dockerfiles). Flask, psycopg2 e botocore geram spans automaticamente; o código adiciona atributos de negócio aos spans (`ngo.name`, `ngo.id`, `volunteer.name`, `volunteer.ngo_id`).
- **`donation-service` (Go)**: instrumentação manual com o SDK OpenTelemetry. O `otelhttp` cria o span de servidor de cada requisição (exceto `/health`), e o código cria spans filhos para o `INSERT` no PostgreSQL (com valor, doador e `ngo_id`) e para o envio assíncrono do evento ao SQS.

O export é controlado por variáveis de ambiente definidas nos Deployments em [`kube/`](/kube) (`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT` apontando para `http://alloy.observe.svc.cluster.local:4318`). O Alloy recebe o OTLP (portas 4317/4318 do Service `alloy`) e encaminha ao Tempo via OTLP gRPC (`tempo:4317`). No ambiente local do `docker compose`, o tracing fica desativado por `OTEL_SDK_DISABLED="true"` nos arquivos `.env_*`.

### Correlação log ↔ trace

Toda linha de log de requisição dos 3 serviços termina com `trace_id=<32 dígitos hex>` quando o tracing está ativo. Esse é o elo entre o Loki e o Tempo.

<BR>

## Configuração no Grafana

O Grafana é externo ao cluster e acessa os backends pelo IP compartilhado do MetalLB.

### Datasource Loki (já existente)

- URL: `http://10.12.11.202:3100`

### Datasource Tempo (novo)

- URL: `http://10.12.11.202:3200`

### Derived field no datasource Loki (salto de log para trace)

Em **Configuration → Data sources → Loki → Derived fields**, criar:

| Campo | Valor |
| --- | --- |
| Name | `trace_id` |
| Regex | `trace_id=([0-9a-f]+)` |
| Query | `${__value.raw}` |
| Internal link | Tempo |

Com isso, cada linha de log que contém `trace_id=` ganha um link que abre o trace correspondente no Tempo.

<BR>

## Verificação rápida

```bash
# O Tempo está pronto?
curl -s http://10.12.11.202:3200/ready

# Gera uma requisição rastreada
curl -s -X POST http://10.12.11.202:8082/donations \
  -H 'Content-Type: application/json' \
  -d '{"ngo_id": 1, "amount": 10.5, "donor_name": "Teste Trace"}'

# Busca os traces mais recentes do donation-service
curl -s "http://10.12.11.202:3200/api/search?tags=service.name%3Ddonation-service" | head
```

O `trace_id` retornado pela busca também aparece no fim da linha de log correspondente no Loki.

<BR>

| [⬆️ Top](#observabilidade) |
| --- |
