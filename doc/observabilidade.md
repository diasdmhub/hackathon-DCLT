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

Os 4 ConfigMaps desse diretório (`loki-config`, `alloy-config`, `tempo-config`, `prometheus-config`) são gerados pelo `configMapGenerator` de [`observe/kustomization.yaml`](/observe/kustomization.yaml), a partir de arquivos de configuração avulsos (`010-loki/config.yaml`, `020-alloy/config.alloy`, `030-tempo/config.yaml`, `040-prometheus/prometheus.yml`), não de um manifesto `ConfigMap` embutido (não existem mais `NNN-configmap.yaml` nesse diretório). Para alterar a configuração de qualquer um desses serviços, edite o arquivo correspondente. Isso também resolve o reinício automático: o nome do ConfigMap gerado carrega um hash do conteúdo, então qualquer edição muda esse nome, o Kustomize reescreve a referência no Deployment/DaemonSet, e o Kubernetes enxerga um pod template diferente e reinicia o serviço sozinho, sem annotation de checksum para manter manualmente.

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

O pipeline por trás: o `metrics_generator` do Tempo (habilitado em `overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]`, ver [`observe/030-tempo/config.yaml`](/observe/030-tempo/config.yaml)) deriva essas métricas de cada trace recebido e as envia via `remote_write` ao Prometheus (`observe/040-prometheus/`).

**Limitação conhecida**: o processador `service-graphs` classifica uma chamada como falha unicamente pelo status do span (`STATUS_CODE_ERROR`), sem olhar o código HTTP da resposta; isso é fixo no código do Tempo, não é configurável. Como a convenção semântica do OpenTelemetry só marca esse status em respostas 5xx (o `otelhttp` do Go, por exemplo, deixa 4xx com status `Unset`), erros 4xx nunca aparecem como falha no mapa de serviços, mesmo sendo erros do ponto de vista de negócio.

### Taxa de erro incluindo 4xx

Pela mesma razão acima, uma query Prometheus que filtre só `traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR"}` enxerga apenas 5xx. Para tratar 4xx também como erro nos painéis de RED, sem alterar o status semântico do span em si, `observe/030-tempo/config.yaml` adiciona `http.response.status_code` como dimensão extra do processador `span-metrics`:

```yaml
overrides:
  defaults:
    metrics_generator:
      processor:
        span_metrics:
          dimensions:
            - http.response.status_code
```

Isso cria o label `http_response_status_code` (pontos viram underscore) em `traces_spanmetrics_calls_total`. A query de taxa de erro passa a somar as duas condições:

```promql
sum by (service) (
  rate(traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR"}[$__rate_interval])
  or
  rate(traces_spanmetrics_calls_total{http_response_status_code=~"4.."}[$__rate_interval])
)
```

O `or` funciona sem contagem duplicada porque uma mesma série nunca cai nos dois filtros ao mesmo tempo (4xx sempre fica com `status_code="STATUS_CODE_UNSET"`). O mapa de serviços (Node Graph) não se beneficia disso, pela limitação descrita acima.

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

## Dashboard modelo

[`doc/grafana/dashboard-solidarytech.json`](/doc/grafana/dashboard-solidarytech.json) é um modelo de dashboard (Grafana 13.1.1, importável via **Dashboards → New → Import**) com as métricas de negócio (Loki), RED por serviço e o mapa de serviços (Tempo/Prometheus), e infraestrutura dos 2 nodes (Zabbix). Os painéis de Zabbix usam o filtro de item pelo nome padrão dos templates oficiais (`CPU utilization`, `Memory utilization`, `Load average (1m avg)`, condição `Ready` dos nodes e réplicas disponíveis dos deployments de `ngo`/`donation`/`volunteer` no host `kubernetes_cluster`); como o esquema exato do target JSON do datasource Zabbix varia por versão do plugin, pode ser necessário reselecionar host/item na edição do painel após a importação. A importação hoje é manual (colar o JSON ou fazer upload do arquivo); ainda não há sincronização automática a partir do Git.

Os painéis de RED (`Taxa de erro por serviço (%)`, `donation-service: requisições/s e erros/s`) contam 4xx e 5xx como erro, pelo motivo explicado em [Taxa de erro incluindo 4xx](#taxa-de-erro-incluindo-4xx); o mapa de serviços continua refletindo só 5xx (limitação do Tempo, não da configuração). O modelo não tem painel dedicado a listar traces de erro individualmente: o tipo de painel `traces` do Grafana, nessa versão (13.1.1), só renderiza a visualização em lista quando a query retorna um trace específico, não uma busca com múltiplos resultados — a query em si funciona (confirmado alternando o mesmo painel para "table view" e para o tipo `table`), só a visualização de lista de traces não desenha nada. Para investigar um erro específico, use o Explore do datasource Tempo diretamente.

<BR>

| [⬆️ Top](#observabilidade) |
| --- |
