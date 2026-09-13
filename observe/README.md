| [↩️ Voltar](../) |
| --- |

# Observabilidade do ambiente local

Este é um resumo da stack de observabilidade da SolidaryTech e de como configurá-la no Grafana.

<BR>

## Visão geral

| Sinal | Coleta | Armazenamento | Consulta |
| --- | --- | --- | --- |
| Métricas de cluster/pod | kube-state-metrics + node-exporter (`HelmRelease`s, `observe/040-prometheus/`) | Prometheus | Grafana |
| Logs | Grafana Alloy (DaemonSet, tail dos arquivos CRI em `/var/log/pods`) | Loki | Grafana |
| Traces | SDK OpenTelemetry nos 3 microserviços, export OTLP ao Alloy, que roteia ao Tempo | Grafana Tempo | Grafana |
| Métricas de RED / service graph | Metrics-generator do próprio Tempo (deriva das traces) | Prometheus (`observe/040-prometheus/`, dedicado a este fim) | Grafana (via datasource Tempo) |

Os manifestos de Loki, Alloy, Tempo e Prometheus vivem em [`observe/`](/observe) e são aplicados pelo Flux através da Kustomization `observe`. Além de receber via `remote_write` as métricas de service-graph/span-metrics que o Tempo deriva das traces, o Prometheus deste diretório também faz scraping das métricas de cluster/pod (ver "Métricas de cluster via Prometheus" abaixo).

O Alloy é o único ponto de entrada de telemetria do cluster: coleta os logs de todos os pods e recebe os traces OTLP dos microserviços, roteando cada sinal ao seu backend (Loki e Tempo, respectivamente).

Os 4 ConfigMaps desse diretório (`loki-config`, `alloy-config`, `tempo-config`, `prometheus-config`) são gerados pelo `configMapGenerator` de [`observe/kustomization.yaml`](/observe/kustomization.yaml), a partir de arquivos de configuração avulsos (`010-loki/config.yaml`, `020-alloy/config.alloy`, `030-tempo/config.yaml`, `040-prometheus/prometheus.yml`), não de um manifesto `ConfigMap` embutido. Para alterar a configuração de qualquer um desses serviços, edite o arquivo correspondente. Isso também resolve o reinício automático: o nome do ConfigMap gerado carrega um hash do conteúdo, então qualquer edição muda esse nome, o Kustomize reescreve a referência no Deployment/DaemonSet, e o Kubernetes enxerga um pod template diferente e reinicia o serviço sozinho, sem annotation de checksum para manter manualmente.

<BR>

## Métricas de cluster via Prometheus

Como o Prometheus roda no cluster, toda a observabilidade foi concentrada no Grafana.

`observe/040-prometheus/` também aplica, via `HelmRelease` (Flux, `helm-controller`):

- **kube-state-metrics** (`046-kube-state-metrics.yaml`): estado dos objetos do Kubernetes - fase dos pods, restarts, réplicas prontas/desejadas de Deployments/DaemonSets/StatefulSets/ReplicaSets, condições dos nodes. `collectors` fica restrito a esses objetos (o chart cobre por padrão praticamente todo tipo de objeto do cluster, incluindo secrets/ingresses/PDBs/webhooks/RBAC, sem uso real aqui) - é a peça que dá a "saúde dos pods da solidarytech".
- **node-exporter** (`047-node-exporter.yaml`): métricas de host por node (CPU, memória, disco, rede).

