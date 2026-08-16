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

**3.** O ambiente de execução/desenvolvimento local deve estar **autenticado na AWS** com o [**AWS CLI**][awscli], pois ele é utilizado em configurações do Terraform.

**4.** É necessário [**instalar o Terraform**][terraform] no ambiente de execução/desenvolvimento local para implementar os serviços da AWS que serão utilizados pela SolidaryTech;

**5.** Um **Personal Access Token do GitHub** com escopo `repo` (_e `admin:public_key`/`admin:org` se o repositório for de uma organização_). Ele é utilizado para autenticação e commits do FluxCD e deve ser definido como uma variável de ambiente `GITHUB_TOKEN`.

**6.** O [FluxCD CLI][fluxcli] é utilizado para a inicialização dos microsserviços e para validar a instalação, caso necessário.

**7.** Apesar de não ser necessário posteriormente, o **`kubectl`** é necessário para a implementação inicial de forma automatizada, e ainda é muito eficiente para gerenciar o cluster Kubernetes e seus recursos, caso necessário. Recomenda-se instalá-lo utilizando o [**repositório oficial do Kubernetes**][kuberepo];

**8.** Um [Zabbix Server][zabbixdoc] já em operação, acessível pela cluster K8s na porta 10051.

**9.** Um [Grafana][grafanacloud] já em operação.

<BR>

## 1. Variáveis Terraform

Para a implementação inicial, é necessário configurar alguns dados para permitir que o ambiente seja criado de forma consistente.

O arquivo de [variáveis do Terraform][tfvars] (`terraform.tfvars`) deve ser definido com as principais variáveis do ambiente, incluindo a senhas. Embora seja disponibilizado um arquivo de exemplo (`terraform.tfvars.example`) com alguns valores pré-definidos, é **altamente recomendado que as variáveis a seguir sejam definidas de acordo com o ambiente final**.

> ⚠️ **Note que este arquivo contém dados sensíveis e deve ter seu acesso restrito. Ele é ignorado pelo Git.**

#### Lista de variáveis:

| Variável | Descrição | Default |
| :---: | :--- | :---: |
| `name_prefix` | Prefixo geral do nome dos recursos AWS | _`solidarytech`_ |
| `aws_region` | Regiao principal da AWS | _`us-east-1`_ |
| `subnet_prefix` | Os 2 primeiros octetos do CIDR da VPC | _`10.80`_ |
| `az_count` | Quantidade de AZs da AWS | _`2`_ |
| `eks_node_instance_types` | Tipo de instância EC2 para o cluster K8s (_free tier_) | _`m7i-flex.large`_ |
| `eks_node_desired_size` | Quantidade de instâncias ativas EC2 para o cluster K8s | _`2`_ |
| `eks_node_min_size` | Quantidade mínima de instâncias EC2 para o cluster K8s | _`1`_ |
| `eks_node_max_size` | Quantidade máxima de instâncias EC2 para o cluster K8s | _`4`_ |
| `enable_prefix_delegation` | Habilita o uso de prefixos de IP disponíveis para os nodes | _`true`_ |
| `db_name` | Nome do banco de dados inicial no RDS - PostgreSQL | _`sol_db`_ |
| `db_username` | Usuário master do PostgreSQL | _`sol`_ |
| `db_password` | Senha do usuário master do PostgreSQL | _`CHANGE_ME`_ |
| `rds_instance_class` | Tipo de instância RDS para o DB | _`db.t3.micro`_ |
| `dynamodb_table_name` | Nome da tabela da SolidaryTech no DynamoDB | _`SolidaryTechVolunteers`_ |
| `sqs_queue_name` | Nome da fila do Donation Service no SQS | _`donation-events`_ |
| `k8s_namespace` | Nome do namespace da SolidaryTech no K8s | _`solidarytech`_ |
| `donation_service_account` | Nome da service account do Donation Service | _`donation-service`_ |
| `volunteer_service_account` | Nome da service account do Volunteer Service | _`volunteer-service`_ |
| `lb_controller_namespace` | Namespace para o Load Balancer Controller | _`kube-system`_ |
| `lb_controller_service_account` | ServiceAccount do Load Balancer Controller | _`aws-load-balancer-controller`_ |
| `observe_allowed_cidrs` | CIDR, IP ou domínio autorizados a alcançar o cluster | _`CHANGE_ME`_ |
| `zabbix_hostname` | Nome do Proxy criado no Zabbix server | _`CHANGE_ME-proxy-eks-solidarytech`_ |
| `zabbix_server_host` | Hostname/IP desse do Zabbix Server | _`CHANGE_ME`_ |
| `zabbix_version` | Versão major do Zabbix Proxy/Agent2 | _`7.4`_ |

<BR>

## 2. Provisionamento de infraestrutura

