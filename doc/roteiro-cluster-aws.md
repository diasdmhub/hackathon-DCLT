| [↩️ Voltar](./) |
| --- |

# Roteiro de implementação inicial do cluster K8s na AWS

Esta é uma sequência de passos para a implementação do ambiente EKS, incluindo os recursos de infraestrutura AWS, o AWS Load Balancer Controller e recursos de observabilidade e monitoração do ambiente (Loki/Tempo/Alloy/Prometheus self-hosted, este último complementado por kube-state-metrics e node-exporter para as métricas de cluster/pod), tudo via Terraform. Os microsserviços da SolidaryTech ficam sob gestão do FluxCD. Detalhes e justificativas de cada etapa estão em `terra/README.md` e `kube-aws/README.md`; este roteiro só reúne os comandos na ordem correta.

<BR>

## 🔑 Pré-requisitos

**1.** De preferência, faça um **"_fork_" deste repositório** para possibilitar a execução do CI workflow. Ele é utilizado para testar e, principalmente, para enviar as imagens dos microserviços ao Docker Hub.

> **É necessário habilitar o serviço de `Actions` no repositório.**

**2.** Copie todo o código-fonte do repositório para um ambiente de execução/desenvolvimento local. Recomenda-se **clonar o repositório com o Git**:

> **`git clone https://github.com/SUA_CONTA/FORK_DO_REPO.git && cd FORK_DO_REPO`**

**3.** O ambiente de execução/desenvolvimento local deve estar **autenticado na AWS** com o [**AWS CLI**][awscli], pois ele é utilizado em configurações do Terraform.

**4.** É necessário [**instalar o Terraform**][terraform] no ambiente de execução/desenvolvimento local para implementar os serviços da AWS que serão utilizados pela SolidaryTech;

**5.** O **`kubectl`** é muito eficiente para gerenciar o cluster Kubernetes e seus recursos, caso necessário. Recomenda-se instalá-lo utilizando o [**repositório oficial do Kubernetes**][kuberepo];

**6.** O [FluxCD CLI][fluxcli] é opcional, pois o Terraform instala e configura ele, mas o CLI continua útil para consultar o estado da reconciliação (`flux get kustomizations`) ou depurar, caso necessário.

**7.** Um [Grafana][grafanacloud] já em operação.

<BR>

## 1. Variáveis Terraform

Para a implementação inicial, é necessário configurar alguns dados para permitir que o ambiente seja criado de forma consistente.

O arquivo de [variáveis do Terraform][tfvars] (`terraform.tfvars`) deve ser definido com as principais variáveis do ambiente, incluindo senhas. Embora seja disponibilizado um arquivo de exemplo (`terraform.tfvars.example`) com alguns valores pré-definidos, é **altamente recomendado que as variáveis a seguir sejam definidas de acordo com o ambiente final**.

> ⚠️ **Note que este arquivo contém dados sensíveis e deve ter seu acesso restrito. Portanto, ele é ignorado pelo Git.**

> **Preencha os dados no host de controle da infraestrutura e guarde o arquivo completo em um local seguro fora da AWS. Um gerenciador de senhas, por exemplo, não somente no disco local.**

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
| `dr_aws_region` | Região AWS do ambiente passivo (`terra-dr/`) | _`us-west-2`_ |
| `rds_backup_retention_period` | Dias de retenção de backup automatizado do RDS (pré-requisito para criar o read replica cross-region) | _`7`_ |
| `dr_standby_subnet_prefix` | CIDR (2 primeiros octetos) da VPC mínima que hospeda o read replica sempre-vivo do RDS | _`10.95`_ |
| `dr_app_vpc_cidr` | CIDR da VPC de app do ambiente passivo (`terra-dr/`) - precisa bater com o `subnet_prefix` de lá | _`10.90.0.0/16`_ |
| `manage_dns` | Habilita a hosted zone Route53 + failover DNS entre os ambientes ativo/passivo | _`true`_ |
| `dns_zone_name` | Subdomínio delegado à hosted zone Route53 (_ex.: `solidarytech.meu.dominio`_) | _`CHANGE_ME`_ |
| `dns_record_name` | Nome do registro DNS com failover que os clientes usam (_ex.: `api.solidarytech.meu.dominio`_) | _`CHANGE_ME`_ |

