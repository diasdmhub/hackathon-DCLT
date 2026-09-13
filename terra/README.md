# terra/

Infraestrutura da AWS para a SolidaryTech é definida em Terraform. Ela possui diversos módulos que definem os diferentes recursos provisionados para atender a SolidaryTech.

<BR>

## Módulos

| Módulo | Recurso principal | Observação de custo |
|---|---|---|
| `vpc` | VPC, subnets públicas/privadas, 1 NAT Gateway | NAT Gateway não é free tier (cobra por hora + dados) |
| `eks` | Cluster EKS + node group gerenciado + OIDC + addons + EBS CSI | Control plane do EKS não é free tier (~US$0,10/h fixo) |
| `rds` | PostgreSQL `db.t3.micro`, single-AZ, 20GB gp3 | Free tier nos primeiros 12 meses de conta nova |
| `dynamo` | Tabela `SolidaryTechVolunteers`, PROVISIONED 5/5 | Dentro do always-free tier (25 RCU/25 WCU/25GB, sem prazo) |
| `sqs` | Fila standard de eventos de doação | Always-free até 1M requisições/mês, sem prazo |
| `iam` | Roles IRSA (donation-service → SQS, volunteer-service → DynamoDB) | Sem custo |
| `nlb` | Network Load Balancer única (3 listeners/target groups, um por microsserviço) | Sem free tier - cobra por hora + LCU |
| `lb-iam` | Role IRSA do AWS Load Balancer Controller (kube-system) | Sem custo |
| `lb` | O AWS Load Balancer Controller em si (ServiceAccount + `helm_release`) | Sem custo AWS - só o compute já discriminado no node group |
| `secrets` | Parâmetros SSM Parameter Store (`SecureString`/`String`) + Secrets Kubernetes `ngo-env`/`donation-env`/`volunteer-env` | Camada Standard do SSM é gratuita; Secrets Kubernetes sem custo |
| `loki` / `tempo` / `prometheus` | Deployment + PVC (`gp3`, retenção curta - só buffer operacional) + Service (`ClusterIP`, sem exposição externa) cada, via recursos `kubernetes_*`; `prometheus` também aplica kube-state-metrics + node-exporter via `helm_release` (ver "Métricas de cluster via Prometheus" abaixo) | Sem custo AWS além do já discriminado (node group, EBS) |
| `alloy` | DaemonSet (coleta de logs + roteamento OTLP) via recursos `kubernetes_*` | Sem custo AWS além do já discriminado (node group) |
| `flux` | Controladores do FluxCD (`helm_release`) + `GitRepository`/`Kustomization` `solidarytech` + Secret `irsa-role-arns`, via recursos `kubernetes_*`/`kubectl_manifest` (ver "FluxCD via Terraform" abaixo) | Sem custo AWS além do já discriminado (node group) |

> **Os últimos 6 módulos não provisionam recursos da AWS, mas aplicam o Kubernetes/Helm diretamente no cluster criado pelos módulos anteriores, por meio dos _providers_ `kubernetes`/`helm`/`kubectl` (_ver "Observabilidade via Terraform" e "FluxCD via Terraform" abaixo_).**

### Custos que não têm free tier

O EKS _control plane_, o NAT Gateway e a NLB (`nlb`) são cobrados desde o primeiro minuto, independentemente da idade da conta AWS - são os itens que mais pesam neste ambiente.

<BR>

## Observabilidade e monitoração de infraestrutura via Terraform

Os módulos Loki, Tempo, Alloy, Prometheus **e o AWS Load Balancer Controller** (módulos `loki`/`tempo`/`alloy`/`prometheus`/`lb` acima) são aplicados diretamente por este `terraform apply`, não por uma `Kustomization` do FluxCD. Na prática, esses componentes se mostraram pouco confiáveis quando geridos pelo Flux neste ambiente, com reconciliações que exigiam intervenção manual, o que prejudicava a sincronização do cluster e gerava commits extras no repositório. Como esses serviços existem apenas no cluster EKS provisionado pelo próprio Terraform e os _providers_ `helm`/`kubernetes` conseguem aplicá-los diretmente no cluster, faz mais sentido tratá-los como parte do mesmo `apply` que cria o cluster. Só os microsserviços da SolidaryTech (`kube-aws/`) continuam sob Flux.

