# kube-aws/

Equivalente a `kube/` (os 3 microsserviços da SolidaryTech) para o ambiente
EKS, mas usando os recursos reais provisionados pelo Terraform (`terra/`) em
vez dos emuladores locais.

`kube/` continua existindo e válido como está, para o cluster
`kubeadm-local`. Nada neste diretório o altera.

## O que muda em relação a `kube/`

| | `kube/` (kubeadm-local) | `kube-aws/` (EKS) |
|---|---|---|
| Banco de dados | Postgres no próprio cluster (`010-db/`) | RDS PostgreSQL real (`terra/modules/rds`) |
| Fila | ElasticMQ no próprio cluster (`020-elasticmq/`) | SQS real (`terra/modules/sqs`) |
| Tabela de voluntários | DynamoDB Local no próprio cluster (`030-dynamodb/`) | DynamoDB real (`terra/modules/dynamo`) |
| Autenticação AWS (donation/volunteer) | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` fixos (`test`/`test`), aceitos pelos emuladores | IRSA via ServiceAccount anotada (`005-serviceaccounts.yaml`), sem credenciais estáticas |
| Exposição externa | 3x `Service` `LoadBalancer` compartilhando um IP fixo do MetalLB (`allow-shared-ip`), diferenciados por porta | `Service` `ClusterIP` + `TargetGroupBinding` por serviço, apontando para uma NLB única (`terra/modules/nlb`) |
| Tag de imagem | Timestamp UTC, atualizada pelo Flux Image Automation | `:latest` - este cluster não roda a Kustomization `image-automation` (só `kubeadm-local`, para evitar dois Flux commitando a mesma alteração em `./kube`) |
| Schema do banco | `docker-entrypoint-initdb.d` do `Dockerfile-psql` roda `db/init.sql` automaticamente na subida do container | Job `rds-init` (`020-rds-init/`) roda os mesmos `db/init.sql` contra o RDS - ver seção abaixo |
| Backend do HPA (`0NN-hpa.yaml`, min 1/max 4 em cada serviço) | `metrics-server` via `HelmRelease` Flux (`observe/050-metrics-server/`), com `--kubelet-insecure-tls` (certificado autoassinado do kubelet no kubeadm) | Addon EKS `metrics-server` (`terra/modules/eks`), gerenciado pela AWS - sem flag de TLS inseguro, o certificado do kubelet já é confiável |

## Inicialização do schema (RDS)

O RDS provisionado por `terra/modules/rds` sobe como uma instância Postgres em branco - diferente do Compose, nada roda o `db/init.sql` do `ngo-service`/`donation-service` automaticamente nele. Sem isso, os Deployments sobem saudáveis (o `/health` não toca no banco), mas todo `INSERT`/`SELECT` falha com "relation does not exist".

`020-rds-init/` cobre isso com um Job one-shot (`rds-init`) que roda `psql` com o schema das duas tabelas (via ConfigMap `rds-init-sql`, `021-configmap.yaml`) contra o `DATABASE_URL` do Secret `ngo-env` (RDS roda um único database compartilhado, `sol_db`, então o mesmo `DATABASE_URL` serve para os dois scripts). Os scripts são idempotentes (`CREATE TABLE IF NOT EXISTS`, `INSERT ... ON CONFLICT DO NOTHING`), então rodar de novo não tem efeito colateral.

Pontos de atenção:
- O ConfigMap é uma **cópia** de `build/ngo-service/db/init.sql` e `build/donation-service/db/init.sql`, não gerada a partir deles (o kustomize recusa arquivos fora da raiz do kustomization, mesmo dentro do mesmo repo). Se esses arquivos mudarem, atualize `021-configmap.yaml` junto.
- Como o Job depende do Secret `ngo-env` (criado pelo Terraform - ver "Secrets" abaixo), e o `terraform apply` sempre roda antes do `flux bootstrap` (ver `doc/roteiro-cluster-aws.md`), o Secret já existe quando a Kustomization `solidarytech` cria o Job pela primeira vez - sem passo manual nem corrida entre os dois. Se o Job ainda assim esgotar o `backoffLimit` (6 tentativas, por exemplo após um `terraform destroy`/`apply` que recriou o RDS com outro endpoint), rode `kubectl delete job rds-init -n solidarytech` e force a reconciliação (`flux reconcile kustomization solidarytech`).
- `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` faz o Flux não tentar recriar o Job já concluído a cada reconciliação (Jobs são imutáveis).

Os `initContainers` `wait-for-psql`/`wait-for-elasticmq`/`wait-for-dynamodb` de `kube/` também não existem aqui: não há um Service local para esperar, e o RDS/SQS/DynamoDB já estão no ar antes do deploy (provisionados pelo Terraform).

## Secrets

O Namespace `solidarytech` e os Secrets `ngo-env`, `donation-env` e
`volunteer-env` **não são aplicados pelo Flux** (não estão listados em
`kustomization.yaml`, de propósito): `ngo-env` e `donation-env` contêm a
string de conexão real do RDS (com senha), diferente do
`AWS_ACCESS_KEY_ID=test` fake versionado em `kube/`.

Em vez de um passo manual (`kubectl apply` fora do Flux), o Namespace e os 3
Secrets são criados direto pelo `terraform apply` (`kubernetes_namespace_v1.solidarytech`
e `module.secrets` em `terra/main.tf`/`terra/modules/secrets`), usando os
mesmos valores de `rds_connection_url`/`sqs_queue_url`/`dynamodb_table_name`
que já alimentam os parâmetros SSM - mesmo raciocínio de mover para o
Terraform o que carrega segredo real ou dependeria de reconciliação do Flux
(ver "Observabilidade via Terraform" em `terra/README.md`). Não há arquivo
`*-secret.yaml`/`*-secret.example.yaml` neste diretório: a definição de cada
Secret vive em `terra/modules/secrets/secrets.tf`.

`AWS_SQS_URL` (em `donation-env`) e `AWS_DYNAMODB_TABLE` (em `volunteer-env`)
não são sensíveis, mas ficam nos mesmos Secrets por conveniência (um único
`envFrom` por Deployment).

## Exposição externa: NLB única + TargetGroupBinding

Equivalente ao IP fixo compartilhado via MetalLB (`allow-shared-ip`) usado
em `kubeadm-local`: os 3 microsserviços são alcançados por um único
endpoint (a mesma NLB, uma porta por serviço: 8081/8082/8083), em vez de 3
Classic ELBs distintas (o que um `Service` `type: LoadBalancer` criaria
neste cluster, um por serviço).

A NLB, os 3 listeners e os 3 target groups são provisionados pelo Terraform
(`terra/modules/nlb`), fora do ciclo de vida do `Service` - por isso os 3
`Service` aqui são `type: ClusterIP`. Cada serviço tem também um
`TargetGroupBinding` (`elbv2.k8s.aws/v1beta1`, ex.: `040-ngo/042-ngo.yaml`)
que referencia o target group pelo nome determinístico gerado pelo Terraform
(`targetGroupName: solidarytech-<serviço>-tg`) e o `Service` correspondente;
é o [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
(instalado via `terra/modules/lb`, fora deste diretório) quem reconcilia esse
CRD, registrando/removendo os IPs de pod no target group conforme os
Deployments escalam.

Diferente da IAM/IRSA (`terra/modules/lb-iam`), o controller
em si (ServiceAccount + `helm_release`) é aplicado direto pelo Terraform, não
pelo Flux - ver "Observabilidade e monitoração de infraestrutura via
Terraform" em `terra/README.md`. `clusters/eks-aws/solidarytech-kustomization.yaml`
não precisa de `dependsOn` por causa disso: contanto que `terraform apply`
rode antes do `flux bootstrap` (ver `doc/roteiro-cluster-aws.md`), o
controller e o CRD `TargetGroupBinding` já existem quando o Flux aplica
estes manifests.

## IRSA

`005-serviceaccounts.yaml` cria as ServiceAccounts `donation-service` e `volunteer-service`, anotadas com os ARNs das roles IRSA que `terra/modules/iam` provisiona (escopo mínimo: `sqs:SendMessage`/`GetQueueAttributes` para a primeira, `dynamodb:PutItem`/`GetItem`/`Scan`/`Query` para a segunda). O nome do namespace e das ServiceAccounts aqui precisa continuar batendo com `k8s_namespace`/`donation_service_account`/`volunteer_service_account` em `terra/terraform.tfvars` - a trust policy de cada role é restrita a essa combinação exata via OIDC.

O ARN de cada role não fica hardcoded em `005-serviceaccounts.yaml` - o
account ID da AWS não deve ficar versionado num repositório público que
pode ser copiado por terceiros. O arquivo usa `${DONATION_SERVICE_ROLE_ARN}`/
`${VOLUNTEER_SERVICE_ROLE_ARN}`, substituídas em tempo de reconciliação pelo
`postBuild.substituteFrom` da Kustomization `solidarytech`
(`clusters/eks-aws/solidarytech-kustomization.yaml`), que lê o Secret
`irsa-role-arns` no namespace `flux-system` - aplicado manualmente uma única
vez, com os ARNs reais (`terraform output -json iam_outputs`), o mesmo
padrão já usado para `gotk-sync.yaml`/`solidarytech-kustomization.yaml`
neste cluster. Ver `clusters/eks-aws/flux-system/irsa-role-arns-secret.example.yaml`
e `doc/roteiro-cluster-aws.md`.

## Flux

`clusters/eks-aws/solidarytech-kustomization.yaml` já aponta para `./kube-aws`. Falta rodar o bootstrap do Flux nesse cluster (`flux bootstrap ...` com `--path=./clusters/eks-aws`) para que `flux-system/` seja gerado e essa Kustomization passe a ser reconciliada de fato - ver `clusters/eks-aws/`.
