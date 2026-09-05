# terra/

Infraestrutura AWS do SolidaryTech, definida em Terraform. Recria na nuvem o
mesmo ambiente hoje provisionado manualmente em `kubeadm-local` (ver
`clusters/kubeadm-local/` e o `CLAUDE.md` na raiz do repositório).

As imagens dos 3 microsserviços continuam publicadas no Docker Hub
(`diasdmhub/{ngo,donation,volunteer}`) pelo pipeline de CI/CD já existente -
nenhum módulo de registry (ECR) foi criado aqui.

## Módulos

| Módulo | Recurso principal | Observação de custo |
|---|---|---|
| `vpc` | VPC, subnets públicas/privadas, 1 NAT Gateway | NAT Gateway não é free tier (cobra por hora + dados) |
| `eks` | Cluster EKS + node group gerenciado + OIDC + addons + EBS CSI | Control plane do EKS não é free tier (~US$0,10/h fixo) |
| `rds` | PostgreSQL `db.t3.micro`, single-AZ, 20GB gp3 | Free tier nos primeiros 12 meses de conta nova |
| `dynamo` | Tabela `SolidaryTechVolunteers`, PROVISIONED 5/5 | Dentro do always-free tier (25 RCU/25 WCU/25GB, sem prazo) |
| `sqs` | Fila standard de eventos de doação | Always-free até 1M requisições/mês, sem prazo |
| `iam` | Roles IRSA (donation-service → SQS, volunteer-service → DynamoDB) | Sem custo |
| `nlb` | Network Load Balancer única (3 listeners/target groups por serviço + 3 para observabilidade) | Sem free tier - cobra por hora + LCU |
| `lb-iam` | Role IRSA do AWS Load Balancer Controller (kube-system) | Sem custo |
| `lb` | O AWS Load Balancer Controller em si (ServiceAccount + `helm_release`) | Sem custo AWS - só o compute já contado no node group |
| `secrets` | Parâmetros SSM Parameter Store (`SecureString`/`String`) + Secrets Kubernetes `ngo-env`/`donation-env`/`volunteer-env` | Camada Standard do SSM é gratuita; Secrets Kubernetes sem custo |
| `loki` / `tempo` / `prometheus` | Deployment + PVC (`gp3`) + Service + `TargetGroupBinding` cada, via recursos `kubernetes_*`/`kubectl_manifest`; `prometheus` também aplica kube-state-metrics + node-exporter via `helm_release` (ver "Métricas de cluster via Prometheus" abaixo) | Sem custo AWS além do já contado (node group, NLB, EBS) |
| `alloy` | DaemonSet (coleta de logs + roteamento OTLP) via recursos `kubernetes_*` | Sem custo AWS além do já contado (node group) |
| `flux` | Controladores do FluxCD (`helm_release`) + `GitRepository`/`Kustomization` `solidarytech` + Secret `irsa-role-arns`, via recursos `kubernetes_*`/`kubectl_manifest` (ver "FluxCD via Terraform" abaixo) | Sem custo AWS além do já contado (node group) |