### Providers extras e como se autenticam

O `terraform.tf` define, além do `kubernetes` já existente, dois providers novos, ambos reaproveitando a mesma autenticação (endpoint/CA do EKS + `aws eks get-token` via `exec`):

- `hashicorp/helm`: usado pelo módulo `prometheus` (charts `prometheus-community/kube-state-metrics` e `prometheus-community/prometheus-node-exporter`) e por `lb` (chart `aws-load-balancer-controller` do repositório `eks-charts`).
- `alekc/kubectl`: usado pelo módulo `flux` para os recursos `GitRepository`/`Kustomization` (_ver seção abaixo sobre por que não `kubernetes_manifest`_).

Todo o resto (Deployment, Service, PVC, ConfigMap, DaemonSet, RBAC, a ServiceAccount do módulo `lb`) usa recursos `kubernetes_*` comuns do provider `kubernetes` já existente.

Nenhum CLI adicional (`helm`/`kubectl`/`flux`) é pré-requisito para executar o `terraform apply` em si. Esses providers falam com a API do Kubernetes diretamente. Mesmo assim, `kubectl`/`helm` continuam úteis para inspecionar o cluster depois.

### Por que `kubectl_manifest` em vez de `kubernetes_manifest`

`terra/modules/flux` usa `kubectl_manifest` (_provider_ `kubectl`) para os CRDs `GitRepository`/`Kustomization`, instalados pelo `helm_release` do chart `flux2` dentro do mesmo módulo. Eles estão dentro do mesmo `terraform apply`, esse `helm_release` só termina de aplicar *durante* esse mesmo apply, não antes dele começar. O provider `kubernetes` e seu recurso `kubernetes_manifest` validam o schema do CRD contra o cluster já no `terraform plan` (antes de qualquer recurso ser criado), o que quebraria numa primeira execução contra um cluster novo, onde o CRD ainda não existe nesse momento. `kubectl_manifest` não tem essa validação prévia, pois só valida no `apply`, quando o grafo de dependências do Terraform já garante que o `helm_release` foi aplicado primeiro e o CRD já existe. Um único `terraform apply` já é suficiente.

### Métricas de cluster via Prometheus

`terra/modules/prometheus` aplica, via `helm_release` (`helm.tf`):

- **kube-state-metrics**: estado dos objetos do Kubernetes - fase dos pods, restarts, réplicas prontas/desejadas de Deployments/DaemonSets/StatefulSets/réplicaSets, condições dos nodes. `collectors` fica restrito a esses objetos. Esta é a peça que informa a "saúde dos pods da SolidaryTech".
- **node-exporter**: métricas de host por node (CPU, memória, disco, rede).

Os dois Services já saem com a anotação `prometheus.io/scrape: "true"` (default de ambos os charts), então o job `kubernetes-service-endpoints` em `prometheus.yml` os descobre via `kubernetes_sd_configs` sem precisar de ServiceMonitor/Prometheus Operator (que este ambiente não usa). Um terceiro job, `kubelet-resource`, complementa com CPU/memória por node/pod/container direto do kubelet, via proxy do apiserver (`/api/v1/nodes/<node>/proxy/metrics/resource` - o endpoint de resumo, mais leve que `/metrics/cadvisor` completo); precisa da ClusterRole `prometheus` (`rbac.tf`), com acesso a `nodes/proxy`, vinculada à ServiceAccount que o Deployment do Prometheus usa (`main.tf`).

Os recursos são deliberadamente enxutos: cobrem saúde/consumo de cluster e pods, não todo detalhe que kube-state-metrics/kubelet conseguem expor.

### Métricas de negócio via Prometheus

Dois jobs adicionais (_`solidarytech-service-endpoints` e `solidarytech-volunteer-metrics`, este último com `scrape_interval: 5m` em vez do padrão de 15s, por causa do custo em RCU de um `Scan` completo na tabela DynamoDB provisionada em 5 RCU/5 WCU_) descobrem, via `kubernetes_sd_configs` no namespace `solidarytech`, o `/metrics` que cada um dos 3 microsserviços (`kube-aws/`) agora expõe - `solidarytech_ngos_total`, `solidarytech_donations_total`/`_amount_sum`, `solidarytech_volunteers_total` -, calculado direto na fonte de dados (RDS/DynamoDB) a cada coleta. A retenção de dados do Loki fica hospedada no Grafana Cloud (ver "Logs e traces para o Grafana Cloud" abaixo).