Os dois Services já saem com a anotação `prometheus.io/scrape: "true"` (default de ambos os charts), então o job `kubernetes-service-endpoints` em `prometheus.yml` os descobre via `kubernetes_sd_configs` sem precisar de ServiceMonitor/Prometheus Operator. Um terceiro job, `kubelet-resource`, complementa com CPU/memória por node/pod/container direto do kubelet, via proxy do apiserver (`/api/v1/nodes/<node>/proxy/metrics/resource` - o endpoint de resumo, mais leve que `/metrics/cadvisor` completo); precisa da ClusterRole `prometheus` (`044-rbac.yaml`), vinculada à ServiceAccount que o Deployment do Prometheus usa (`043-prometheus.yaml`.

Deliberadamente enxuto: cobre saúde/consumo de cluster e pods, não todo detalhe que kube-state-metrics/kubelet conseguem expor.

Adicionalmente, existe a template indepente do Zabbix para métricas de negócio/health-check dos 3 microsserviços (`doc/zabbix/template-solidarytech-by-http.yaml`, seção "Template Zabbix" abaixo). Ela cobre health/contagens via HTTP, não métricas de nó/cluster.

<BR>

## Métricas de negócio via Prometheus

Os painéis Grafana "(total)" de doações/ONGs/voluntários expõem um `/metrics` próprio (mesma porta HTTP do serviço), calculado direto na fonte de dados a cada coleta, sem estado em memória:

- **ngo-service**: `solidarytech_ngos_total` (`SELECT COUNT(*) FROM ngos`).
- **donation-service**: `solidarytech_donations_total` e `solidarytech_donations_amount_sum` (`SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM donations`).
- **volunteer-service**: `solidarytech_volunteers_total` (Scan completo da tabela DynamoDB com `Select=COUNT`, paginando por `LastEvaluatedKey`).

Os Services de `ngo`/`donation`/`volunteer` em [`kube/`](/kube) carregam a anotação `prometheus.io/scrape: "true"` e o label `app.kubernetes.io/name`, no mesmo convênio usado por kube-state-metrics/node-exporter acima. Dois jobs em `040-prometheus/prometheus.yml` descobrem esses alvos via `kubernetes_sd_configs` (namespace `solidarytech`, não `observe`):

- `solidarytech-service-endpoints`: ngo-service e donation-service, no `scrape_interval` global (15s).
- `solidarytech-volunteer-metrics`: só volunteer-service, com `scrape_interval: 5m` próprio - o `Scan` com `Select=COUNT` ainda consome as mesmas RCUs de um scan normal (só evita transferir os itens), e a tabela está provisionada em apenas 5 RCU/5 WCU; um scrape a cada 15s competiria por essa capacidade conforme a tabela cresce.

`/metrics` fica fora dos logs de requisição e das traces (mesmo tratamento já dado a `/health`), para não virar ruído a cada coleta.

<BR>

## Traces

### Instrumentação

- **`ngo-service` e `volunteer-service` (Python/Flask)**: auto-instrumentação via `opentelemetry-instrument` (wrapper no `CMD` dos Dockerfiles). Flask, psycopg2 e botocore geram spans automaticamente; o código adiciona atributos de negócio aos spans (`ngo.name`, `ngo.id`, `volunteer.name`, `volunteer.ngo_id`).
- **`donation-service` (Go)**: instrumentação manual com o SDK OpenTelemetry. O `otelhttp` cria o span de servidor de cada requisição (exceto `/health`), e o código cria spans filhos para o `INSERT` no PostgreSQL (com valor, doador e `ngo_id`) e para o envio assíncrono do evento ao SQS.

O export é controlado por variáveis de ambiente definidas nos Deployments em [`kube/`](/kube) (`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT` apontando para `http://alloy.observe.svc.cluster.local:4318`). O Alloy recebe o OTLP (portas 4317/4318 do Service `alloy`) e encaminha ao Tempo via OTLP gRPC (`tempo:4317`). No ambiente local do `docker compose`, o tracing fica desativado por `OTEL_SDK_DISABLED="true"` nos arquivos `.env_*`.

### Correlação log e trace

Toda linha de log de requisição dos 3 serviços termina com `trace_id=<32 dígitos hex>` quando o tracing está ativo. Esse é o elo entre o Loki e o Tempo.

<BR>

## Configuração no Grafana

O Grafana é externo ao cluster e recebe os dados por endpoint próprio.

### Service Graph no datasource Tempo (monta o "service map")

Em **Configuration → Data sources → Tempo → Service Graph**, selecionar o datasource Prometheus criado acima em **Data source**. Com isso, a aba **Node Graph** aparece ao abrir qualquer trace no Tempo, mostrando os serviços e as chamadas entre eles (taxa de requisições, erros, latência). Este é o "service map" do Grafana.

O pipeline por trás: o `metrics_generator` do Tempo (habilitado em `overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]`, ver [`observe/030-tempo/config.yaml`](/observe/030-tempo/config.yaml)) deriva essas métricas de cada trace recebido e as envia via `remote_write` ao Prometheus (`observe/040-prometheus/`).

### Limitação conhecida

O processador `service-graphs` classifica uma chamada como falha unicamente pelo status do span (`STATUS_CODE_ERROR`), sem olhar o código HTTP da resposta. **Isso é fixo no código do Tempo, não é configurável.** Como a convenção semântica do OpenTelemetry só marca esse status em respostas 5xx (o `otelhttp` do Go, por exemplo, deixa 4xx com status `Unset`), erros 4xx nunca aparecem como falha no mapa de serviços, mesmo sendo erros do ponto de vista de negócio.

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

Isso cria o label `http_response_status_code` em `traces_spanmetrics_calls_total`. A query de taxa de erro passa a somar as duas condições:

```promql
sum by (service) (
  rate(traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR"}[$__rate_interval])
  or
  rate(traces_spanmetrics_calls_total{http_response_status_code=~"4.."}[$__rate_interval])
)
```

O `or` funciona sem contagem duplicada porque uma mesma série nunca cai nos dois filtros ao mesmo tempo (4xx sempre fica com `status_code="STATUS_CODE_UNSET"`). **O mapa de serviços (Node Graph) não se beneficia disso, pela limitação descrita acima.**

### Derived field no datasource Loki (salto de log para trace)

Em **Configuration → Data sources → Loki → Derived fields**, criar:

| Campo | Valor |
| --- | --- |
| Name | `trace_id` |
| Regex | `trace_id=([0-9a-f]+)` |
| Query | `${__value.raw}` |
| Internal link | Tempo |

Com isso, cada linha de log que contém `trace_id=` ganha um link que abre o trace correspondente no Tempo.

> **Use o "Explore" do Grafana para uma verificação rápida dos dados.**

<BR>

## Dashboard modelo

[`doc/grafana/dashboard-solidarytech.json`](/doc/grafana/dashboard-solidarytech.json) é um modelo de dashboard de visão geral com as métricas de negócio, RED por serviço, o mapa de serviços (Tempo/Prometheus) e a saúde dos pods da solidarytech.

Os painéis de infraestrutura apontam para o Prometheus, em [`doc/grafana/dashboard-solidarytech-infra.json`](/doc/grafana/dashboard-solidarytech-infra.json), dedicado a CPU/load/memória/disco por node e dados básicos do cluster como contagem de nodes e de pods em execução. A separação evita misturar infraestrutura de cluster com a visão de negócio/serviço da SolidaryTech.

Os painéis de RED contam respostas HTTP 4xx e 5xx como erro, pelo motivo explicado em [Taxa de erro incluindo 4xx](#taxa-de-erro-incluindo-4xx); o mapa de serviços continua refletindo só 5xx (_limitação do Tempo_). Para investigar um erro específico, use o Explore do datasource Tempo diretamente.

A _row_ "Recursos dos Pods" traz 6 painéis, com CPU e memória sugeridas (p95) para cada um dos 3 serviços, calculados a partir do `kubelet-resource` (`container_cpu_usage_seconds_total`/`container_memory_working_set_bytes`, rotulados por `container` `ngo`/`donation`/`volunteer`). A query usa `avg by (container)` antes do `quantile_over_time` para obter o uso típico de **um** pod (não a soma da frota), o que mantém o número comparável a `requests`/`limits` do Deployment mesmo com o HPA variando a contagem de réplicas. Os thresholds estão alianhados com as definições de `kube/0{40,50,60}-*/*.yaml`. Se os _requests_ ou _limits_ mudarem, atualize os thresholds desses painéis para não ficarem desalinhados. **O objetivo é dar o insumo (_p95 de uso real_) para reajustar manualmente `requests`/`limits` ao longo do tempo**, já que o VPA foi descartado, pois causaria _drift_ contra o FluxCD (_ver `doc/estrutura.md`_).

<BR>

## Template Zabbix

São disponibilizadas 2 templates para uso no Zabbix, a fim de criar uma visão externa (_BlackBox do cliente_) da Solidarytech.

### SolidaryTech Health by HTTP

É a template para monitorar os serviços da SolidaryTech externamente. Ela abrange dois aspectos principais:

- **Saúde**: consultas HTTP por serviço ao recurso `/health`, e retornando o status e a latência;
- **Negócio**: itens para a contagem de ONGs, doações e voluntários por ONG.

### SolidaryTech Load by HTTP (Testes)

**É uma template para testes de carga**. Ela envia requisições periódicas para criar ONGs, voluntários e doações na SolidaryTech.

| [⬆️ Top](#observabilidade-do-ambiente-local) |
| --- |

[tempzabbix]: /doc/zabbix/template-solidarytech-by-http.yaml