| [↩️ Voltar](./) |
| --- |

# Roteiro de implementação inicial do cluster K8s na AWS

> ⚠️ **_Em construção_**

Sequência mínima para implementar o ambiente EKS do zero e deixá-lo sob gestão do FluxCD, com logs, traces e métricas de negócio no Loki/Tempo/Prometheus self-hosted deste cluster e métricas de infraestrutura no seu Zabbix externo. Detalhes e justificativas de cada etapa estão em `terra/README.md`, `kube-aws/README.md`, `observe-aws/README.md` e `zabbix/README.md`; este roteiro só reúne os comandos na ordem correta.

<BR>

## Pré-requisitos

- `terraform` >= 1.6, `aws` CLI v2 configurado (permissão para criar VPC, EKS, RDS, DynamoDB, SQS, IAM e SSM).
- [`flux` CLI][fluxcli] instalado (usado tanto para o bootstrap quanto para validar a instalação).
- `kubectl` e `helm`.
- Um **Personal Access Token do GitHub** com escopo `repo` (e `admin:public_key`/`admin:org` se o repositório for de uma organização), exportado como `GITHUB_TOKEN` — é com ele que o `flux bootstrap github` autentica e faz commit das definições em `clusters/eks-aws/flux-system/`.
- O CIDR, IP ou domínio público de onde o seu Grafana externo vai consultar Loki/Tempo/Prometheus (para `observe_allowed_cidrs` em `terra/terraform.tfvars` - ver passo 1; um domínio, ex. de um DDNS para IP dinâmico, é resolvido via DNS a cada `terraform apply`).
- Um Zabbix server já em operação, acessível pela internet na porta 10051 (para `zabbixProxy.ZBX_SERVER_HOST` em `zabbix/020-helmrelease-zabbix.yaml` - ver passo 5).

<BR>

## 1. Provisionar a infraestrutura AWS com Terraform

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars, principalmente db_password e observe_allowed_cidrs
# (CIDR, IP ou domínio de onde o Grafana externo vai consultar
# Loki/Tempo/Prometheus - ver observe-aws/README.md; não deixe o valor de
# exemplo)

./init.sh   # cria bucket S3 + tabela DynamoDB do backend remoto (idempotente)

terraform plan
terraform apply
```

Ao final, aponte o `kubectl` local para o cluster criado:

```bash
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-east-1 --name solidarytech-eks-cluster
```

<BR>

## 2. Inicializar o FluxCD no cluster

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

Isso gera `clusters/eks-aws/flux-system/` (instala os controllers, cria o `GitRepository` apontando para este repositório e o `Kustomization` raiz) e faz commit + push direto na branch `main`. A partir daí, as `Kustomization`s já declaradas em `clusters/eks-aws/` passam a reconciliar de fato:

- `lb-controller` → `./lb-controller`
- `solidarytech` → `./kube-aws` (depende de `lb-controller`)
- `observe` → `./observe-aws` (depende de `lb-controller`)
- `zabbix` → `./zabbix`

```bash
flux get kustomizations
```

> **Este cluster não roda a `Kustomization` `image-automation`**: ela já reconcilia `./kube` a partir do `kubeadm-local` e faz commit+push direto em `main`; rodá-la também aqui faria dois Flux checarem o Docker Hub e tentarem commitar a mesma atualização de tag em paralelo.

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

Loki, Tempo e Prometheus já sobem sozinhos com a `Kustomization` `observe` do
passo 2 - nenhum passo manual de instalação aqui, diferente do fluxo antigo
do Grafana Cloud. Falta só cadastrar os 3 datasources no seu Grafana
externo, apontando para o DNS name da NLB:

```bash
terraform output -raw nlb_dns_name   # em terra/
```

- Loki: `http://<nlb_dns_name>:3100`
- Tempo: `http://<nlb_dns_name>:3200`
- Prometheus: `http://<nlb_dns_name>:9090`

Ver `observe-aws/README.md` para o restante da configuração (Service Graph,
derived field de `trace_id`, dashboard modelo).

<BR>

## 5. Conectar o cluster ao seu Zabbix

Etapa manual, fora do Flux, no lado do **Zabbix server** — ver
`zabbix/README.md` para o passo a passo completo (criar o Proxy, ajustar
`ZBX_SERVER_HOST` em `zabbix/020-helmrelease-zabbix.yaml`, importar as
templates nativas "Kubernetes nodes by HTTP"/"Kubernetes cluster state by
HTTP" usando o token da ServiceAccount `zabbix-k8s-reader`). A stack em si
(Zabbix Proxy + Agent2 + kube-state-metrics) já sobe sozinha com a
`Kustomization` `zabbix` do passo 2.

<BR>

## Referência: destruição do ambiente

Use `terra/destroy.sh` em vez de `terraform destroy` direto - hoje é um wrapper fino sobre o destroy (a NLB única de `terra/modules/nlb` está no state do Terraform, sem risco de ENI órfã como um `Service` `LoadBalancer` teria). Ver `terra/README.md` para o detalhamento.

```bash
cd terra
./destroy.sh
```

| [⬆️ Top](#roteiro-de-implementação-inicial-do-cluster-k8s-na-aws) |
| --- |

[fluxcli]: https://fluxcd.io/flux/installation/#install-the-flux-cli