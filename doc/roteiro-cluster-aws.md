| [↩️ Voltar](./) |
| --- |

# Roteiro de implementação inicial do cluster K8s na AWS

> ⚠️ **_Em construção_**

Sequência mínima para implementar o ambiente EKS do zero: infraestrutura AWS, o AWS Load Balancer Controller, observabilidade (Loki/Tempo/Alloy/Prometheus self-hosted) e monitoração de infraestrutura (Zabbix), tudo via Terraform - só os microsserviços da SolidaryTech ficam sob gestão do FluxCD. Detalhes e justificativas de cada etapa estão em `terra/README.md` e `kube-aws/README.md`; este roteiro só reúne os comandos na ordem correta.

<BR>

## Pré-requisitos

- `terraform` >= 1.6, `aws` CLI v2 configurado (permissão para criar VPC, EKS, RDS, DynamoDB, SQS, IAM e SSM). É só o que o passo 1 exige - os providers `helm`/`kubernetes`/`kubectl` do Terraform conversam direto com a API do EKS, sem precisar dos CLIs `helm`/`kubectl` instalados.
- [`flux` CLI][fluxcli] instalado (usado no passo 2, para o bootstrap dos microsserviços e para validar a instalação).
- `kubectl` (para inspecionar o cluster e para os passos manuais do Zabbix).
- Um **Personal Access Token do GitHub** com escopo `repo` (e `admin:public_key`/`admin:org` se o repositório for de uma organização), exportado como `GITHUB_TOKEN` — é com ele que o `flux bootstrap github` autentica e faz commit das definições em `clusters/eks-aws/flux-system/`.
- O CIDR, IP ou domínio público de onde o seu Grafana externo vai consultar Loki/Tempo/Prometheus (para `observe_allowed_cidrs` em `terra/terraform.tfvars` - ver passo 1; um domínio, ex. de um DDNS para IP dinâmico, é resolvido via DNS a cada `terraform apply`).
- Um Zabbix server já em operação, acessível pela internet na porta 10051 (para `zabbix_server_host`/`zabbix_hostname` em `terra/terraform.tfvars` - ver passo 1 e passo 4).

<BR>

## 1. Provisionar a infraestrutura AWS, o AWS Load Balancer Controller, observabilidade e Zabbix com Terraform

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars: no mínimo db_password, observe_allowed_cidrs
# (CIDR, IP ou domínio de onde o Grafana externo vai consultar
# Loki/Tempo/Prometheus) e zabbix_hostname/zabbix_server_host (identificam
# o Proxy e o servidor do seu Zabbix externo - ver terra/README.md);
# não deixe os valores de exemplo.

./init.sh   # cria bucket S3 + tabela DynamoDB do backend remoto (idempotente)

terraform plan
terraform apply
```

Este único `apply` cria a VPC/EKS/RDS/etc., instala o AWS Load Balancer
Controller (`terra/modules/lb`), e já aplica Loki/Tempo/Alloy/Prometheus
(`terra/modules/{loki,tempo,alloy,prometheus}`) e o Zabbix Proxy/Agent2/kube-state-metrics
(`terra/modules/zabbix`) direto no cluster, via os providers `helm`/`kubernetes`/`kubectl`
— nenhum desses passa pelo Flux, ver `terra/README.md` para o porquê. A
ordem entre eles (controller antes dos `TargetGroupBinding` de
Loki/Tempo/Prometheus) já é garantida pelo grafo de dependências do próprio
Terraform - não precisa de um segundo `apply`.

Ao final, aponte o `kubectl` local para o cluster criado:

```bash
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-east-1 --name solidarytech-eks-cluster
```

<BR>

## 2. Inicializar o FluxCD no cluster (microsserviços)

Com o `flux` CLI instalado e o `kubectl` já apontando para o cluster criado no passo anterior, valide os pré-requisitos e rode o bootstrap contra o GitHub:

```bash
flux check --pre

export GITHUB_TOKEN=<seu-personal-access-token>

flux bootstrap github \
    --owner=diasdmhub \
    --repository=hackathon-DCLT \
    --branch=main \
    --path=./clusters/eks-aws \
    --personal \
    --token-auth