> As 9 variáveis de Grafana Cloud (3 para métricas, 3 para logs, 3 para traces) são opcionais: servem para Prometheus/Loki/Tempo enviarem (via `remote_write`/`loki.write`/`otelcol.exporter.otlp`) os dados para fora do cluster, já que o armazenamento local (PVC, retenção curta) não é replicado para o ambiente passivo (`terra-dr/`). Ver "Remote_write para o Grafana Cloud" e "Logs e traces para o Grafana Cloud" em `terra/README.md`, e o passo 5 abaixo para onde obter esses valores.

> As variáveis de DR (`enable_dr`, `dr_aws_region`, `rds_backup_retention_period`, `manage_dns`, `dns_zone_name`, `dns_record_name`) vêm com valores padrão já habilitados no `.example`, pois cobrem apenas a proteção contínua de dados (barata, sem compute extra) - o ambiente passivo em si (`terra-dr/`) continua uma ativação separada e sob demanda, ver passo 4. `dns_zone_name`/`dns_record_name` exigem um domínio próprio já registrado (fora da AWS ou não) para funcionar - ver passo 4.

<BR>

## 2. Provisionamento de infraestrutura

Neste passo serão provisionados a infraestrutura AWS, o Load Balancer Controller, o FluxCD (controladores + bootstrap dos microsserviços) e os serviços de observabilidade e monitoramento, tudo com o Terraform.

> **Os comandos abaixo devem ser executados a partir de um host de controle da infraestrutura.**

---

Crie e edite o arquivo `terraform.tfvars`. **Evite usar os valores de exemplo.**

