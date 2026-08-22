| [↩️ Voltar](../) |
| --- |

# Observabilidade do ambiente local

> ⚠️ **_Em construção_**

Este é um resumo da stack de observabilidade da SolidaryTech e de como configurá-la no Grafana.

<BR>

## Visão geral

| Sinal | Coleta | Armazenamento | Consulta |
| --- | --- | --- | --- |
| Métricas de cluster/pod | kube-state-metrics + node-exporter (`HelmRelease`s, `observe/040-prometheus/`) | Prometheus | Grafana |
| Logs | Grafana Alloy (DaemonSet, tail dos arquivos CRI em `/var/log/pods`) | Loki | Grafana |
| Traces | SDK OpenTelemetry nos 3 microserviços, export OTLP ao Alloy, que roteia ao Tempo | Grafana Tempo | Grafana |
| Métricas de RED / service graph | Metrics-generator do próprio Tempo (deriva das traces) | Prometheus (`observe/040-prometheus/`, dedicado a este fim) | Grafana (via datasource Tempo) |

Os manifestos de Loki, Alloy, Tempo e Prometheus vivem em [`observe/`](/observe) e são aplicados pelo Flux através da Kustomization `observe`. Além de receber via `remote_write` as métricas de service-graph/span-metrics que o Tempo deriva das traces, o Prometheus deste diretório também faz scraping das métricas de cluster/pod (ver "Métricas de cluster via Prometheus" abaixo) - papel que antes era do Zabbix, hoje inteiramente concentrado no Grafana.

O Alloy é o único ponto de entrada de telemetria do cluster: coleta os logs de todos os pods (tail dos arquivos CRI) e recebe os traces OTLP dos microserviços, roteando cada sinal ao seu backend (Loki e Tempo, respectivamente).

Os 4 ConfigMaps desse diretório (`loki-config`, `alloy-config`, `tempo-config`, `prometheus-config`) são gerados pelo `configMapGenerator` de [`observe/kustomization.yaml`](/observe/kustomization.yaml), a partir de arquivos de configuração avulsos (`010-loki/config.yaml`, `020-alloy/config.alloy`, `030-tempo/config.yaml`, `040-prometheus/prometheus.yml`), não de um manifesto `ConfigMap` embutido (não existem mais `NNN-configmap.yaml` nesse diretório). Para alterar a configuração de qualquer um desses serviços, edite o arquivo correspondente. Isso também resolve o reinício automático: o nome do ConfigMap gerado carrega um hash do conteúdo, então qualquer edição muda esse nome, o Kustomize reescreve a referência no Deployment/DaemonSet, e o Kubernetes enxerga um pod template diferente e reinicia o serviço sozinho, sem annotation de checksum para manter manualmente.

<BR>

## Métricas de cluster via Prometheus (substituindo o Zabbix)

Este ambiente monitorava a camada de nó/cluster com um Zabbix Proxy + Agent2 (release Helm `zabbix`, namespace `monitoring`, instalado manualmente fora deste repositório - não aparece em nenhum `Kustomization`/`HelmRelease` do Flux). Na prática, cada recriação do cluster exigia reconfigurar várias regras manuais do lado do Zabbix server (criar o Proxy, importar/vincular as templates) antes dos dados aparecerem. Como o Prometheus já roda neste cluster (recebendo via `remote_write` as métricas de RED/service-graph do Tempo), fazia mais sentido concentrar toda a observabilidade nele/no Grafana, sem um segundo sistema de monitoração em paralelo - mesma decisão já aplicada ao cluster EKS (`terra/modules/prometheus`, ver `terra/README.md`).

`observe/040-prometheus/` agora também aplica, via `HelmRelease` (Flux, `helm-controller`):