```

Isso gera `clusters/eks-aws/flux-system/` (instala os controllers, cria o `GitRepository` apontando para este repositório e o `Kustomization` raiz) e faz commit + push direto na branch `main`. A partir daí, a `Kustomization` já declarada em `clusters/eks-aws/` passa a reconciliar de fato:

- `solidarytech` → `./kube-aws`

```bash
flux get kustomizations
```

> **Este cluster não roda a `Kustomization` `image-automation`**: ela já reconcilia `./kube` a partir do `kubeadm-local` e faz commit+push direto em `main`; rodá-la também aqui faria dois Flux checarem o Docker Hub e tentarem commitar a mesma atualização de tag em paralelo. **Também não há `Kustomization` `lb-controller`/`observe`/`zabbix`** aqui: esses componentes já foram aplicados pelo Terraform no passo 1, não pelo Flux — ver `CLAUDE.md`. `solidarytech` não declara `dependsOn` por causa disso: o AWS Load Balancer Controller (e o CRD `TargetGroupBinding` que `kube-aws/` usa) já existe desde o passo 1, contanto que ele tenha rodado antes deste passo.

<BR>

## 3. Aplicar os Secrets que o Flux não gerencia

Os Secrets `ngo-env`, `donation-env` e `volunteer-env` ficam de fora do Flux de propósito, pois contêm a string de conexão real do RDS. Depois que o namespace `solidarytech` existir (criado pela `Kustomization` `solidarytech` no passo anterior):

```bash
cp kube-aws/040-ngo/041-secret.example.yaml kube-aws/040-ngo/041-secret.yaml
cp kube-aws/050-donation/051-secret.example.yaml kube-aws/050-donation/051-secret.yaml
cp kube-aws/060-volunteer/061-secret.example.yaml kube-aws/060-volunteer/061-secret.yaml
# preencha DATABASE_URL em cada arquivo (terraform output rds_outputs, ou
# aws ssm get-parameter no parâmetro já populado por terra/modules/secrets)

kubectl apply -f kube-aws/040-ngo/041-secret.yaml
kubectl apply -f kube-aws/050-donation/051-secret.yaml
kubectl apply -f kube-aws/060-volunteer/061-secret.yaml
```

<BR>

## 4. Configurar o Grafana externo

Loki, Tempo e Prometheus já sobem sozinhos com o `terraform apply` do passo 1
- nenhum passo manual de instalação aqui. Falta só cadastrar os 3
datasources no seu Grafana externo, apontando para o DNS name da NLB:

```bash
terraform output -raw nlb_dns_name   # em terra/
```

- Loki: `http://<nlb_dns_name>:3100`
- Tempo: `http://<nlb_dns_name>:3200`
- Prometheus: `http://<nlb_dns_name>:9090`

Ver `doc/observabilidade.md` para o restante da configuração (Service Graph,
derived field de `trace_id`, dashboard modelo).

<BR>

## 5. Conectar o cluster ao seu Zabbix

O Zabbix Proxy + Agent2 + kube-state-metrics já sobem sozinhos com o
`terraform apply` do passo 1 (`zabbix_hostname`/`zabbix_server_host` de
`terraform.tfvars`) - falta só a configuração do **lado do seu Zabbix
server**, que nenhuma ferramenta deste repositório consegue aplicar (vive no
banco de dados do próprio Zabbix). Ver a seção "Observabilidade e
monitoração de infraestrutura via Terraform" em `terra/README.md` para o
passo a passo completo: criar o Proxy, pegar o token da ServiceAccount
`zabbix-k8s-reader`, e importar/vincular as templates nativas "Kubernetes
nodes by HTTP"/"Kubernetes cluster state by HTTP".

<BR>

## Referência: destruição do ambiente

Use `terra/destroy.sh` em vez de `terraform destroy` direto - hoje é um wrapper fino sobre o destroy (a NLB única de `terra/modules/nlb` está no state do Terraform, sem risco de ENI órfã como um `Service` `LoadBalancer` teria). Ver `terra/README.md` para o detalhamento, incluindo o cuidado com os recursos `kubernetes_*`/`helm_release` de observabilidade/Zabbix (também no state, mas exigem a API do EKS alcançável durante o destroy).

```bash
cd terra
./destroy.sh
```

| [⬆️ Top](#roteiro-de-implementação-inicial-do-cluster-k8s-na-aws) |
| --- |

[fluxcli]: https://fluxcd.io/flux/installation/#install-the-flux-cli
