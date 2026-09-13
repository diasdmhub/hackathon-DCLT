# Manifestos K8s na AWS

Este diretório é equivalente a `kube/`, contendo os 3 microsserviços da SolidaryTech, mas para o ambiente EKS, e usando os recursos provisionados pelo Terraform na AWS (`terra/`), ao invés de emuladores locais.

<BR>

## O que muda em relação a `kube/`

| | `kube/` (kubeadm-local) | `kube-aws/` (EKS) |
|---|---|---|
| Banco de dados | Postgres no próprio cluster (`010-db/`) | RDS PostgreSQL real (`terra/modules/rds`) |
| Fila | ElasticMQ no próprio cluster (`020-elasticmq/`) | SQS real (`terra/modules/sqs`) |
| Tabela de voluntários | DynamoDB Local no próprio cluster (`030-dynamodb/`) | DynamoDB real (`terra/modules/dynamo`) |
| Autenticação AWS (donation/volunteer) | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` fixos (`test`/`test`), aceitos pelos emuladores | IRSA via ServiceAccount anotada (`005-serviceaccounts.yaml`), sem credenciais estáticas |
| Exposição externa | 3x `Service` `LoadBalancer` compartilhando um IP fixo do MetalLB (`allow-shared-ip`), diferenciados por porta | `Service` `ClusterIP` + `TargetGroupBinding` por serviço, apontando para uma NLB única (`terra/modules/nlb`) |
| Tag de imagem | Timestamp UTC, atualizada pelo Flux Image Automation | `:latest` - este cluster não executa a Kustomization `image-automation` (só `kubeadm-local`, para evitar dois Flux commitando a mesma alteração em `./kube`) |
| Schema do banco | `docker-entrypoint-initdb.d` do `Dockerfile-psql` executa `db/init.sql` automaticamente na subida do container | Job `rds-init` (`020-rds-init/`) executa os mesmos `db/init.sql` contra o RDS - ver seção abaixo |
| Backend do HPA (`0NN-hpa.yaml`, min 1/max 4 em cada serviço) | `metrics-server` via `HelmRelease` Flux (`observe/050-metrics-server/`), com `--kubelet-insecure-tls` (certificado autoassinado do kubelet no kubeadm) | Addon EKS `metrics-server` (`terra/modules/eks`), gerenciado pela AWS - sem flag de TLS inseguro, o certificado do kubelet já é confiável |

<BR>

## Inicialização do schema (RDS)

O RDS provisionado por `terra/modules/rds` sobe como uma instância Postgres em branco. Diferente do Compose, nada executa o `db/init.sql` do `ngo-service`/`donation-service` automaticamente nele. Sem isso, os Deployments sobem saudáveis (o `/health` não toca no banco), mas todo `INSERT`/`SELECT` falha com "relation does not exist".

`020-rds-init/` cobre isso com um Job de execução única (`rds-init`) que executa `psql` com o schema das duas tabelas (via ConfigMap `rds-init-sql`, `021-configmap.yaml`) contra o `DATABASE_URL` do Secret `ngo-env` (RDS executa um único database compartilhado, `sol_db`, então o mesmo `DATABASE_URL` serve para os dois scripts). Os scripts são idempotentes (`CREATE TABLE IF NOT EXISTS`, `INSERT ... ON CONFLICT DO NOTHING`), então executar de novo não tem efeito colateral.

Pontos de atenção:

- O ConfigMap é uma **cópia** de `build/ngo-service/db/init.sql` e `build/donation-service/db/init.sql`, não gerada a partir deles. Se esses arquivos mudarem, atualize o `021-configmap.yaml` também.
- Como o Job depende do Secret `ngo-env` (criado pelo Terraform - _ver "Secrets" abaixo_), e o `terraform apply` sempre executa antes do `flux bootstrap` (ver `doc/roteiro-cluster-aws.md`), o Secret já existe quando a Kustomization `solidarytech` cria o Job pela primeira vez. Se o Job ainda assim esgotar o `backoffLimit` (6 tentativas, por exemplo após um `terraform destroy`/`apply` que recriou o RDS com outro endpoint), rode `kubectl delete job rds-init -n solidarytech` e force a reconciliação (`flux reconcile kustomization solidarytech`).
- `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` faz o Flux não tentar recriar o Job já concluído a cada reconciliação (Jobs são imutáveis).

<BR>

## Secrets

O Namespace `solidarytech` e os Secrets `ngo-env`, `donation-env` e `volunteer-env` **não são aplicados pelo Flux** (não estão listados em `kustomization.yaml`, de propósito). `ngo-env` e `donation-env` contêm a string de conexão real do RDS (com senha), diferente do `AWS_ACCESS_KEY_ID=test` fake versionado em `kube/`.

Em vez de um passo manual (`kubectl apply` fora do Flux), o Namespace e os 3 Secrets são criados direto pelo `terraform apply` (`kubernetes_namespace_v1.solidarytech` e `module.secrets` em `terra/main.tf`/`terra/modules/secrets`), usando os mesmos valores de `rds_connection_url`/`sqs_queue_url`/`dynamodb_table_name` que já alimentam os parâmetros SSM (_ver "Observabilidade via Terraform" em `terra/README.md`_). A definição de cada Secret vive em `terra/modules/secrets/secrets.tf`.

`AWS_SQS_URL` (em `donation-env`) e `AWS_DYNAMODB_TABLE` (em `volunteer-env`) não são sensíveis, mas ficam nos mesmos Secrets por conveniência (um único `envFrom` por Deployment).

<BR>

## Exposição externa: NLB única + TargetGroupBinding

Equivalente ao IP fixo compartilhado via MetalLB (`allow-shared-ip`) usado no cluster local, os 3 microsserviços são alcançados por um único endpoint (a mesma NLB, uma porta por serviço: 8081/8082/8083), em vez de 3 Classic ELBs distintas (o que um `Service` `type: LoadBalancer` criaria neste cluster, um por serviço).

A NLB, os 3 listeners e os 3 target groups são provisionados pelo Terraform (`terra/modules/nlb`), fora do ciclo de vida do `Service` - por isso os 3 `Service` aqui são `type: ClusterIP`. Cada serviço tem também um `TargetGroupBinding` (`elbv2.k8s.aws/v1beta1`, ex.: `040-ngo/042-ngo.yaml`) que referencia o target group pelo nome determinístico gerado pelo Terraform (`targetGroupName: solidarytech-<serviço>-tg`) e o `Service` correspondente. É o [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) (instalado via `terra/modules/lb`, fora deste diretório) quem reconcilia esse CRD, registrando/removendo os IPs de pod no target group conforme os Deployments escalam.

Diferente da IAM/IRSA (`terra/modules/lb-iam`), o controller (ServiceAccount + `helm_release`) é aplicado direto pelo Terraform, não pelo Flux - _ver "Observabilidade e monitoração de infraestrutura via Terraform" em `terra/README.md`_. `clusters/eks-aws/solidarytech-kustomization.yaml` não precisa de `dependsOn` por causa disso; contanto que `terraform apply` execute antes do `flux bootstrap` (ver `doc/roteiro-cluster-aws.md`), o controller e o CRD `TargetGroupBinding` já existem quando o Flux aplica estes manifests.

<BR>

## IRSA

`005-serviceaccounts.yaml` cria as ServiceAccounts `donation-service` e `volunteer-service`, anotadas com os ARNs das roles IRSA que `terra/modules/iam` provisiona (escopo mínimo: `sqs:SendMessage`/`GetQueueAttributes` para a primeira, `dynamodb:PutItem`/`GetItem`/`Scan`/`Query` para a segunda). O nome do namespace e das ServiceAccounts aqui precisa continuar batendo com `k8s_namespace`/`donation_service_account`/`volunteer_service_account` em `terra/terraform.tfvars` - _a trust policy de cada role é restrita a essa combinação exata via OIDC_.

O ARN de cada role não fica hardcoded em `005-serviceaccounts.yaml`, já que o account ID da AWS não deve ficar versionado num repositório público que pode ser copiado por terceiros. O arquivo usa `${DONATION_SERVICE_ROLE_ARN}`/`${VOLUNTEER_SERVICE_ROLE_ARN}`, substituídas em tempo de reconciliação pelo `postBuild.substituteFrom` da Kustomization `solidarytech` (`clusters/eks-aws/solidarytech-kustomization.yaml`), que lê o Secret `irsa-role-arns` no namespace `flux-system` - criado diretamente pelo Terraform (`terra/modules/flux`, com os ARNs vindos de `module.iam`), sem nenhum passo manual, o mesmo módulo que também aplica `gotk-sync.yaml`/`solidarytech-kustomization.yaml` neste cluster. _Ver "FluxCD via Terraform" em `terra/README.md`_.

<BR>

## Flux

`clusters/eks-aws/solidarytech-kustomization.yaml` aponta para `./kube-aws`. Falta executar o bootstrap do Flux nesse cluster (`flux bootstrap ...` com `--path=./clusters/eks-aws`) para que `flux-system/` seja gerado e essa Kustomization passe a ser reconciliada de fato - ver `clusters/eks-aws/`.

<BR>

## Disaster Recovery

Este diretório é **compartilhado** entre o cluster ativo (`clusters/eks-aws/`) e o cluster passivo da estratégia de DR (`clusters/eks-aws-dr/`, provisionado por `terra-dr/`). **Nenhum manifest aqui muda entre os dois**. Isso funciona porque as duas únicas coisas que diferem por ambiente já são resolvidas fora deste diretório: os ARNs de IRSA (`005-serviceaccounts.yaml`) vêm de um Secret `irsa-role-arns` próprio de cada cluster (via `postBuild.substituteFrom`), e os `targetGroupName` dos `TargetGroupBinding` usam um nome determinístico que não depende de região (`${name_prefix}-<service>-tg`, com o mesmo `name_prefix` nos dois roots Terraform). _Ver "Disaster Recovery" em `terra/README.md` e `terra-dr/README.md` para a estratégia completa_.