### Remote_write para o Grafana Cloud (histórico de SLO sobrevivendo ao DR)

O TSDB local do Prometheus (PVC `gp3`, retenção curta - só um buffer operacional, ver "Sem exposição externa..." abaixo) não é réplicado para `terra-dr/` - nenhum dos módulos de observabilidade está na lista de itens continuamente protegidos entre regiões (só RDS e DynamoDB estão, ver "Disaster Recovery" abaixo). Isso é especialmente grave para os painéis de SLO em `doc/grafana/dashboard-solidarytech-golden-metrics.json`, que usam uma janela fixa de 30d (`rate(...[30d])`) embutida na própria query. Ao ativar o ambiente passivo em `terra-dr/`, o Prometheus novo recalcula essa métrica com o pouco histórico que existir no momento (às vezes minutos), o que não é um gráfico vazio, e sim um número de SLO tecnicamente válido, mas sem lastro, o que apaga qualquer orçamento de erro consumido antes do desastre. Por isso a dashboard consulta o Prometheus hospedado no Grafana Cloud, não o local.

Para preservar esse histórico, `terra/modules/prometheus` aceita 3 variáveis opcionais (`grafana_cloud_remote_write_url`, `grafana_cloud_username`, `grafana_cloud_api_key`) e, quando a URL está preenchida, `prometheus.yml.tpl` (um template, renderizado via `templatefile()` em `main.tf`) adiciona um bloco `remote_write` sem `write_relabel_configs`, ou seja, envia **todas** as séries deste Prometheus (golden metrics/SLI do Tempo, kube-state-metrics, node-exporter, kubelet-resource e métricas de negócio) para o Grafana Cloud, não só `traces_spanmetrics_*`. Sem um filtro adicional a manter: o scrape em si já é enxuto por design (collectors do kube-state-metrics restritos, `kubelet-resource` só no endpoint de resumo, ver seção anterior), então não há série "supérflua" a excluir. O único ponto de atenção é o limite de active series do plano do Grafana Cloud, caso o cluster cresça bastante. A API key não entra no ConfigMap: fica só num `kubernetes_secret_v1` dedicado (`prometheus-grafana-cloud`), montado no pod e referenciado via `password_file`, no mesmo espírito de `terra/modules/secrets` (segredo fora do Flux/git, mas nunca em texto puro num objeto sem esse propósito). As 3 variáveis ficam só em `terraform.tfvars` (gitignored); URL/username vazios (default) desativam o remote_write por completo, o que mantém `terra-dr/` funcionando sem alteração, já que não passa essas variáveis ao `module.prometheus`.

### Logs e traces para o Grafana Cloud (via Alloy)

Mesmo raciocínio da seção anterior, aplicado às outras duas pernas da telemetria. O Loki e o Tempo locais (PVCs `local-path`/`gp3`) também não são réplicados entre regiões, e o Alloy (`terra/modules/alloy`, o ponto único de entrada de logs+traces do cluster) já é o lugar natural para adicionar uma segunda via de saída, em vez de reconfigurar Loki/Tempo.

`terra/modules/alloy/config.alloy.tpl` (também um template, mesmo mecanismo `templatefile()`/`checksum-config` de `terra/modules/prometheus`) ganha, condicionado a 6 variáveis opcionais (3 para Logs, 3 para Traces, mesmo padrão de nomes de `grafana_cloud_remote_write_url`/`_username`/`_api_key`):

- um segundo `loki.write "grafanacloud"`, adicionado ao `forward_to` de `loki.process "pods"` junto do `loki.write "default"` já existente - os mesmos logs (já processados pelo `stage.cri`/`stage.drop`) seguem para as duas vias, não há duplicação de configuração de parsing;
- um segundo `otelcol.exporter.otlp "grafanacloud"` (mais o componente `otelcol.auth.basic "grafanacloud"` que ele referencia via
  `auth = otelcol.auth.basic.grafanacloud.handler`), adicionado ao `output.traces` de `otelcol.processor.batch "default"` junto do
  `otelcol.exporter.otlp "tempo"` já existente.

