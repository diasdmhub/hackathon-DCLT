| [↩️ Voltar](./) |
| --- |

# Roteiro de implementação inicial do cluster K8s na AWS

Esta é uma sequência de passos para a implementação do cluster Kubernetes, incluindo os recursos de infraestrutura, o AWS Load Balancer Controller, além de recursos de observabilidade e monitoração do ambiente, tudo via Terraform. Os microsserviços da SolidaryTech são gerenciados pelo FluxCD. Mais detalhes e justificativas de cada etapa estão disponíveis em [`terra/README.md`][terra] e [`kube-aws/README.md`][kubeaws]. Este roteiro foca nos passos para a ativação do ambiente AWS.

<BR>

## 🔑 Pré-requisitos

**1.** De preferência, faça um **"_fork_" deste repositório** para possibilitar a execução do _CI workflow_. Ele é utilizado para testar e, principalmente, para enviar as imagens dos microserviços ao Docker Hub.

> **É necessário habilitar o serviço de `Actions` no repositório.**

**2.** Inclua as credenciais de login do Docker Hub como _secrets_ do repositório. São necessários o `username` e o `token` do Docker Hub.

**3.** Copie todo o código-fonte do repositório para um ambiente de execução/desenvolvimento local. Recomenda-se **clonar o repositório com o Git**:

> **`git clone https://github.com/SUA_CONTA/FORK_DO_REPO.git && cd FORK_DO_REPO`**

**4.** O ambiente de execução/desenvolvimento local deve estar **autenticado na AWS** por meio do [**AWS CLI**][awscli], pois ele é utilizado em configurações do Terraform.

**5.** [**Instale o Terraform**][terraform] no ambiente de execução/desenvolvimento local para implementar os serviços da AWS que serão utilizados pela SolidaryTech;

**6.** O **`kubectl`** é muito eficiente para gerenciar o cluster Kubernetes e seus recursos, se necessário. Recomenda-se instalá-lo utilizando o [**repositório oficial do Kubernetes**][kuberepo];

**7.** A instalação do [**FluxCD CLI**][fluxcli] é opcional, pois o Terraform o instala e o configura. No entanto, o CLI é útil para consultar o estado da reconciliação (`flux get kustomizations`) ou realizar depurações, caso necessário.

**8.** É necessário ter uma instância [**Grafana Cloud**][grafanacloud] já em operação para o envio de dados de monitoramento e observabilidade.

<BR>

## 1. Variáveis Terraform

Para a implementação inicial, é necessário configurar alguns dados para permitir que o ambiente seja criado de maneira consistente.

O arquivo de [variáveis do Terraform][tfvars] (`terraform.tfvars`) deve ser preenchido com as principais variáveis do ambiente, incluindo senhas. Embora um arquivo de exemplo (`terraform.tfvars.example`) esteja disponível com alguns valores pré-definidos, **recomenda-se fortemente que as variáveis a seguir sejam ajustadas de acordo com o ambiente final**.

> ⚠️ **Note que este arquivo contém dados sensíveis, portanto, seu acesso deve ser restrito. Por isso, ele é ignorado pelo Git.**