Neste passo serão provisionados a infraestrutura AWS, Load Balancer Controller, serviços de observabilidade e monitoramento com o Terraform. Os comandos abaixo devem ser executados a partir de um host de controle da infraestrutura.

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars: no mínimo `db_password`, `observe_allowed_cidrs`
# e `zabbix_hostname`/`zabbix_server_host`; não use os valores de exemplo.

./init.sh   # cria bucket S3 + tabela DynamoDB + inicializa Terraform (idempotente)

# Na primeira inicialização, com um cluster totalmente novo, os providers
# kubernetes/helm/kubectl tentam usar outputs do cluster EKS, que não
# existem num state vazio. Portantanto, o cluster deve ser criado primeiro.
# Vide "Uso" em terra/README.md (limitação de Terraform+EKS).
terraform plan -target=module.eks
terraform apply -target=module.eks

# Um segundo `apply` (já num state com o cluster criado) cria os demais recursos 
# AWS, instala o Load Balancer Controller, e aplica o Loki/Tempo/Alloy/Prometheus
# e o Zabbix Proxy/Agent2/kube-state-metrics direto no cluster, através dos providers
# `helm`/`kubernetes`/`kubectl`. Nenhum desses passa pelo FluxCD, (`terra/README.md`).
# A ordem entre eles passa por dependências do Terraform. Não precisa de mais um
# `apply` além do `-target=module.eks` inicial. Em clusters já existentes
# (`module.eks` criado), siga direto para o `terraform plan`/`apply`.
terraform plan
terraform apply
```

Ao final, aponte o `kubectl` local para o cluster criado:

```bash
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-east-1 --name solidarytech-eks-cluster
```

<BR>

## 3. Inicializar o FluxCD no cluster (microsserviços)

Com o `flux` CLI instalado e o `kubectl` já apontando para o cluster criado no passo anterior, valide os pré-requisitos e rode o _bootstrap_ contra o GitHub.

```bash
flux check --pre

export GITHUB_TOKEN=<personal-access-token>

flux bootstrap github \
    --owner=[CONTA DO GITHUB] \
    --repository=hackathon-DCLT \
    --branch=main \
    --path=./clusters/eks-aws \
    --personal \
    --token-auth
```

Isso instala os controladores (_`clusters/eks-aws/flux-system/`_) do FluxCD, cria o `GitRepository` apontando para o repositório determinado e o `Kustomization` raiz. Ele faz _commit_ e _push_ direto na branch `main` do repositório. A partir daí, o `Kustomization` já declarado em `clusters/eks-aws/` passa a se reconciliar com o cluster, criando os serviços da SolidaryTech.

O Namespace `solidarytech` e os Secrets `ngo-env`, `donation-env` e `volunteer-env` (string de conexão real do RDS) já existem nesse ponto, pois foram criados pelo `terraform apply` do passo 2 (`kubernetes_namespace_v1.solidarytech` e `module.secrets`), não pelo Flux (vide `kube-aws/README.md`, seção "Secrets").

```bash
flux get kustomizations  # Consulta
```

<BR>

## 4. Configurar o Grafana externo

Loki, Tempo e Prometheus são implementados com o `terraform apply` do passo 2. Após isso, é necessário cadastrar os 3 datasources no Grafana externo, apontando para o DNS name do NLB.

```bash
terraform output -raw nlb_dns_name   # no diretório `terra/`
```

- Loki: `http://<nlb_dns_name>:3100`
- Tempo: `http://<nlb_dns_name>:3200`
- Prometheus: `http://<nlb_dns_name>:9090`

> **Ver `doc/observabilidade.md` para o restante da configuração para mais informação.**

<BR>

## 5. Conectar o cluster ao seu Zabbix

Também é necessário configurar o **lado do seu Zabbix Server**. Veja a seção "Observabilidade e monitoração de infraestrutura via Terraform" em `terra/README.md` para mais informações: criar o Proxy, obter o token da ServiceAccount `zabbix-k8s-reader` e importar/vincular as templates do Kubernetes.

<BR>

## Destruição do ambiente

> **É necessário estar conectado ao cluster AWS.**

```bash
cd terra
terraform destroy
```

| [⬆️ Top](#roteiro-de-implementação-inicial-do-cluster-k8s-na-aws) |
| --- |

[awscli]: https://aws.amazon.com/cli
[terraform]: https://developer.hashicorp.com/terraform/install
[fluxcli]: https://fluxcd.io/flux/installation/#install-the-flux-cli
[kuberepo]: https://kubernetes.io/docs/tasks/tools
[tfvars]: /terra/terraform.tfvars.example
[zabbixdoc]: https://www.zabbix.com/documentation/current/en
[grafanacloud]: https://grafana.com/products/cloud/