Em ambos os casos a senha (API key) vem de um `kubernetes_secret_v1` dedicado (`alloy-grafana-cloud`, com as chaves `loki-api-key`/`tempo-api-key`), montado no pod em `/etc/alloy-secrets/grafana-cloud/`, nunca em texto puro no ConfigMap. O `loki.write "grafanacloud"` lê a chave direto via `basic_auth.password_file` (suportado nativamente). Já o `otelcol.auth.basic "grafanacloud"` **não** aceita `password_file` dentro do bloco `client_auth` nesta versão do Alloy (v1.19.2) - falha no startup com `no credential source provided` mesmo com o arquivo presente, um bug/lacuna real do componente (não documentado). O contorno: um componente `local.file "tempo_api_key"` (com `is_secret = true`) lê o arquivo do Secret, e seu `.content` (já definido como `secret`) é passado para os argumentos de nível superior `username`/`password` do próprio `otelcol.auth.basic` (a forma mais antiga do componente, sem o bloco `client_auth`). Diferente do Prometheus, aqui **não** há `write_relabel_configs`/filtro equivalente para restringir o que é enviado. Um DaemonSet de logs não tem como filtrar "logs supérfluos" da mesma forma que uma série de métrica, e os traces já são a fonte usada tanto pelos painéis locais quanto pelos golden metrics/SLI (a amostragem, se algum dia for necessária por custo, entraria como `otelcol.processor.probabilistic_sampler` antes do `otelcol.processor.batch`, não implementado hoje).

URL/endpoint vazios (default) desativam cada via independentemente. É possível para habilitar só Logs, só Traces, ou os dois. Como em Prometheus, as 6 variáveis ficam só em `terraform.tfvars` (_ignoradas no git_) e `terra-dr/` não as recebe hoje (mesmo raciocínio: `module.alloy` em `terra-dr/main.tf` não passa essas variáveis).

⚠️ **Aviso de configuração: desativar a geração de métricas de spans no próprio Grafana Cloud.** Como o Tempo local já roda seu `metrics_generator` (seção "Deriva métricas de RED" em `terra/modules/tempo/config.yaml`) e o Prometheus local já reenvia essas séries via `remote_write`, o Grafana Cloud não deve gerar `traces_spanmetrics_*` de novo a partir da segunda via de traces recebida por `otelcol.exporter.otlp "grafanacloud"` acima. Com as duas gerações ativas ao mesmo tempo, as séries resultantes compartilham exatamente os mesmos labels (`job`, `service`, `span_kind`, `span_name`, `status_code`), mas cada uma usa um esquema de buckets de histograma diferente (o do Tempo local vs. o padrão do Grafana Cloud); Prometheus/Mimir mescla as duas sob o mesmo nome de série, o que quebra a monotonicidade exigida por `histogram_quantile` e produz leituras de p95/p99 absurdas (dezenas de segundos onde a latência real é de dezenas de milissegundos), incluindo nos painéis de SLO em `doc/grafana/dashboard-solidarytech-golden-metrics.json`. Esse recurso fica no portal do Grafana Cloud, fora deste repositório, em **Observability > Configuration > Traces metrics generation**. Desative-o ali antes de habilitar `grafana_cloud_tempo_endpoint`, ou revise-o de novo caso os p95 voltem a parecer inconsistentes após qualquer mudança na conta do Grafana Cloud.

### Sem exposição externa de Loki/Tempo/Prometheus

O Prometheus, Loki e Tempo empurram tudo para o Grafana Cloud por push (`remote_write`/`loki.write`/`otelcol.exporter.otlp`, ver seções acima), portanto, não há nada para o Grafana Cloud *consultar* no cluster. Os 3 datasources nativos e hospedados do próprio Grafana Cloud já guardam os dados. `terra/modules/nlb` não tem listeners/target groups de observabilidade (só os 3 dos microsserviços).

<BR>

## FluxCD via Terraform

