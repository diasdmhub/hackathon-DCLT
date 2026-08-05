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

Os `initContainers` `wait-for-psql`/`wait-for-elasticmq`/`wait-for-dynamodb` de `kube/` também não existem aqui: não há um Service local para esperar, e o RDS/SQS/DynamoDB já estão no ar antes do deploy (provisionados pelo Terraform).

## Secrets

Os Secrets `ngo-env`, `donation-env` e `volunteer-env` **não são aplicados pelo Flux** (não estão listados em `kustomization.yaml`, de propósito): `ngo-env` e `donation-env` contêm a string de conexão real do RDS (com senha), diferente do `AWS_ACCESS_KEY_ID=test` fake versionado em `kube/`.

1. Copie o `*-secret.example.yaml` de cada serviço (`040-ngo/`, `050-donation/`, `060-volunteer/`) para `*-secret.yaml` (já coberto pelo `.gitignore` da raiz do repositório).
2. Preencha `DATABASE_URL` com a URL de conexão real do RDS - instruções de onde encontrar o valor estão nos comentários do próprio arquivo (`terraform output rds_outputs` em `terra/`, ou `aws ssm get-parameter` no parâmetro que `terra/modules/secrets` já populou).
3. Aplique manualmente, uma vez, depois que o namespace `solidarytech` existir:
   ```bash
   kubectl apply -f kube-aws/040-ngo/041-secret.yaml
   kubectl apply -f kube-aws/050-donation/051-secret.yaml
   kubectl apply -f kube-aws/060-volunteer/061-secret.yaml
   ```

`AWS_SQS_URL` (em `donation-env`) e `AWS_DYNAMODB_TABLE` (em `volunteer-env`) já vêm preenchidos nos próprios `*-secret.example.yaml`, pois não são valores sensíveis.

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
(instalado via `lb-controller/`, fora deste diretório) quem reconcilia esse
CRD, registrando/removendo os IPs de pod no target group conforme os
Deployments escalam.

`clusters/eks-aws/solidarytech-kustomization.yaml` declara `dependsOn:
lb-controller` para garantir que o controller (e o CRD `TargetGroupBinding`
que o chart instala) já exista antes desses manifests serem aplicados - ver
`lb-controller/README.md`.

## IRSA

`005-serviceaccounts.yaml` cria as ServiceAccounts `donation-service` e `volunteer-service`, anotadas com os ARNs das roles IRSA que `terra/modules/iam` provisiona (escopo mínimo: `sqs:SendMessage`/`GetQueueAttributes` para a primeira, `dynamodb:PutItem`/`GetItem`/`Scan`/`Query` para a segunda). O nome do namespace e das ServiceAccounts aqui precisa continuar batendo com `k8s_namespace`/`donation_service_account`/`volunteer_service_account` em `terra/terraform.tfvars` - a trust policy de cada role é restrita a essa combinação exata via OIDC.

## Flux

`clusters/eks-aws/solidarytech-kustomization.yaml` já aponta para `./kube-aws`. Falta rodar o bootstrap do Flux nesse cluster (`flux bootstrap ...` com `--path=./clusters/eks-aws`) para que `flux-system/` seja gerado e essa Kustomization passe a ser reconciliada de fato - ver `clusters/eks-aws/`.