> **No mínimo `db_password` deve ser definido.**

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
```

Execute o script de inicialização para criar o bucket S3, a tabela de estado do Terraform no DynamoDB e inicializar o Terraform.

```bash
./init.sh
```

Na primeira inicialização, com um cluster totalmente novo, os providers `kubernetes/helm/kubectl` tentam usar outputs do cluster EKS, que não existem num _state_ vazio. Portantanto, o cluster EKS deve ser criado primeiro. _Vide "Uso" em terra/README.md (limitação de Terraform+EKS)_.

```bash
terraform plan -target=module.eks
terraform apply -target=module.eks
```

Um segundo `apply` (já com o cluster criado) gera os demais recursos AWS: instala o "_Load Balancer Controller_", instala o FluxCD e aplica o `GitRepository`/`Kustomization` que faz os 3 microsserviços (`./kube-aws`) subirem, e também aplica o `Loki/Tempo/Alloy/Prometheus` direto no cluster. A ordem entre eles passa por dependências do Terraform. Em clusters já existentes (com o `module.eks` criado), siga direto para o `terraform plan`/`apply`.

```bash
terraform plan
terraform apply
```

Ao final, aponte o `kubectl` local para o cluster criado.

```bash
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-east-1 --name solidarytech-eks-cluster
```

<BR>

## 3. FluxCD no cluster

O `terraform apply` do passo 2 já instalou os controladores do FluxCD e aplicou o `GitRepository` (`clusters/eks-aws/flux-system/gotk-sync.yaml`), a `Kustomization` da SolidaryTech (`clusters/eks-aws/solidarytech-kustomization.yaml`) e o Secret `irsa-role-arns` com os ARNs reais das roles IRSA, vindos direto de `module.iam`.

Se um dia o `url`/`branch` do `GitRepository`, o `path`/`interval` da `Kustomization`, ou os ARNs de IRSA mudarem (_ex.: `terraform destroy`/`apply` recriando as roles_), basta executar o `terraform apply` novamente. Assim, o Terraform reconcilia a diferença, sem a necessidade de um `kubectl apply -f` manual.

```bash
flux get kustomizations  # Consulta (requer o Flux CLI - opcional, ver Pré-requisitos)
kubectl get kustomization solidarytech -n flux-system  # Alternativa sem o Flux CLI
```

<BR>

## 4. Preparar o ambiente passivo

Aproveite que o ambiente principal está ativo e saudável para deixar pronto o `terraform.tfvars` do ambiente passivo (`terra-dr/`).

> **Não espere um desastre real para preparar os dados.**

Parte dos dados dependem do `terraform output` no ambiente ativo, o `terra/`, o que exige que o bucket S3 e a tabela DynamoDB do backend remoto estejam acessíveis.

```bash
cd terra-dr
cp terraform.tfvars.example terraform.tfvars
```

A maioria das variáveis é de configuração estática, sem nenhuma consulta ao ambiente ativo. Elas também são similares às variáveis do passo 1. Preencha elas com os mesmos valores (ou equivalentes) do `terra/terraform.tfvars` já usado no passo 2.

Quatro variáveis vêm de outputs do `terra/`:

- **`db_password`**: precisa ser **IGUAL** à senha real do ambiente ativo, mas não de consulta ao parâmetro SSM criado por `module.secrets`.
- **`route53_zone_id`**: copie este valor direto do `terra/` (_Route53 é um serviço global da AWS, e o valor está pronto no ambiente ativo_): `terraform output -raw route53_zone_id`
- **`rds_dr_vpc_id`/`rds_dr_vpc_cidr`**: o read replica cross-region sempre-vivo do RDS (`module.rds_dr_replica`) e sua VPC mínima (`module.dr_standby_vpc`) já existem desde que `terra/` foi aplicado com `enable_dr = true` - dá para preencher com antecedência: `terraform output dr_standby_vpc_id` / `terraform output dr_standby_vpc_cidr`.
- **`rds_dr_connection_url`**: idem, já dá para copiar o valor (`terraform output -raw dr_replica_connection_url`) - mas o replica continua **somente leitura** até a promoção (`var.promote_dr_db = true` em `terra/`), que é a única ação deste fluxo realmente restrita ao momento exato da ativação, não algo para preparar com antecedência.

> **Vide [`doc/roteiro-dr-ativacao.md`][ativadr] para o passo a passo completo quando o DR precisar ser ativado**, incluindo o congelamento de escritas, a promoção do replica e o VPC peering entre as duas VPCs.

### DNS do failover (`manage_dns = true`)

`dns_zone_name`/`dns_record_name` (passo 1) pressupõem um **domínio próprio já registrado** (em qualquer registrador, não precisa ser a Route53) - `dns_zone_name` é um subdomínio desse domínio (_ex.: `solidarytech.meu.dominio`_), não o domínio raiz inteiro. O `terraform apply` do passo 2 cria a hosted zone Route53 desse subdomínio, mas ela só resolve de fato depois que o domínio raiz **delegar** a resolução para ela. Depois do `apply`, consulte os nameservers gerados:

```bash
terraform output route53_name_servers
```

Cadastre esses 4 nameservers como registros **NS** do subdomínio (`dns_zone_name`) no provedor DNS do domínio raiz (o mesmo lugar onde o domínio foi registrado ou onde seu DNS é gerenciado hoje). Sem esse cadastro, `dns_record_name` não resolve, mesmo com a hosted zone e os registros `PRIMARY`/`SECONDARY` já criados no Route53.

<BR>

## 5. Grafana externo

Loki, Tempo e Prometheus são implementados com o `terraform apply` do passo 2, e (se as variáveis de Grafana Cloud do passo 1 estiverem preenchidas) já empurram logs/traces/métricas para os datasources nativos e hospedados do próprio Grafana Cloud (`remote_write`/`loki.write`/`otelcol.exporter.otlp` - ver "Remote_write..."/"Logs e traces..." em `terra/README.md`). Não há NLB pública nem passo de cadastro de datasource: nada a configurar manualmente aqui.

As 9 variáveis (`grafana_cloud_remote_write_url`/`_username`/`_api_key` para métricas, `grafana_cloud_loki_url`/`_username`/`_api_key` para logs, `grafana_cloud_tempo_endpoint`/`_username`/`_api_key` para traces) são obtidas direto na conta do Grafana Cloud, sem precisar de nenhum contato ou solicitação:

1. Acesse [grafana.com][grafanacloud] e entre na sua conta (ou crie uma, o tier gratuito já é suficiente).
2. No portal, abra o stack desejado e, em **"Connections" > "Add new connection"** (ou na página de detalhes do stack), localize os cartões **Prometheus**, **Loki** e **Tempo** (cada um pertence a um Instance ID/stack próprio, mesmo dentro da mesma conta).
3. Cada cartão traz a **URL de push** (`remote_write`/`loki.write`/OTLP endpoint) e o **Instance ID** (usado como username/basic-auth) prontos para copiar.
4. Gere uma **API key** (ou "Cloud Access Policy Token") com permissão de escrita (`MetricsPublisher`/`LogsPublisher`/`TracesPublisher`, conforme o cartão) em **"Access Policies"**.

Preencha esses valores em `terra/terraform.tfvars` (passo 1) e rode `terraform apply` novamente. **Preencher qualquer um dos 3 grupos de variáveis já ativa o envio remoto correspondente** (métricas, logs ou traces, de forma independente) - deixar um grupo vazio mantém aquele envio desativado, sem afetar os demais.

<BR>

## Destruição do ambiente

> **É necessário estar conectado ao cluster AWS.**

> Se o ambiente passivo (`terra-dr/`) chegou a ser ativado, destrua-o **antes** do ambiente principal.

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