Diferente da observabilidade acima, o Flux continua a peça que reconcilia `./kube-aws` (os 3 microsserviços) no cluster. O módulo `flux` (`terra/modules/flux`) instala os controladores via `helm_release` (chart `fluxcd-community/flux2`) e aplica os mesmos dois objetos - lidos do YAML já versionado em `clusters/eks-aws/flux-system/gotk-sync.yaml` e `clusters/eks-aws/solidarytech-kustomization.yaml` via `file()`, sem duplicar o conteúdo, além do Secret `irsa-role-arns`, cujos valores vêm direto de `module.iam`. Um único `terraform apply` cobre tudo: a instalação inicial e qualquer atualização futura (nova versão do Flux via `flux_chart_version`, ou mudança de `url`/`branch`/`path`/`interval` nesses dois objetos).

O Flux instalado por este módulo só lê o `GitRepository`, nunca escreve nele. Só os 4 controladores padrão do `flux install` sem `--components-extra` são habilitados (`sourceController`/`kustomizeController`/`helmController`/`notificationController`). O mesmo módulo `flux` é reaplicado, sem alteração, pelo `terra-dr/` (ver `terra-dr/README.md`).

<BR>

## Disaster Recovery (ambiente ativo-passivo)

Este diretório (`terra/`) é sempre o ambiente **ativo**; `../terra-dr/` é o ambiente **passivo**, um root Terraform separado que reaplica os mesmos módulos (`terra/modules/*`) numa segunda região, normalmente sem nenhum recurso de compute executando (_nem cobrando_). "Ativar" o ambiente passivo é executar o `terraform apply` em `terra-dr/`. Ver `doc/roteiro-dr-ativacao.md` para o roteiro completo de ativação/failback.

O que fica sempre protegido, independente de ativação, custando pouco:

- **RDS**: quando `enable_dr = true`, `terra/main.tf` mantém um **"read réplica cross-region" sempre ativo** do Postgres (`module.rds_dr_réplica`, usando `terra/modules/rds` uma segunda vez com `réplicate_source_db_arn`, numa VPC mínima própria - `module.dr_standby_vpc`, sem Internet Gateway/NAT, já que a réplicação cross-region do RDS trafega pelo canal interno gerenciado da AWS, não pela internet da VPC). A latência é tipicamente de segundos, não minutos. Isso é necessário porque o `donation-service` grava valores de doação, e uma estratégia de RPO de minutos arriscava divergência de dados num _failover_. `backup_retention_period` (variável `rds_backup_retention_period`) continua > 0 tanto na instância primária (pré-requisito para criar uma réplica a partir dela) quanto na próprio réplica (permite, por sua vez, servir de origem a uma réplica reversa no failback). A **ativação** promove esse réplica a instância standalone in-place (`var.promote_dr_db = true` - o provider Terraform interpreta a remoção de `replicate_source_db` como uma chamada `ModifyDBInstance` de promoção, não um destroy/recreate). O **failback** espelha o mesmo mecanismo ao contrário: a instância original é destruída e recriada como réplica do novo primário (limitação da própria AWS - não existe conversão in-place de standalone para réplica), resincroniza, e é promovida de volta no mesmo formato. Ver `doc/roteiro-dr-ativacao.md` para o passo a passo completo, incluindo o VPC peering necessário para o EKS de `terra-dr/` alcançar este réplica depois de promovido.
- **DynamoDB**: `module.dynamo` recebe `réplica_regions = [var.dr_aws_region]` quando `enable_dr = true`, transformando a tabela numa Global Table (v2) com uma réplica sempre viva na região do ambiente passivo. `terra-dr/` não cria sua própria tabela, só referencia essa réplica pelo nome (idêntica em toda região de uma Global Table). Global Tables (v2) com billing `PROVISIONED` exige capacidade de escrita com auto scaling já configurado no momento em que a réplica é criada. Como a réplica é declarada no mesmo recurso que cria a tabela (bloco `réplica`), não há como um `aws_appautoscaling_target` (que só pode existir depois da tabela já criada) satisfazer essa exigência a tempo, num `terraform apply` só. A AWS rejeita a criação com `Table write capacity should either be Pay-Per-Request or AutoScaled`. `terra/modules/dynamo/dynamo.tf` evita o problema trocando para `billing_mode = "PAY_PER_REQUEST"` quando há réplica (`var.réplica_regions`), que não exige capacidade pré-configurada. Sem DR, a tabela continua `PROVISIONED` 5/5 (dentro do *always-free tier*) como antes. O custo de `PAY_PER_REQUEST` não entra nesse *always-free tier*, mas é pequeno dado o volume deste ambiente.
- **DNS/failover**: quando `manage_dns = true`, uma hosted zone Route53 + health check + registro `PRIMARY` (`aws_route53_record.primary`) são criados, apontando para a NLB deste _state_. `terra-dr/` completa o par com o registro `SECONDARY` da sua própria NLB, referenciando esta zone via `route53_zone_id` (var, copiada do output `route53_zone_id` abaixo, sem `terraform_remote_state`, para não acoplar os dois states). O Route53 troca de `PRIMARY` para `SECONDARY` sozinho quando o health check do ambiente ativo falhar, dentro do TTL configurado (30s), sem depender de IPs fixos. A NLB de cada região tem seu próprio DNS name, o nome que o cliente usa (`dns_record_name`) é o único que fica constante.

  > O health check (`aws_route53_health_check.primary`) só verifica se > `donation-service:8082/health` responde 200 pela rede. Isso cobre bem uma indisponibilidade de rede/região inteira, mas não detecta desastres em que o endpoint continua respondendo apesar do sistema estar quebrado por trás (corrupção de dados, uma bad deploy, um bug de aplicação). Para esses casos, a ativação do ambiente passivo continua sendo uma decisão manual, não algo que o failover de DNS resolve sozinho.