> **Preencha os dados no host de controle da infraestrutura e guarde o arquivo completo em um local seguro fora da AWS. Um gerenciador de senhas, por exemplo, e não o armazene apenas no disco local.**

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
| `flux_chart_version` | Versão do chart Helm `flux2` usado por `terra/modules/flux` | _`2.19.0`_ |
| `grafana_cloud_remote_write_url` | Endpoint remote_write do Grafana Cloud Prometheus (opcional - vazio desativa o envio) | _(vazio)_ |
| `grafana_cloud_username` | Instance ID do stack Grafana Cloud de métricas (opcional) | _(vazio)_ |
| `grafana_cloud_api_key` | API key do Grafana Cloud com permissão de escrita em métricas (opcional, sensível) | _(vazio)_ |
| `grafana_cloud_loki_url` | Endpoint `loki.write` do Grafana Cloud Logs (opcional - vazio desativa o envio) | _(vazio)_ |
| `grafana_cloud_loki_username` | Instance ID do stack Grafana Cloud de Logs (opcional) | _(vazio)_ |
| `grafana_cloud_loki_api_key` | API key do Grafana Cloud com permissão de escrita em Logs (opcional, sensível) | _(vazio)_ |
| `grafana_cloud_tempo_endpoint` | Endpoint OTLP do Grafana Cloud Traces (opcional - vazio desativa o envio) | _(vazio)_ |
| `grafana_cloud_tempo_username` | Instance ID do stack Grafana Cloud de Traces (opcional) | _(vazio)_ |
| `grafana_cloud_tempo_api_key` | API key do Grafana Cloud com permissão de escrita em Traces (opcional, sensível) | _(vazio)_ |
| `enable_dr` | Habilita a proteção contínua de dados para DR (read replica cross-region sempre-vivo do RDS + Global Table do DynamoDB) | _`true`_ |
| `dr_aws_region` | Região AWS do ambiente passivo ([`terra-dr/`][terradr]) | _`us-west-2`_ |
| `rds_backup_retention_period` | Dias de retenção de backup automatizado do RDS (pré-requisito para criar o read replica cross-region) | _`7`_ |
| `dr_standby_subnet_prefix` | CIDR (2 primeiros octetos) da VPC mínima que hospeda o read replica sempre-vivo do RDS | _`10.95`_ |
| `dr_app_vpc_cidr` | CIDR da VPC de app do ambiente passivo ([`terra-dr/`][terradr]) - precisa bater com o `subnet_prefix` de lá | _`10.90.0.0/16`_ |
| `manage_dns` | Habilita a hosted zone Route53 + failover DNS entre os ambientes ativo/passivo | _`true`_ |
| `dns_zone_name` | Subdomínio delegado à hosted zone Route53 (_ex.: `solidarytech.meu.dominio`_) | _`CHANGE_ME`_ |
| `dns_record_name` | Nome do registro DNS com failover que os clientes usam (_ex.: `api.solidarytech.meu.dominio`_) | _`CHANGE_ME`_ |

> **As 9 variáveis do Grafana Cloud (3 para métricas, 3 para logs, 3 para traces) são opcionais, pois permitem que o Prometheus/Loki/Tempo enviem dados para fora do cluster, já que o armazenamento local não é replicado no ambiente passivo ([`terra-dr/`][terradr]). Consulte "Remote_write para o Grafana Cloud" e "Logs e traces para o Grafana Cloud" em [`terra/README.md`][terra].**

> **As variáveis de DR (`enable_dr`, `dr_aws_region`, `rds_backup_retention_period`, `manage_dns`, `dns_zone_name`, `dns_record_name`) já vêm habilitadas com valores padrão no arquivo `.example`, pois cobrem apenas a proteção contínua de dados (com custos reduzidos e sem necessidade de computação adicional). A ativação do ambiente passivo ([`terra-dr/`][terradr]) é feita separadamente e sob demanda (_veja o passo 4_).**

<BR>

## 2. Provisionamento de infraestrutura

Nesta etapa, a infraestrutura da AWS, o Load Balancer Controller, o FluxCD (_controladores que inicializam os microsserviços_) e os serviços de observabilidade e monitoramento serão provisionados com o uso do **Terraform**.

> **Os comandos a seguir devem ser executados a partir de um host de controle da infraestrutura.**

---

**2.1** Crie e edite o arquivo `terraform.tfvars`.

