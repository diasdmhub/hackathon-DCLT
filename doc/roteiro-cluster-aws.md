| [↩️ Voltar](./) |
| --- |

# Roteiro de implementação inicial do cluster AWS

> ⚠️ **_Em construção_**

Sequência mínima para provisionar o ambiente EKS do zero e deixá-lo sob gestão do FluxCD, com logs/traces chegando ao Grafana Cloud. Detalhes e justificativas de cada etapa estão em `terra/README.md`, `kube-aws/README.md` e `observe-aws/README.md`; este roteiro só reúne os comandos na ordem correta.

<BR>

## Pré-requisitos

- `terraform` >= 1.6, `aws` CLI v2 configurado (permissão para criar VPC, EKS, RDS, DynamoDB, SQS, IAM e SSM).
- [`flux` CLI][fluxcli] instalado (usado tanto para o bootstrap quanto para validar a instalação).
- `kubectl` e `helm`.
- Um **Personal Access Token do GitHub** com escopo `repo` (e `admin:public_key`/`admin:org` se o repositório for de uma organização), exportado como `GITHUB_TOKEN` — é com ele que o `flux bootstrap github` autentica e faz commit das definições em `clusters/eks-aws/flux-system/`.
- Uma conta no Grafana Cloud (plano gratuito é suficiente para o volume deste ambiente).

<BR>

## 1. Provisionar a infraestrutura AWS com Terraform

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars, principalmente db_password

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
  --personal
```

Isso gera `clusters/eks-aws/flux-system/` (instala os controllers, cria o `GitRepository` apontando para este repositório e o `Kustomization` raiz) e faz commit + push direto na branch `main`. A partir daí, as duas `Kustomization`s já declaradas em `clusters/eks-aws/` passam a reconciliar de fato:

- `solidarytech` → `./kube-aws`
- `observe` → `./observe-aws`

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

## 4. Conectar o cluster ao Grafana Cloud

Etapa manual, fora do Flux — ver `observe-aws/README.md` para o porquê.

1. No Grafana Cloud: **seu stack → Connections → Add new connection → Kubernetes**. Informe o nome do cluster (`solidarytech-eks-cluster`) e selecione ao menos logs e traces.
2. Copie o comando `helm install` gerado pelo assistente (já inclui `helm repo add grafana ...`, `--namespace observe` e as credenciais do seu stack) e rode-o contra o cluster:

```bash
# comando gerado pelo Grafana Cloud - não versionar, contém token embutido
helm install ... --namespace observe ...
```

O namespace `observe` já existe nesse ponto (criado pela `Kustomization` `observe` no passo 2). Se o token expirar ou for rotacionado, gere um novo comando na mesma tela e rode `helm upgrade`.

<BR>

## Referência: destruição do ambiente

Use `terra/destroy.sh` em vez de `terraform destroy` direto — ele suspende as `Kustomization`s do Flux, remove os `Service` `LoadBalancer` (evita ENIs órfãs bloqueando a exclusão da VPC) e só então roda o destroy. Ver `terra/README.md` para o detalhamento.

```bash
cd terra
./destroy.sh
```

| [⬆️ Top](#roteiro-de-implementação-inicial-do-cluster-aws) |
| --- |

[fluxcli]: https://fluxcd.io/flux/installation/#install-the-flux-cli