- O que **não** replica continuamente, por escolha é a fila **SQS** (eventos em trânsito no momento do desastre não são reprocessados, e a fila é recriada vazia em `terra-dr/`) e o **EKS/VPC/NLB/observabilidade** do ambiente passivo (só existem depois de `terra-dr/` ser aplicado).
- `enable_dr` e `manage_dns` vêm ativos por padrão (`true`). Desabilitá-los muda o comportamento/custo do ambiente já em produção, então é explicitamente opicional via `terraform.tfvars` (ver `terraform.tfvars.example`).
- **IAM entre as duas regiões**: como IAM é um namespace global por conta AWS, `terra/modules/eks` (roles do cluster/nodes/EBS CSI), `terra/modules/iam` e `terra/modules/lb-iam` aceitam `role_name_suffix` (vazio em `terra/` e `"-dr"` em `terra-dr/`) para as roles de cada ambiente não colidirem, mesmo usando o mesmo `name_prefix`. O `name_prefix` **precisa** ficar igual entre os dois roots. Os target groups da NLB usam nomes determinísticos (`${name_prefix}-<service>-tg`) que `kube-aws/*.yaml` já referencia via `targetGroupName`. Um `name_prefix` diferente quebraria esse binding sem exigir nenhuma mudança em `kube-aws/`, que continua 100% compartilhado entre os dois clusters (a diferenciação de ARNs de IRSA já passa pelo Secret `irsa-role-arns` por cluster, não por conteúdo diferente em `kube-aws/` - ver `clusters/eks-aws-dr/`).

<BR>

## Pré-requisitos

- Terraform >= 1.6
- AWS CLI v2 configurado (usado pelo provider `kubernetes` para obter token via `aws eks get-token`)
- Uma conta AWS com permissão para criar VPC, EKS, RDS, DynamoDB, SQS, IAM e SSM

<BR>

## Inicialização do backend remoto (_uma única vez_)

O backend S3 em `terraform.tf` exige que o bucket e a tabela de lock já existam antes do primeiro `terraform init`. Não é possível criá-los com o mesmo Terraform que os usa como backend. `init.sh` automatiza isso (é idempotente, pois pode ser reexecutado sem erro se o bucket/tabela já existirem):

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars, principalmente db_password