- **kube-state-metrics** (`046-kube-state-metrics.yaml`): estado dos objetos do Kubernetes - fase dos pods, restarts, réplicas prontas/desejadas de Deployments/DaemonSets/StatefulSets/ReplicaSets, condições dos nodes. `collectors` fica restrito a esses objetos (o chart cobre por padrão praticamente todo tipo de objeto do cluster, incluindo secrets/ingresses/PDBs/webhooks/RBAC, sem uso real aqui) - é a peça que dá a "saúde dos pods da solidarytech".
- **node-exporter** (`047-node-exporter.yaml`): métricas de host por node (CPU, memória, disco, rede) - a camada que o Agent2 cobria antes.

Os dois Services já saem com a anotação `prometheus.io/scrape: "true"` (default de ambos os charts), então o job `kubernetes-service-endpoints` em `prometheus.yml` os descobre via `kubernetes_sd_configs` sem precisar de ServiceMonitor/Prometheus Operator (que este ambiente não usa). Um terceiro job, `kubelet-resource`, complementa com CPU/memória por node/pod/container direto do kubelet, via proxy do apiserver (`/api/v1/nodes/<node>/proxy/metrics/resource` - o endpoint de resumo, mais leve que `/metrics/cadvisor` completo); precisa da ClusterRole `prometheus` (`044-rbac.yaml`), vinculada à ServiceAccount que o Deployment do Prometheus usa (`043-prometheus.yaml`, antes rodava como `default`). Deliberadamente enxuto: cobre saúde/consumo de cluster e pods, não todo detalhe que kube-state-metrics/kubelet conseguem expor.

**Descomissionar o Zabbix** (fora deste repositório, ação manual no cluster):

```bash
helm uninstall zabbix -n monitoring
kubectl delete namespace monitoring   # opcional, se nada mais usar esse namespace
```

O template Zabbix de métricas de negócio/health-check dos 3 microsserviços (`doc/zabbix/template-solidarytech-by-http.yaml`, seção "Template Zabbix" abaixo) é independente disso - cobre health/contagens via HTTP, não métricas de nó/cluster, e não foi alterado por esta migração.

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

> ⚠️ Com a migração da seção "Métricas de cluster via Prometheus" acima, os painéis de infraestrutura desse modelo ainda apontam para o datasource Zabbix (que deixa de existir no cluster). Ainda não foram reconstruídos contra kube-state-metrics/node-exporter/Prometheus - pendente.

