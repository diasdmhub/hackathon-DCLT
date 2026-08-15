| [↩️ Voltar](./) |
| --- |

# Roteiro de implementação inicial do cluster K8s na AWS

> ⚠️ **_Em construção_**

Esta é uma sequência de passos para a implementação do ambiente EKS, incluindo os recursos de infraestrutura AWS, o AWS Load Balancer Controller, recursos de observabilidade (Loki/Tempo/Alloy/Prometheus self-hosted) e monitoração de do ambiente (Zabbix), tudo via Terraform. Os microsserviços da SolidaryTech ficam sob gestão do FluxCD. Detalhes e justificativas de cada etapa estão em `terra/README.md` e `kube-aws/README.md`; este roteiro só reúne os comandos na ordem correta.

<BR>

## 🔑 Pré-requisitos

**1.** De preferência, faça um **"_fork_" deste repositório** para possibilitar a execução do CI workflow. Ele é utilizado para testar e, principalmente, para enviar as imagens dos microserviços ao Docker Hub.

> **É necessário habilitar o serviço de `Actions` no repositório.**

**2.** Copie todo o código-fonte do repositório para um ambiente de execução/desenvolvimento local. Recomenda-se **clonar o repositório com o Git**:

> **`git clone https://github.com/SUA_CONTA/FORK_DO_REPO.git && cd FORK_DO_REPO`**

**3.** O ambiente de execução/desenvolvimento local deve estar **autenticado na AWS** com o [**AWS CLI**][awscli], pois ele será utilizado em algumas configurações mais adiante.

**4.** É necessário [**instalar o Terraform**][terraform] no ambiente de execução/desenvolvimento local para implementar os serviços da AWS que serão utilizados pela SolidaryTech;

**5.** Um **Personal Access Token do GitHub** com escopo `repo` (_e `admin:public_key`/`admin:org` se o repositório for de uma organização_). Ele é utilizado para autenticação e commits do FluxCD e deve ser definido como uma variável de ambiente `GITHUB_TOKEN`.

**6.** O [FluxCD CLI][fluxcli] é utilizado para a inicialização dos microsserviços e para validar a instalação, caso necessário.

**7.** (_Opcional_) Apesar de não ser necessário, o **`kubectl`** ainda é muito eficiente para gerenciar o cluster Kubernetes e seus recursos. Caso necessário, recomenda-se instalá-lo utilizando o [**repositório oficial do Kubernetes**][kuberepo];

<BR>

## 1. Variáveis Terraform

Para a implementação inicial, é necessário configurar alguns dados para permitir que o ambiente seja criado de forma consistente.

O arquivo de [variáveis do Terraform][tfvars] (`terraform.tfvars`) deve ser definido com as principais variáveis do ambiente, incluindo a senhas. Embora seja disponibilizado um arquivo de exemplo (`terraform.tfvars.example`) com alguns valores pré-definidos, é **altamente recomendado que as variáveis a seguir sejam definidas de acordo com o ambiente final**.

> ⚠️ **Note que este arquivo contém dados sensíveis e deve ter seu acesso restrito. Ele é ignorado pelo Git.**


| Variável | Descrição | Default |
| :---: | :--- | :--- |
| `name_prefix` | Prefixo geral do nome dos recursos AWS | _`solidarytech`_ |
| `aws_region` | Regiao principal da AWS | _`us-east-1`_ |
| `subnet_prefix` | Os 2 primeiros octetos do CIDR da VPC | _`10.80`_ |
| `az_count` | Quantidade de AZs da AWS | _`2`_ |
| `eks_node_instance_types` | Tipo de instância EC2 para o cluster K8s (_free tier_) | _`m7i-flex.large`_ |
| `eks_node_desired_size` | Quantidade de instâncias ativas EC2 para o cluster K8s | _`2`_ |
| `eks_node_min_size` | Quantidade mínima de instâncias EC2 para o cluster K8s | _`1`_ |
| `eks_node_max_size` | Quantidade máxima de instâncias EC2 para o cluster K8s | _`4`_ |
| `enable_prefix_delegation` | Habilita o uso de prefixos de IP disponíveis para os nodes | _`true`_ |
| `db_name` | Nome do banco de dados inicial no RDS | _vazio_ |
| `db_username` | Usuário master do PostgreSQL | _vazio_ |
| `db_password` | Senha do usuário master | _vazio_ |
| `git_org` | Domínio provedor Git | _vazio_ |
| `git_repo` | Nome do repositório do provedor Git | _fiap-toggle-master-stack_ |
| `service_type` | Tipo de serviço para o ArgoCD | _ClusterIP_ |
| `grafana_pass` | Senha do usuário admin do Grafana | _vazio_ |
| `grafana_service_type` | Tipo de serviço do Grafana | _ClusterIP_ |

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

# Só na primeira vez, contra um backend/cluster totalmente novo: os
# providers kubernetes/helm/kubectl (usados abaixo) autenticam com outputs
# do cluster EKS, que ainda não existem num state vazio - crie só o cluster
# primeiro. Ver "Uso" em terra/README.md para o porquê (limitação clássica
# de Terraform+EKS, não algo específico deste repositório).
terraform apply -target=module.eks

terraform plan
terraform apply
```

Esse segundo `apply` (já num state com o cluster criado) cria o resto -
RDS/DynamoDB/SQS/IAM/NLB/etc., instala o AWS Load Balancer Controller
(`terra/modules/lb`), e já aplica Loki/Tempo/Alloy/Prometheus
(`terra/modules/{loki,tempo,alloy,prometheus}`) e o Zabbix Proxy/Agent2/kube-state-metrics
(`terra/modules/zabbix`) direto no cluster, via os providers `helm`/`kubernetes`/`kubectl`
— nenhum desses passa pelo Flux, ver `terra/README.md` para o porquê. A
ordem entre eles (controller antes dos `TargetGroupBinding` de
Loki/Tempo/Prometheus) já é garantida pelo grafo de dependências do próprio
Terraform - não precisa de mais um `apply` além do `-target=module.eks`
inicial. Em clusters já existentes (`module.eks` já no state), pule direto
para `terraform plan`/`apply`.

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

[awscli]: https://aws.amazon.com/cli
[terraform]: https://developer.hashicorp.com/terraform/install
[fluxcli]: https://fluxcd.io/flux/installation/#install-the-flux-cli
[kuberepo]: https://kubernetes.io/docs/tasks/tools
[tfvars]: /terra/terraform.tfvars.example