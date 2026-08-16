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
| `zabbix` | Zabbix Proxy (modo ativo) + Agent2 (DaemonSet) + kube-state-metrics, via `helm_release` | Sem custo AWS - só o compute já contado no node group |
| `loki` / `tempo` / `prometheus` | Deployment + PVC (`gp3`) + Service + `TargetGroupBinding` cada, via recursos `kubernetes_*`/`kubectl_manifest` | Sem custo AWS além do já contado (node group, NLB, EBS) |
| `alloy` | DaemonSet (coleta de logs + roteamento OTLP) via recursos `kubernetes_*` | Sem custo AWS além do já contado (node group) |

Os últimos 6 módulos não provisionam recursos AWS (`aws_*`) - aplicam
Kubernetes/Helm diretamente contra o cluster que os módulos acima acabaram
de criar, via os providers `kubernetes`/`helm`/`kubectl` (ver "Observabilidade
via Terraform" abaixo). `lb-iam` é a exceção nesse grupo: continua
puramente IAM (`aws_iam_role`/`aws_iam_role_policy`), como antes (só o nome
mudou, de `lb-controller` para `lb-iam`, para não ser confundido com o
módulo `lb`) - só o lado Kubernetes do AWS Load Balancer Controller (`lb`)
é novo.

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

Zabbix, Loki, Tempo, Alloy, Prometheus **e o AWS Load Balancer Controller**
(módulos `zabbix`/`loki`/`tempo`/`alloy`/`prometheus`/`lb` acima) são
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

- `helm` (`hashicorp/helm`): usado pelos módulos `zabbix` (charts
  `zabbix-community/helm-zabbix` e `prometheus-community/kube-state-metrics`)
  e `lb` (chart `aws-load-balancer-controller` do repositório `eks-charts`).
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

### `zabbix_hostname`/`zabbix_server_host`

Identificam a infraestrutura pessoal do seu Zabbix server externo, por isso
sem default (`terra/variables.tf`) - defina os valores reais em
`terraform.tfvars`. O módulo `zabbix` os passa ao chart via `set` em
`helm.tf`, no lugar do antigo Secret aplicado manualmente fora do Flux -
`terraform.tfvars` já é a fonte de valores sensíveis deste ambiente (mesmo
padrão de `db_password`).

Passos manuais (uma vez, no seu Zabbix server - o Terraform não pode
aplicá-los, essa configuração vive no banco de dados do Zabbix):

1. **Criar o Proxy**: *Data collection → Proxies → Create proxy*. Nome igual
   ao `zabbix_hostname` de `terraform.tfvars`. Modo: **Active**.
2. Rodar `terraform apply` com `zabbix_hostname`/`zabbix_server_host` já
   preenchidos - a stack sobe junto com o resto do cluster.
3. **Pegar o token da ServiceAccount de leitura**:
   ```bash
   kubectl get secret zabbix-k8s-reader-token -n zabbix \
     -o jsonpath='{.data.token}' | base64 -d
   ```
4. **Pegar a URL da API do EKS**: `terraform output -raw configure_kubectl`.
5. **Importar as templates nativas do Zabbix** (Zabbix 6.4+, já inclusas):
   *Data collection → Templates → Kubernetes* - confirme **"Kubernetes nodes
   by HTTP"** e **"Kubernetes cluster state by HTTP"**.
6. **Criar os hosts do cluster EKS** a partir dessas templates, vinculados ao
   **Proxy** do passo 1 (não ao Zabbix server diretamente), preenchendo
   `{$KUBE.API.SERVER.URL}` (passo 4), `{$KUBE.API.TOKEN}` (passo 3) e
   `{$KUBE.NAMESPACE}` = `zabbix`.
7. **Verificar**: `kubectl logs -n zabbix -l app.kubernetes.io/component=proxy`
   deve mostrar a conexão ativa com o Zabbix server; no Zabbix, o Proxy deve
   aparecer com "last seen" recente.

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
dos módulos `zabbix`/`loki`/`tempo`/`alloy`/`prometheus`: por estarem no
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