Os últimos 6 módulos não provisionam recursos AWS (`aws_*`) - aplicam
Kubernetes/Helm diretamente contra o cluster que os módulos acima acabaram
de criar, via os providers `kubernetes`/`helm`/`kubectl` (ver "Observabilidade
via Terraform" e "FluxCD via Terraform" abaixo). `lb-iam` é a exceção nesse
grupo: continua puramente IAM (`aws_iam_role`/`aws_iam_role_policy`), como
antes (só o nome mudou, de `lb-controller` para `lb-iam`, para não ser
confundido com o módulo `lb`) - só o lado Kubernetes do AWS Load Balancer
Controller (`lb`) é novo.

### Resolução de domínio em `observe_allowed_cidrs`

A regra de Security Group que libera Loki/Tempo/Prometheus (`terra/modules/{loki,tempo,prometheus}`)
para o Grafana externo aceita, em `observe_allowed_cidrs`
(`terra/terraform.tfvars`), um CIDR, um IP solto ou um nome de domínio -
útil para quem consulta a partir de um IP dinâmico associado a um domínio
DDNS. Domínios são resolvidos via DNS (provider `hashicorp/dns`,
`terra/dns.tf`) a cada `terraform plan`/`apply` e viram um `/32` com o
primeiro endereço retornado; como a resolução só acontece nesse momento, um
IP que mude entre um apply e outro só é refletido na regra no próximo
`terraform apply`.

### Health check da NLB nas portas de observabilidade precisa do CIDR da VPC, não só de `observe_allowed_cidrs`

`observe_allowed_cidrs` restringe quem de **fora** alcança Loki/Tempo/Prometheus,
mas o **health check da própria NLB** não vem de fora - para targets
`type = "ip"`, ele parte das ENIs da NLB nas subnets públicas
(`var.public_subnet_ids`), com IP de origem dentro da VPC. Por isso
`terra/modules/nlb/nlb.tf` tem duas regras de Security Group separadas
nessas 3 portas: `observe_ingress` (`observe_allowed_cidrs`, o Grafana
externo) e `observe_health_check_ingress` (`var.vpc_cidr`, só para o health
check). Sem a segunda, o `TargetGroupBinding` reconcilia normalmente (o pod
está registrado), mas `aws elbv2 describe-target-health` mostra
`unhealthy`/`Target.FailedHealthChecks` porque a Security Group derruba o
próprio probe da NLB - sintoma indistinguível de fora de "porta bloqueada",
mas a causa é a falta dessa regra, não `observe_allowed_cidrs` estar errado.
As 3 portas de aplicação (`nlb_ingress`) nunca tiveram esse problema porque
já são `0.0.0.0/0`.

### Custos que não têm free tier

O EKS control plane, o NAT Gateway e a NLB (`nlb`) são cobrados desde o
primeiro minuto, independentemente da idade da conta AWS - são os itens que
mais pesam neste ambiente; destrua o cluster (`terraform destroy`) fora de
uso para evitar cobrança contínua.

## Observabilidade e monitoração de infraestrutura via Terraform

Loki, Tempo, Alloy, Prometheus **e o AWS Load Balancer Controller**
(módulos `loki`/`tempo`/`alloy`/`prometheus`/`lb` acima) são
aplicados diretamente por este `terraform apply`, não por uma
`Kustomization` do FluxCD. Na prática, esses componentes se mostraram pouco
confiáveis quando geridos pelo Flux neste ambiente - reconciliações que
exigiam intervenção manual, e o próprio Flux se autodestruindo
ocasionalmente, prejudicando a sincronização do cluster e gerando commits
extras no repositório. Como esses serviços só existem no cluster EKS que o
próprio Terraform já provisiona, e os providers `helm`/`kubernetes` já
conseguem aplicá-los direto contra esse cluster, faz mais sentido tratá-los
como parte do mesmo `apply` que cria o cluster. Só os microsserviços da
SolidaryTech (`kube-aws/`) continuam sob Flux - ver `CLAUDE.md`.

O AWS Load Balancer Controller entrou nessa migração por uma razão a mais,
além da confiabilidade: mantê-lo no Flux teria criado uma dependência
cruzada entre ferramentas (o Terraform aplicando `TargetGroupBinding` de um
CRD que só o Flux instalaria) - ver o caveat abaixo sobre por que isso
importa.

### Providers extras e como se autenticam

`terraform.tf` define, além do `kubernetes` já existente, dois providers
novos, ambos reaproveitando a mesma autenticação (endpoint/CA do EKS +
`aws eks get-token` via `exec`):

- `helm` (`hashicorp/helm`): usado pelo módulo `prometheus` (charts
  `prometheus-community/kube-state-metrics` e
  `prometheus-community/prometheus-node-exporter`) e por `lb` (chart
  `aws-load-balancer-controller` do repositório `eks-charts`).
- `kubectl` (`alekc/kubectl`): usado pelos módulos `loki`/`tempo`/`prometheus`
  só para o recurso `TargetGroupBinding` (ver seção abaixo sobre por que não
  `kubernetes_manifest`). Todo o resto
  (Deployment, Service, PVC, ConfigMap, DaemonSet, RBAC, a ServiceAccount do
  módulo `lb`) usa recursos `kubernetes_*` comuns do provider `kubernetes`
  já existente.

Nenhum CLI adicional (`helm`/`kubectl`/`flux`) é pré-requisito para rodar
`terraform apply` em si - esses providers falam com a API do Kubernetes
diretamente. `kubectl`/`helm` continuam úteis para inspecionar o cluster
depois (ver `doc/roteiro-cluster-aws.md`).

### Por que `TargetGroupBinding` usa `kubectl_manifest`, não `kubernetes_manifest`

O CRD `TargetGroupBinding`, usado pelos módulos `loki`/`tempo`/`prometheus`
(e por `kube-aws/`, ainda no Flux), é instalado pelo módulo `lb` acima -
mas dentro do mesmo `terraform apply`, `module.lb` só termina de aplicar
*durante* esse mesmo `apply`, não antes dele começar. O provider
`kubernetes` e seu recurso `kubernetes_manifest` validam o schema do CRD
contra o cluster já no `terraform plan` (antes de qualquer recurso ser
criado), o que quebraria numa primeira execução contra um cluster novo,
onde o CRD ainda não existe nesse momento. `kubectl_manifest` (provider
`kubectl`) não tem essa validação prévia - só valida no `apply`, quando o
grafo de dependências do Terraform (`depends_on = [..., module.lb]` nos 3
módulos, em `main.tf`) já garante que `module.lb` foi aplicado primeiro e o
CRD já existe. Um único `terraform apply` já é suficiente - não é mais
necessário rodar o Flux bootstrap antes ou reaplicar depois, diferente de
quando o AWS Load Balancer Controller ainda vivia no Flux.

### Métricas de cluster via Prometheus (substituindo o Zabbix)

Este ambiente monitorava a camada de nó/cluster com um Zabbix Proxy + Agent2
externo (`terra/modules/zabbix`, removido). Na prática, cada novo cluster
exigia reconfigurar várias regras manuais do lado do Zabbix server (criar o
Proxy, cadastrar a PSK, importar/vincular as templates) antes dos dados
aparecerem - um passo manual repetido a cada recriação do ambiente. Como o
Prometheus já roda neste cluster (recebendo via remote_write as métricas de
RED/service-graph do Tempo), fazia mais sentido concentrar toda a
observabilidade nele/no Grafana externo, sem um segundo sistema de
monitoração em paralelo.

`terra/modules/prometheus` agora também aplica, via `helm_release`
(`helm.tf`):

- **kube-state-metrics**: estado dos objetos do Kubernetes - fase dos pods,
  restarts, réplicas prontas/desejadas de Deployments/DaemonSets/
  StatefulSets/ReplicaSets, condições dos nodes. `collectors` fica
  restrito a esses objetos (o chart cobre por padrão praticamente todo tipo
  de objeto do cluster, incluindo secrets/ingresses/PDBs/webhooks/RBAC, sem
  uso real aqui) - é a peça que dá a "saúde dos pods da solidarytech".
- **node-exporter**: métricas de host por node (CPU, memória, disco, rede) -
  a camada que o Agent2 cobria antes.

Os dois Services já saem com a anotação `prometheus.io/scrape: "true"`
(default de ambos os charts), então o job `kubernetes-service-endpoints` em
`prometheus.yml` os descobre via `kubernetes_sd_configs` sem precisar de
ServiceMonitor/Prometheus Operator (que este ambiente não usa). Um terceiro
job, `kubelet-resource`, complementa com CPU/memória por node/pod/container
direto do kubelet, via proxy do apiserver
(`/api/v1/nodes/<node>/proxy/metrics/resource` - o endpoint de resumo,
mais leve que `/metrics/cadvisor` completo); precisa da ClusterRole
`prometheus` (`rbac.tf`), com acesso a `nodes/proxy`, vinculada à
ServiceAccount que o Deployment do Prometheus usa (`main.tf`).
Deliberadamente enxuto: cobre saúde/consumo de cluster e pods, não todo
detalhe que kube-state-metrics/kubelet conseguem expor.

### Métricas de negócio via Prometheus

Mesmo mecanismo do cluster `kubeadm-local` (ver "Métricas de negócio via
Prometheus" em `observe/README.md`), aplicado aqui em
`terra/modules/prometheus/prometheus.yml`: dois jobs adicionais
(`solidarytech-service-endpoints` e `solidarytech-volunteer-metrics`, este
último com `scrape_interval: 5m` em vez do padrão de 15s, por causa do custo
em RCU de um `Scan` completo na tabela DynamoDB provisionada em 5 RCU/5 WCU)
descobrem, via `kubernetes_sd_configs` no namespace `solidarytech`, o
`/metrics` que cada um dos 3 microsserviços (`kube-aws/`) agora expõe -
`solidarytech_ngos_total`, `solidarytech_donations_total`/`_amount_sum`,
`solidarytech_volunteers_total` -, calculado direto na fonte de dados
(RDS/DynamoDB) a cada coleta. Substitui os antigos painéis Grafana "(total)"
baseados em `count_over_time()` sobre o Loki, presos à retenção de 168h
configurada em `terra/modules/loki/config.yaml`.

### Remote_write para o Grafana Cloud (histórico de SLO sobrevivendo ao DR)

O TSDB local do Prometheus (PVC `gp3`, retenção de 35d) não é replicado para
`terra-dr/` - nenhum dos módulos de observabilidade está na lista de itens
continuamente protegidos entre regiões (só RDS e DynamoDB estão, ver
"Disaster Recovery" abaixo). Isso é especialmente grave para os painéis de
SLO em `doc/grafana/dashboard-solidarytech-golden-metrics.json`, que usam
uma janela fixa de 30d (`rate(...[30d])`) embutida na própria query: ao
ativar `terra-dr/`, o Prometheus novo recalcula essa métrica com o pouco
histórico que existir no momento (às vezes minutos), o que não é um gráfico
vazio, e sim um número de SLO tecnicamente válido, mas sem lastro, o que
apaga qualquer orçamento de erro consumido antes do desastre.

Para preservar esse histórico, `terra/modules/prometheus` aceita 3
variáveis opcionais (`grafana_cloud_remote_write_url`,
`grafana_cloud_username`, `grafana_cloud_api_key`, esta última sensível) e,
quando a URL está preenchida, `prometheus.yml.tpl` (agora um template,
renderizado via `templatefile()` em `main.tf`) adiciona um bloco
`remote_write` restrito, via `write_relabel_configs`, apenas às séries
`traces_spanmetrics_*` usadas pelos painéis de golden metrics/SLI - não a
base inteira do Prometheus, que já tem proteção equivalente por outros
meios (kube-state-metrics/node-exporter refletem o estado do cluster atual,
sem valor histórico após uma recriação; métricas de negócio já são
recalculadas ao vivo do RDS/DynamoDB, ver seção anterior). A API key não
entra no ConfigMap: fica só num `kubernetes_secret_v1` dedicado
(`prometheus-grafana-cloud`), montado no pod e referenciado via
`password_file`, no mesmo espírito de `terra/modules/secrets` (segredo fora
do Flux/git, mas nunca em texto puro num objeto sem esse propósito). As 3
variáveis ficam só em `terraform.tfvars` (gitignored); URL/username vazios
(default) desativam o remote_write por completo, o que mantém `terra-dr/`
funcionando sem alteração, já que hoje não passa essas variáveis ao
`module.prometheus`.

## FluxCD via Terraform

Diferente da observabilidade acima (movida para o Terraform porque o Flux
se mostrou pouco confiável rodando *essas* cargas específicas -
reconciliações que exigiam intervenção manual, autodestruição ocasional), o
Flux em si continua a peça que reconcilia `./kube-aws` (os 3
microsserviços) neste cluster - ele não foi removido, nem substituído. O
que mudou é só a forma como os controladores chegam no cluster: em vez de
`flux install` (CLI) seguido de `kubectl apply -f` manual em dois objetos
(`GitRepository` e `Kustomization` `solidarytech`) e num terceiro (Secret
`irsa-role-arns`), o módulo `flux` (`terra/modules/flux`) instala os
controladores via `helm_release` (chart `fluxcd-community/flux2`) e aplica
os mesmos dois objetos - lidos do YAML já versionado em
`clusters/eks-aws/flux-system/gotk-sync.yaml` e
`clusters/eks-aws/solidarytech-kustomization.yaml` via `file()`, sem
duplicar o conteúdo - mais o Secret `irsa-role-arns`, cujos valores agora
vêm direto de `module.iam` em vez de copiados manualmente de `terraform
output -json iam_outputs`. Um único `terraform apply` cobre tudo: a
instalação inicial e qualquer atualização futura (nova versão do Flux via
`flux_chart_version`, ou mudança de `url`/`branch`/`path`/`interval` nesses
dois objetos).

Isso **não** muda a decisão de não usar `flux bootstrap` neste cluster (ver
o comentário em `clusters/eks-aws/flux-system/gotk-sync.yaml` para o porquê
- o push mirror unidirecional Gitea→GitHub apagaria qualquer commit que o
Flux fizesse aqui): o Flux instalado por este módulo continua só lendo do
`GitRepository`, nunca escrevendo nele. Só os 4 controladores padrão do
`flux install` sem `--components-extra` são habilitados
(`sourceController`/`kustomizeController`/`helmController`/
`notificationController`); `imageReflectionController`/
`imageAutomationController` ficam desligados, porque o loop de Image
Automation já roda uma única vez no cluster `kubeadm-local` (ver CLAUDE.md).

O mesmo módulo `flux` é reaplicado, sem alteração, pelo `terra-dr/` (ver
`terra-dr/README.md`) - a mesma simplificação vale para a ativação do
ambiente passivo, que antes também exigia `flux install` + 3 `kubectl
apply -f` manuais.

## Disaster Recovery (ambiente ativo-passivo)

Estratégia de DR ativo-passivo entre duas regiões AWS: este diretório
(`terra/`) é sempre o ambiente **ativo**; `../terra-dr/` é o ambiente
**passivo**, um root Terraform separado que reaplica os mesmos módulos
(`terra/modules/*`) numa segunda região, normalmente sem nenhum recurso de
compute rodando (nem cobrando) - "ativar" o ambiente passivo é rodar
`terraform apply` em `terra-dr/`. Ver `terra-dr/README.md` para o runbook
completo de ativação/failback.

O que fica sempre protegido, independente de ativação, custando pouco:

- **RDS**: `backup_retention_period` (variável `rds_backup_retention_period`,
  passo obrigatório - antes era `0`, sem backup algum) habilita backups
  automatizados; quando `enable_dr = true`, o recurso
  `aws_db_instance_automated_backups_replication` (`terra/main.tf`) replica
  esses backups continuamente para a região do ambiente passivo (via o
  provider `aws.dr`, o único uso de uma segunda região neste state). A
  restauração em si só acontece quando `terra-dr/` é aplicado
  (`aws_db_instance.restored`, `restore_to_point_in_time`, em
  `terra/modules/rds`) - o RPO é limitado pela frequência/latência dessa
  replicação contínua, não por um snapshot manual agendado.
- **DynamoDB**: `module.dynamo` recebe `replica_regions = [var.dr_aws_region]`
  quando `enable_dr = true`, transformando a tabela numa Global Table (v2)
  com uma réplica sempre viva na região do ambiente passivo -
  `terra-dr/` não cria sua própria tabela, só referencia essa réplica pelo
  nome (idêntico em toda região de uma Global Table).
- **DNS/failover**: quando `manage_dns = true`, uma hosted zone Route53 +
  health check + registro `PRIMARY` (`aws_route53_record.primary`) são
  criados aqui, apontando para a NLB deste state; `terra-dr/` completa o par
  com o registro `SECONDARY` da sua própria NLB, referenciando esta zone via
  `route53_zone_id` (var, copiada do output `route53_zone_id` abaixo - sem
  `terraform_remote_state`, para não acoplar os dois states). O Route53
  troca de `PRIMARY` para `SECONDARY` sozinho quando o health check do
  ambiente ativo falhar, dentro do TTL configurado (30s) - sem depender de
  IPs fixos: a NLB de cada região tem seu próprio DNS name, o nome que o
  cliente usa (`dns_record_name`) é o único que fica constante.

O que **não** replica continuamente, por escolha: a fila **SQS** (eventos em
trânsito no momento do desastre não são reprocessados - a fila é recriada
vazia em `terra-dr/`) e o **EKS/VPC/NLB/observabilidade** do ambiente
passivo em si (só existem depois de `terra-dr/` ser aplicado).

`enable_dr` e `manage_dns` vêm desligados por padrão (`false`) - habilitá-los
muda o comportamento/custo do ambiente já em produção, então é opt-in
explícito via `terraform.tfvars` (ver `terraform.tfvars.example`).

**IAM entre as duas regiões**: como IAM é um namespace global por conta AWS
(diferente de quase todo o resto deste repositório, escopado por região),
`terra/modules/iam` e `terra/modules/lb-iam` aceitam `role_name_suffix`
(vazio aqui, `"-dr"` em `terra-dr/`) para as roles IRSA de cada ambiente não
colidirem, mesmo usando o mesmo `name_prefix`. O `name_prefix` em si
**precisa** ficar igual entre os dois roots: os target groups da NLB usam
nomes determinísticos (`${name_prefix}-<service>-tg`) que `kube-aws/*.yaml`
já referencia via `targetGroupName` - um `name_prefix` diferente quebraria
esse binding sem exigir nenhuma mudança em `kube-aws/`, que continua
100% compartilhado entre os dois clusters (a diferenciação de ARNs de IRSA
já passa pelo Secret `irsa-role-arns` por cluster, não por conteúdo
diferente em `kube-aws/` - ver `clusters/eks-aws-dr/`).

## Pré-requisitos

- Terraform >= 1.6
- AWS CLI v2 configurado (usado pelo provider `kubernetes` para obter token via `aws eks get-token`)
- Uma conta AWS com permissão para criar VPC, EKS, RDS, DynamoDB, SQS, IAM e SSM

## Bootstrap do backend remoto (uma única vez)

O backend S3 (`terraform.tf`) exige que o bucket e a tabela de lock já
existam antes do primeiro `terraform init` - não é possível criá-los com o
mesmo Terraform que os usa como backend. `init.sh` automatiza isso (é
idempotente - pode ser reexecutado sem erro se o bucket/tabela já existirem):

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars, principalmente db_password

./init.sh
```

Nomes de bucket S3 são globalmente únicos entre todas as contas AWS - por
isso `init.sh` usa o prefixo `fiap-solidarytech-terraform-*`, não só
`solidarytech-terraform-*`. **Os nomes em `init.sh` e no bloco `backend "s3"`
de `terraform.tf` precisam ser exatamente os mesmos** (blocos de backend não
aceitam variáveis, então o valor em `terraform.tf` é literal); se ajustar um,
ajuste o outro. Um 403 do tipo `Unable to access object "terraform.tfstate"
in S3 bucket "..."` ao rodar `terraform init` é o sintoma desse descompasso -
a AWS responde 403 em vez de 404 tanto para bucket sem permissão quanto para
bucket que nem existe (ou pertence a outra conta), então a mensagem não
distingue as duas causas.

## Uso

Num backend/cluster totalmente novo (state vazio), o cluster EKS precisa
existir *antes* dos providers `kubernetes`/`helm`/`kubectl` conseguirem se
configurar - os 3 (`terraform.tf`) autenticam usando `module.eks.eks_cluster_endpoint`/
`eks_cluster_ca`/`eks_cluster_name`, que ainda são valores desconhecidos
("unknown") num `plan` contra um state vazio, já que o cluster ainda não
existe para produzi-los. É a limitação clássica de Terraform+EKS (criar o
cluster e já gerenciar recursos Kubernetes dentro dele no mesmo `apply`),
não algo específico deste repositório. Os providers `kubernetes`/`helm`
costumam tolerar isso (adiam a conexão real); o `kubectl` (`alekc/kubectl`,
usado só para `TargetGroupBinding`) não - ele falha o `plan` inteiro com
`Error: invalid provider configuration: invalid configuration: no
configuration has been provided, try setting KUBERNETES_MASTER environment
variable`, mesmo que nenhum recurso `kubectl_manifest` seja avaliado ainda.

A solução é rodar o primeiro `apply` em duas etapas - só na primeira vez
(depois que `module.eks` já estiver no state, `eks_cluster_endpoint`/etc.
passam a ser valores concretos, e `terraform plan`/`apply` funcionam
normalmente num único comando):

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

`terraform.tfvars` nunca deve ser commitado (já coberto pelo `.gitignore` da
raiz do repositório, que ignora `*.tfvars`).

## Destruição do ambiente (`terraform destroy`)

Os 3 microsserviços expõem `Service` `type: ClusterIP` (`kube-aws/040-ngo/`,
`050-donation/`, `060-volunteer/`) e são alcançados de fora via uma NLB
única (`terra/modules/nlb`), com o AWS Load Balancer Controller registrando
os pods nos target groups através de `TargetGroupBinding` - ver
`kube-aws/README.md`. Diferente de um `Service` `type: LoadBalancer` (que
faria o EKS criar uma Classic ELB fora do state do Terraform, arriscando
ENIs órfãs bloqueando a exclusão da VPC), a NLB aqui é o recurso `aws_lb` de
`terra/modules/nlb`: está no state do Terraform, então `terraform destroy` já
apaga NLB, listeners, target groups e a regra de Security Group na ordem
certa, sem passo manual.

O mesmo vale para os recursos `kubernetes_*`/`helm_release`/`kubectl_manifest`
dos módulos `loki`/`tempo`/`alloy`/`prometheus`: por estarem no
state do Terraform, `terraform destroy` os remove (Deployments, PVCs,
`TargetGroupBinding`, releases do Helm) sem passo manual - mas isso exige a
API do EKS alcançável durante todo o destroy, já que esses providers
conversam com o cluster para aplicar as remoções (diferente dos recursos
`aws_*`, que a AWS processa independente do cluster estar de pé). Não
destrua o node group/cluster antes desses recursos serem removidos do state.

Ainda assim, use `terra/destroy.sh` em vez de `terraform destroy` direto -
hoje é só um wrapper fino (`terraform destroy -auto-approve`), mantido como
o ponto de entrada documentado caso a destruição volte a precisar de algum
passo extra:

```bash
cd terra
./destroy.sh
```

## Pendências para o cluster ficar totalmente funcional

Estes módulos provisionam a infraestrutura AWS, mas os ajustes abaixo em
`kube/` (fora do escopo deste diretório) ainda são necessários para o
ambiente funcionar de ponta a ponta na AWS:

1. **Remover as credenciais fake do DynamoDB/SQS local.** Hoje
   `kube/050-donation/051-secret.yaml` e `kube/060-volunteer/061-secret.yaml`
   injetam `AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test` como env
   vars. Tanto o SDK Go (`aws-sdk-go-v2/config.LoadDefaultConfig`) quanto o
   boto3 do volunteer-service resolvem credenciais checando essas env vars
   *antes* do IRSA - se continuarem definidas na AWS, o SDK vai tentar
   autenticar com "test"/"test" em vez de assumir a role IRSA, e vai falhar.
2. **Criar as `ServiceAccount`s `donation-service` e `volunteer-service`**
   no namespace `solidarytech`, anotadas com
   `eks.amazonaws.com/role-arn: <output iam_outputs.donation_service_role_arn / volunteer_service_role_arn>`,
   e referenciá-las via `serviceAccountName` nos respectivos Deployments
   (hoje usam a ServiceAccount `default`).
3. **Apontar `DATABASE_URL`, `AWS_SQS_URL` e `AWS_DYNAMODB_TABLE`** para os
   valores reais gerados aqui (`terraform output`, ou lendo os parâmetros
   SSM criados pelo módulo `secrets`), no lugar dos valores atuais que
   apontam para `psql`/`elasticmq`/DynamoDB Local do Compose.
4. Como `kube/` hoje serve um único ambiente (`kubeadm-local`), provavelmente
   fará sentido introduzir overlays do Kustomize (`base` + `overlays/aws`)
   quando esse ajuste for feito, em vez de sobrescrever os manifests atuais.

Nenhum desses 4 pontos foi alterado por este commit - `kube/` continua
válido para o cluster `kubeadm-local` como está hoje.
