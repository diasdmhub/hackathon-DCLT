| [↩️ Voltar](./) |
| --- |

# Roteiro de implementação inicial do cluster K8s na AWS

> ⚠️ **_Em construção_**

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

**6.** O [FluxCD CLI][fluxcli] é opcional - o Terraform instala e configura o FluxCD (controladores, `GitRepository`, `Kustomization` e o Secret `irsa-role-arns`, ver passo 3 abaixo), mas o CLI continua útil para consultar o estado da reconciliação (`flux get kustomizations`) ou depurar, caso necessário. **Não** é preciso um Personal Access Token do GitHub: o `GitRepository` deste cluster só lê do repositório público (leitura anônima), nunca escreve nele - ver o comentário em `clusters/eks-aws/flux-system/gotk-sync.yaml` para o porquê.

**7.** Um [Grafana][grafanacloud] já em operação.

<BR>

## 1. Variáveis Terraform

Para a implementação inicial, é necessário configurar alguns dados para permitir que o ambiente seja criado de forma consistente.

O arquivo de [variáveis do Terraform][tfvars] (`terraform.tfvars`) deve ser definido com as principais variáveis do ambiente, incluindo a senhas. Embora seja disponibilizado um arquivo de exemplo (`terraform.tfvars.example`) com alguns valores pré-definidos, é **altamente recomendado que as variáveis a seguir sejam definidas de acordo com o ambiente final**.

> ⚠️ **Note que este arquivo contém dados sensíveis e deve ter seu acesso restrito. Portanto, ele é ignorado pelo Git.**

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

<BR>

## 2. Provisionamento de infraestrutura

Neste passo serão provisionados a infraestrutura AWS, o Load Balancer Controller, o FluxCD (controladores + bootstrap dos microsserviços) e os serviços de observabilidade e monitoramento, tudo com o Terraform.

> **Os comandos abaixo devem ser executados a partir de um host de controle da infraestrutura.**

Crie e edite o arquivo `terraform.tfvars`. **Evite usar os valores de exemplo.**

> No mínimo `db_password` e `observe_allowed_cidrs` devem ser definidos.

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
```

Execute o script de inicialização para criar o bucket S3, a tabela de estado do Terraform no DynamoDB e inicializar o Terraform.

```bash
./init.sh
```

Na primeira inicialização, com um cluster totalmente novo, os providers
`kubernetes/helm/kubectl` tentam usar outputs do cluster EKS, que não
 existem num _state_ vazio. Portantanto, o cluster EKS deve ser criado primeiro. _Vide "Uso" em terra/README.md (limitação de Terraform+EKS)_.

```bash
terraform plan -target=module.eks
terraform apply -target=module.eks
```

Um segundo `apply` (já com o cluster criado) gera os demais recursos AWS: instala o "Load Balancer Controller", instala o FluxCD e aplica o `GitRepository`/`Kustomization` que fazem os 3 microsserviços (`./kube-aws`) subirem, e aplica o `Loki/Tempo/Alloy/Prometheus` direto no cluster, através dos providers `helm/kubernetes/kubectl`. Nenhum desses passa por um `flux bootstrap` autogerenciado (_vide `terra/README.md`_) - o próprio Terraform instala e configura o Flux. A ordem entre eles passa por dependências do Terraform. Não precisa de mais um `apply` além do `-target=module.eks` inicial. Em clusters já existentes (com o `module.eks` criado), siga direto para o `terraform plan`/`apply`.

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

## 3. Verificar o FluxCD no cluster (microsserviços)

O `terraform apply` do passo 2 já instalou os controladores do FluxCD (via `terra/modules/flux`, chart Helm `fluxcd-community/flux2`) e aplicou o `GitRepository` (`clusters/eks-aws/flux-system/gotk-sync.yaml`), a `Kustomization` `solidarytech` (`clusters/eks-aws/solidarytech-kustomization.yaml`) e o Secret `irsa-role-arns` (com os ARNs reais das roles IRSA, vindos direto de `module.iam` - nenhum passo manual de copiar/colar ARN). Não há mais nada a instalar ou aplicar manualmente neste passo - ele só confirma que a reconciliação está funcionando.

> Ao contrário do cluster local (`clusters/kubeadm-local/`), aqui **não** se usa `flux bootstrap` (que faz o Flux se autogerenciar, commitando seus próprios manifests de volta no repositório). O repositório canônico deste projeto é o Gitea (`gitea.diasdm.com.br`), que mantém um *push mirror* unidirecional para o GitHub - a cada push no Gitea, a branch `main` do GitHub é forçada a ficar idêntica à do Gitea, apagando qualquer commit que exista só no lado do GitHub. Como o EKS não alcança o Gitea pela rede (só o GitHub), qualquer commit que o Flux fizesse aqui ficaria só no GitHub e seria apagado no próximo push feito no Gitea. Por isso, aqui o Flux só lê do GitHub, nunca escreve nele - isso não muda com a instalação via Terraform, só a forma como os controladores chegam no cluster mudou (ver "FluxCD via Terraform" em `terra/README.md`).

Se um dia o `url`/`branch` do `GitRepository`, o `path`/`interval` da `Kustomization`, ou os ARNs de IRSA mudarem (ex.: `terraform destroy`/`apply` recriando as roles), basta rodar `terraform apply` de novo - o Terraform reconcilia a diferença, sem `kubectl apply -f` manual.

```bash
flux get kustomizations  # Consulta (requer o Flux CLI - opcional, ver Pré-requisitos)
kubectl get kustomization solidarytech -n flux-system  # Alternativa sem o Flux CLI
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
[grafanacloud]: https://grafana.com/products/cloud/