Os painéis de RED (`Taxa de erro por serviço (%)`, `donation-service: requisições/s e erros/s`) contam 4xx e 5xx como erro, pelo motivo explicado em [Taxa de erro incluindo 4xx](#taxa-de-erro-incluindo-4xx); o mapa de serviços continua refletindo só 5xx (limitação do Tempo, não da configuração). O modelo não tem painel dedicado a listar traces de erro individualmente: o tipo de painel `traces` do Grafana, nessa versão (13.1.1), só renderiza a visualização em lista quando a query retorna um trace específico, não uma busca com múltiplos resultados — a query em si funciona (confirmado alternando o mesmo painel para "table view" e para o tipo `table`), só a visualização de lista de traces não desenha nada. Para investigar um erro específico, use o Explore do datasource Tempo diretamente.

<BR>

## Template Zabbix

[`doc/zabbix/template-solidarytech-by-http.yaml`](/doc/zabbix/template-solidarytech-by-http.yaml) é a template "SolidaryTech by HTTP" (exportação Zabbix 7.4, importável via **Data collection → Templates → Import**), com macros `{$ST.PORT.NGO}`/`{$ST.PORT.DONATION}`/`{$ST.PORT.VOLUNTEER}` (padrão 8081/8082/8083) e `{$ST.HTTP.SCHEMA}` (padrão `http`), resolvidas sobre `{HOST.CONN}` do host ao qual a template for vinculada. Ela cobre dois tipos de métrica:

- **Saúde**: um item HTTP agent por serviço (`SolidaryTech Health NGO/Donation/Volunteer Service`, chaves `st.health[ngo|donation|volunteer]`) consultando `GET /health`. Cada um tem três passos de pré-processamento: JSONPath (`$.status`, extrai o campo `status` do corpo `{"status":"ok","service":"..."}`), Replace (`STR_REPLACE`, converte o texto `ok` no inteiro `1` — necessário para que o `value_type: UNSIGNED` do item receba um valor puramente numérico, já que um Replace direto sobre o corpo JSON inteiro deixaria texto ao redor do `1`) e Discard unchanged with heartbeat (5m, evita gravar histórico redundante enquanto o serviço permanece saudável). Um `valuemap` "Health Status" traduz `1`/qualquer outro valor para `Ok`/`Unavailable` na UI.
- **Negócio**: itens dependentes (`type: DEPENDENT`) que reaproveitam o corpo já obtido por um item HTTP agent "lista" (`st.ngos.list` via `GET /ngos`, `st.donations.list` via `GET /donations`), evitando pollings redundantes ao mesmo endpoint. A partir de `st.ngos.list`: `SolidaryTech NGO Count` (`$.length()`). A partir de `st.donations.list`: `SolidaryTech Donation Count` (`$.length()`) e `SolidaryTech Donations Total Amount` (`$[*].amount.sum()`). Para voluntários por ONG, a regra de descoberta `SolidaryTech NGO Discovery` também é `DEPENDENT` de `st.ngos.list` (via `lld_macro_paths` mapeando `{#NGO.ID}`/`{#NGO.NAME}` a `$.id`/`$.name`, sem chamada HTTP extra) e cria um item prototype `SolidaryTech Volunteers Count: {#NGO.NAME}` por ONG descoberta; esse prototype precisa ser HTTP agent (não dependente), pois o volunteer-service só expõe `GET /volunteers/<ngo_id>` por ONG individual, sem endpoint que liste voluntários de todas as ONGs de uma vez.

### Incidente: CrashLoopBackOff do volunteer-service causado pelo item prototype de voluntários por ONG

O item prototype `SolidaryTech Volunteers Count: {#NGO.NAME}` foi originalmente criado sem `delay` explícito (herdando o padrão de 1m do Zabbix). Com 156 ONGs cadastradas no banco (`SELECT count(*) FROM ngos` no host `psql`), a discovery rule criou 156 itens, cada um chamando `GET /volunteers/<ngo_id>` a cada minuto. Cada chamada dispara um `Scan` não indexado no DynamoDB (comentário no próprio `volunteer-service/app.py`: "simplificado... não seria adequado para produção"), e `Dockerfile-volunteer` sobe o serviço com `gunicorn --bind 0.0.0.0:8083 volunteer:app` sem `--workers`/`--threads`, ou seja, um único worker `sync` processando uma requisição por vez.

O resultado, confirmado nos logs e eventos do pod (`kubectl logs --previous`, `kubectl describe pod`): as ~156 chamadas de `/volunteers/<id>` ficavam enfileiradas sequencialmente (~0,5 a 0,7s cada, ~90 a 110s no total) atrás do único worker, o que impedia a liveness probe (`GET /health`, `timeout=2s`, `period=10s`, `failureThreshold=3`) de ser respondida a tempo. Após 3 falhas consecutivas (~30s), o kubelet matava o container, gerando o `CrashLoopBackOff`.

Correção aplicada na template: `delay: 1h` explícito no item prototype (métrica de negócio, não precisa de granularidade de minuto). Isso reduz a frequência do problema, mas não o elimina por completo (156 chamadas seriais ainda ocupam ~1,5 a 2 minutos, uma vez por hora); a correção definitiva é dar concorrência ao `volunteer-service` (`--workers`/`--threads` no `gunicorn`, em `build/Dockerfile-volunteer`), para que a liveness probe nunca fique atrás de um Scan lento. Essa mudança de imagem ainda não foi aplicada — depende de rebuild/push/deploy e foi deixada para decisão explícita.

**Importante**: esse arquivo é só a fonte da template; a correção do `delay` só passa a valer depois de reimportar a template no Zabbix (ou ajustar manualmente o item já vinculado ao host). Até lá, o `SolidaryTech NGO Discovery` continua gerando carga no ritmo antigo no Zabbix em produção.

<BR>

| [⬆️ Top](#observabilidade-do-ambiente-local) |
| --- |