> **No mínimo o valor de `db_password` deve ser definido. Evite usar os valores de exemplo.**

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
```

**2.2** Execute o script de inicialização para criar o bucket S3, a tabela de estado do Terraform no DynamoDB e inicializar o Terraform.

```bash
./init.sh
```

**2.3** Na primeira inicialização de um cluster totalmente novo, os _providers_ `kubernetes`, `helm` e `kubectl` tentam usar _outputs_ do cluster EKS, que não existem em um estado vazio. Portanto, o cluster EKS deve ser criado primeiro. _Consulte "Uso" em terra/README.md (limitação de Terraform+EKS)_.

```bash
terraform plan -target=module.eks
terraform apply -target=module.eks
```

**2.4** Um segundo `apply` (já com o cluster criado) gera os demais recursos da AWS: instala o "_Load Balancer Controller_", instala o FluxCD e aplica o `GitRepository`/`Kustomization` que faz com que os 3 microsserviços ([`./kube-aws`][kubeaws]) sejam iniciados. Também é aplicado o `Loki`/`Tempo`/`Alloy`/`Prometheus` diretamente no cluster. Em clusters já existentes, onde o `module.eks` já foi criado, siga direto para o `terraform plan`/`apply` a seguir.

```bash
terraform plan
terraform apply
```

**2.5** Ao final, aponte o `kubectl` local para o cluster criado a fim de gerenciar os recursos K8s.

```bash
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-east-1 --name solidarytech-eks-cluster
```

<BR>

## 3. FluxCD no cluster

No passo 2, o `terraform apply` instalou os controladores do FluxCD e aplicou o `GitRepository` ([`clusters/eks-aws/flux-system/gotk-sync.yaml`][gotksync]), a `Kustomization` da SolidaryTech ([`clusters/eks-aws/solidarytech-kustomization.yaml`][solidkustom]) e o Secret `irsa-role-arns` com os ARNs reais das _roles_ IRSA, obtidos diretamente do módulo IAM.

Caso a URL/Branch do `GitRepository`, o `path`/`interval` da `Kustomization`, ou os ARNs de IRSA sejam alterados (_ex.: `terraform destroy`/`apply` recriando as roles_), basta executar o `terraform apply` novamente. Dessa forma, o Terraform concilia as diferenças, sem a necessidade de um `kubectl apply -f` manual.

```bash
# Consulta (requer o Flux CLI - opcional, ver Pré-requisitos)
flux get kustomizations
# Alternativa sem o Flux CLI
kubectl get kustomization solidarytech -n flux-system
```

<BR>

## 4. Preparar o ambiente passivo

Aproveite que o ambiente principal está ativo e saudável para preparar o `terraform.tfvars` do ambiente passivo ([`terra-dr/`][terradr]).

> ⚠️ **Não espere um desastre real para preparar os dados.**

Parte desses dados dependem do `terraform output` no ambiente ativo ([`terra/`][terra]), o que exige que o bucket S3 e a tabela DynamoDB do _backend_ remoto estejam acessíveis.

```bash
cd terra-dr
cp terraform.tfvars.example terraform.tfvars
```

A maioria das variáveis é de configuração estática, sem consulta alguma ao ambiente ativo. Elas também são semelhantes às variáveis do passo 1, portanto, preencha-as elas com os mesmos valores (ou equivalentes) do `terra/terraform.tfvars` já usado no passo 2.

Quatro variáveis são provenientes de dados do ambiente ativo:

- **`db_password`**: precisa ser **IGUAL** à senha real do ambiente ativo;
- **`route53_zone_id`**: copie este valor diretamente do Terraform;
    - Route53 é um serviço global da AWS, e o valor fica disponível no ambiente ativo: `terraform output -raw route53_zone_id`
- **`rds_dr_vpc_id`/`rds_dr_vpc_cidr`**: o _read replica cross-region_ sempre-vivo do RDS (`module.rds_dr_replica`) e sua VPC mínima (`module.dr_standby_vpc`) já existem desde a aplicação do `enable_dr = true` no ambiente principal.
    - É possível preencher as variáveis antecipadamente: `terraform output dr_standby_vpc_id` / `terraform output dr_standby_vpc_cidr`.
- **`rds_dr_connection_url`**: é possivel preencher com o valor de `terraform output -raw dr_replica_connection_url`;
    - A replica permanece **somente em modo de leitura** até a promoção (`var.promote_dr_db = true` em [`terra/`][terra]). Essa é a única ação nesse fluxo que é realmente restrita ao momento exato da ativação, portanto não é algo que possa ser preparado antecipadamente.

**Consulte [`doc/roteiro-dr-ativacao.md`][ativadr] para obter o passo a passo completo para ativação do DR.**

### DNS do failover (`manage_dns = true`)

As variáveis `dns_zone_name` e `dns_record_name` (passo 1) pressupõem um **domínio próprio**, que já deve ter sido registrado em algum registrador. Não é necessário que seja a Route53.

- `dns_zone_name` corresponde a um subdomínio desse domínio (_ex.: `solidarytech.meu.dominio`_), e não ao domínio raiz inteiro. O `terraform apply` do passo 2 cria a _hosted zone_ na Route53 para esse subdomínio, mas ela só resolve de fato depois que o domínio raiz **delegar** a resolução para ela.

Após o `apply`, é possivel consultar os nameservers gerados:

```bash
terraform output route53_name_servers
```

Cadastre esses 4 nameservers como registros **NS** do subdomínio (`dns_zone_name`) no provedor DNS do domínio raiz. É o mesmo provedor em que o domínio foi registrado ou em que seu DNS é gerenciado. Sem esse cadastro, `dns_record_name` não será resolvido, mesmo com a hosted zone e os registros `PRIMARY`/`SECONDARY` já criados no Route53.

> ⚠️ **O registro de domínios envolve custos antecipados, que estão fora do escopo deste projeto, e sua configuração pode variar de acordo com a região e o provedor. Eles não são obrigatórios para o projeto, mas, após a migração de clusters, auxiliam no acesso aos serviços, pois exigem menos ação manual.**

<BR>

## 5. Grafana externo

Loki, Tempo, Alloy e Prometheus são implementados com o `terraform apply` do passo 2. Se as variáveis do Grafana Cloud do passo 1 estiverem preenchidas, os logs/traces/métricas serão enviados para os _datasources_ nativos e hospedados do próprio Grafana Cloud (veja "Remote_write..." - "Logs e traces..." em [`terra/README.md`][terra]).

As 9 variáveis são obtidas diretamente na conta do Grafana Cloud.

- Métricas: `grafana_cloud_remote_write_url`/`_username`/`_api_key`;
- Logs: `grafana_cloud_loki_url`/`_username`/`_api_key`;
- Traces: `grafana_cloud_tempo_endpoint`/`_username`/`_api_key`.

**5.1** Acesse o [grafana.com][grafanacloud] e faça login em sua conta (ou crie uma; o **tier gratuito** é o suficiente).

**5.2** No portal do Grafana Cloud Stack, acesse os detalhes da Stack (_Details_). Em seguida, localize os recursos **Prometheus**, **Loki** e **Tempo**.

**5.3** Cada recurso apresenta a **URL de push** (`remote_write`/`loki.write`/OTLP endpoint) e o **Instance ID** (usado como username/basic-auth), prontos para serem copiados.

**5.4** Gere uma **API key** (ou "Cloud Access Policy Token") com permissão de escrita (`MetricsPublisher`/`LogsPublisher`/`TracesPublisher`, conforme o recurso) em **"Access Policies"**.

**5.5** Preencha esses valores em `terra/terraform.tfvars` (passo 1) e execute o comando `terraform apply` novamente. **Preencher qualquer um dos 3 grupos de variáveis ativa o envio remoto correspondente** de forma independente (métricas, logs ou traces). Deixar um grupo vazio mantém o envio correspondente desativado, sem afetar os demais.

<BR>

## Destruição do ambiente

> **É necessário estar conectado ao cluster da AWS.**

> **Caso o ambiente passivo ([`terra-dr/`][terradr]) tenha sido ativado, ele deve ser destrído antes do ambiente principal.**

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
[grafanacloud]: https://grafana.com/products/cloud/
[ativadr]: /doc/roteiro-dr-ativacao.md
[gotksync]: /clusters/eks-aws/flux-system/gotk-sync.yaml
[solidkustom]: clusters/eks-aws/solidarytech-kustomization.yaml
[terradr]: /terra-dr/
[terra]: /terra/
[kubeaws]: /kube-aws/