./init.sh
```

Nomes de bucket S3 são globalmente únicos entre todas as contas AWS. Por isso `init.sh` usa o prefixo `fiap-solidarytech-terraform-*`, não só `solidarytech-terraform-*`. **Os nomes em `init.sh` e no bloco `backend "s3"` de `terraform.tf` precisam ser exatamente os mesmos** (blocos de backend não aceitam variáveis, então o valor em `terraform.tf` é literal). **Se ajustar um, ajuste o outro.** Um 403 do tipo `Unable to access object "terraform.tfstate" in S3 bucket "..."` ao executar `terraform init` é o sintoma desse descompasso, pois a AWS responde 403 em vez de 404 tanto para bucket sem permissão quanto para bucket que nem existe (ou pertence a outra conta), então a mensagem não distingue as duas causas.

O bucket/tabela ficam em `us-west-2` deliberadamente (a região de DR definida em `dr_aws_region`), não em `us-east-1` (a região ativa definida em `aws_region`). A promoção da réplica de DR (`var.promote_dr_db`, ver "Disaster Recovery" abaixo) é um `terraform apply` para este mesmo backend, e precisa dele acessível justamente quando a região ativa estiver indisponível. `terra-dr/init.sh` reaproveita o mesmo bucket/tabela (só a `key` do _state_ muda), então basta executar `terra/init.sh` uma única vez.

<BR>

## Uso

Num backend/cluster totalmente novo (_state_ vazio), o cluster EKS precisa existir *antes* dos providers `kubernetes`/`helm`/`kubectl` conseguirem se configurar. Os 3 (`terraform.tf`) autenticam usando `module.eks.eks_cluster_endpoint`/`eks_cluster_ca`/`eks_cluster_name`, que ainda são valores desconhecidos ("_unknown_") num `plan` de um _state_ vazio, já que o cluster ainda não existe para produzi-los. É uma limitação de Terraform+EKS (criar o cluster e já gerenciar recursos Kubernetes dentro dele no mesmo `apply`), não algo específico deste repositório. Os providers `kubernetes`/`helm` costumam tolerar isso já que adiam a conexão real. O `kubectl` (`alekc/kubectl`,
usado só para `TargetGroupBinding`) não, pois ele falha o `plan` inteiro com `Error: invalid provider configuration: invalid configuration: no configuration has been provided, try setting KUBERNETES_MASTER environment variable`, mesmo que nenhum recurso `kubectl_manifest` seja avaliado ainda.

A solução é executar o primeiro `apply` em duas etapas, mas só na primeira inicialização, depois que `module.eks` já estiver no _state_, `eks_cluster_endpoint`/etc, passam a ser valores concretos, e `terraform plan`/`apply` funciona normalmente num único comando:

```bash
# 1ª vez apenas: cria só o cluster (e o que ele depende: vpc), para os
# outputs usados pelos providers kubernetes/helm/kubectl deixarem de ser
# "unknown"
terraform apply -target=module.eks

# a partir daqui, uso normal
terraform plan
terraform apply

# configurar o kubectl local contra o cluster criado
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-east-1 --name solidarytech-eks-cluster
```

> **`terraform.tfvars` não deve ser compartilhado (já coberto pelo `.gitignore` da raiz do repositório, que ignora `*.tfvars`).**

<BR>

## Destruição do ambiente (`terraform destroy`)

Os 3 microsserviços expõem `Service` `type: ClusterIP` (`kube-aws/040-ngo/`,`050-donation/`, `060-volunteer/`) e são alcançados de fora via uma NLB única (`terra/modules/nlb`), com o AWS Load Balancer Controller registrando os pods nos target groups através de `TargetGroupBinding` - _ver `kube-aws/README.md`_. Diferente de um `Service` `type: LoadBalancer` (que faria o EKS criar uma Classic ELB fora do _state_ do Terraform, arriscando ENIs órfãs e bloqueando a exclusão da VPC), a NLB aqui é o recurso `aws_lb` de `terra/modules/nlb` e está no _state_ do Terraform, então `terraform destroy` apaga NLB, listeners, target groups e a regra de Security Group na ordem certa.

O mesmo vale para os recursos `kubernetes_*`/`helm_release`/`kubectl_manifest` dos módulos `loki`/`tempo`/`alloy`/`prometheus`. Por estarem no _state_ do Terraform, `terraform destroy` os remove (Deployments, PVCs, `TargetGroupBinding`, releases do Helm) sem passos manuais, mas isso exige que a API do EKS esteja alcançável durante todo o destroy, já que esses providers conversam com o cluster para aplicar as remoções (diferente dos recursos `aws_*`, que a AWS processa independente do cluster estar de pé). Evite destruir o "node group"/cluster antes desses recursos serem removidos do _state_.

Se estiver ativo, destrua o ambiente passivo (`terra-dr/`) antes de destruir o ambiente principal.

```bash
cd terra
terraform destroy
```