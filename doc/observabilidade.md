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
| Métricas de RED / service graph | Metrics-generator do próprio Tempo (deriva das traces) | Prometheus (`observe/040-prometheus/`, dedicado a este fim) | Grafana (via datasource Tempo) |

Os manifestos de Loki, Alloy, Tempo e Prometheus vivem em [`observe/`](/observe) e são aplicados pelo Flux através da Kustomization `observe`. O Prometheus deste diretório é mínimo e dedicado: não faz scraping de infraestrutura (isso continua no Zabbix), serve só para receber via `remote_write` as métricas de service-graph/span-metrics que o Tempo deriva das traces.

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
- É essa URL que o Grafana usa para consultar traces/spans (busca por serviço, TraceQL, abrir um trace específico).

### Datasource Prometheus (novo, para o service map)

- URL: `http://10.12.11.202:9090`
- Cadastrar **antes** do Tempo, pois o passo seguinte referencia esse datasource pelo nome.

### Service Graph no datasource Tempo (monta o "service map")

Em **Configuration → Data sources → Tempo → Service Graph**, selecionar o datasource Prometheus criado acima em **Data source**. Com isso, a aba **Node Graph** aparece ao abrir qualquer trace no Tempo, mostrando os serviços e as chamadas entre eles (taxa de requisições, erros, latência) — o "service map" do Grafana.

O pipeline por trás: o `metrics_generator` do Tempo (habilitado em `overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]`, ver [`observe/030-tempo/031-configmap.yaml`](/observe/030-tempo/031-configmap.yaml)) deriva essas métricas de cada trace recebido e as envia via `remote_write` ao Prometheus (`observe/040-prometheus/`).

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

# Confirma que o metrics-generator está enviando métricas de service graph ao Prometheus
# (pode levar alguns segundos após a primeira requisição rastreada)
curl -s "http://10.12.11.202:9090/api/v1/query?query=traces_service_graph_request_total" | head
```

O `trace_id` retornado pela busca também aparece no fim da linha de log correspondente no Loki.

<BR>

| [⬆️ Top](#observabilidade) |
| --- |
