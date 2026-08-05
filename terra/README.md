# terra/

Infraestrutura AWS do SolidaryTech, definida em Terraform. Recria na nuvem o
mesmo ambiente hoje provisionado manualmente em `kubeadm-local` (ver
`clusters/kubeadm-local/` e o `CLAUDE.md` na raiz do repositório).

As imagens dos 3 microsserviços continuam publicadas no Docker Hub
(`diasdmhub/{ngo,donation,volunteer}`) pelo pipeline de CI/CD já existente -
nenhum módulo de registry (ECR) foi criado aqui.

## Módulos

| Módulo | Recurso principal | Observação de custo |
|---|---|---|
| `vpc` | VPC, subnets públicas/privadas, 1 NAT Gateway | NAT Gateway não é free tier (cobra por hora + dados) |
| `eks` | Cluster EKS + node group gerenciado + OIDC + addons + EBS CSI | Control plane do EKS não é free tier (~US$0,10/h fixo) |
| `rds` | PostgreSQL `db.t3.micro`, single-AZ, 20GB gp3 | Free tier nos primeiros 12 meses de conta nova |
| `dynamo` | Tabela `SolidaryTechVolunteers`, PROVISIONED 5/5 | Dentro do always-free tier (25 RCU/25 WCU/25GB, sem prazo) |
| `sqs` | Fila standard de eventos de doação | Always-free até 1M requisições/mês, sem prazo |
| `iam` | Roles IRSA (donation-service → SQS, volunteer-service → DynamoDB) | Sem custo |
| `nlb` | Network Load Balancer única (3 listeners/target groups, um por serviço) | Sem free tier - cobra por hora + LCU |
| `lb-controller` | Role IRSA do AWS Load Balancer Controller (kube-system) | Sem custo |
| `secrets` | Parâmetros SSM Parameter Store (`SecureString`/`String`) | Camada Standard é gratuita |

### Custos que não têm free tier

O EKS control plane, o NAT Gateway e a NLB (`nlb`) são cobrados desde o
primeiro minuto, independentemente da idade da conta AWS - são os itens que
mais pesam neste ambiente; destrua o cluster (`terraform destroy`) fora de
uso para evitar cobrança contínua.

## Pré-requisitos

- Terraform >= 1.6
- AWS CLI v2 configurado (usado pelo provider `kubernetes` para obter token via `aws eks get-token`)
- Uma conta AWS com permissão para criar VPC, EKS, RDS, DynamoDB, SQS, IAM e SSM

## Bootstrap do backend remoto (uma única vez)

O backend S3 (`terraform.tf`) exige que o bucket e a tabela de lock já
existam antes do primeiro `terraform init` - não é possível criá-los com o
mesmo Terraform que os usa como backend. `init.sh` automatiza isso (é
idempotente - pode ser reexecutado sem erro se o bucket/tabela já existirem):

```bash
cd terra
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars, principalmente db_password

./init.sh
```

Nomes de bucket S3 são globalmente únicos entre todas as contas AWS - por
isso `init.sh` usa o prefixo `fiap-solidarytech-terraform-*`, não só
`solidarytech-terraform-*`. **Os nomes em `init.sh` e no bloco `backend "s3"`
de `terraform.tf` precisam ser exatamente os mesmos** (blocos de backend não
aceitam variáveis, então o valor em `terraform.tf` é literal); se ajustar um,
ajuste o outro. Um 403 do tipo `Unable to access object "terraform.tfstate"
in S3 bucket "..."` ao rodar `terraform init` é o sintoma desse descompasso -
a AWS responde 403 em vez de 404 tanto para bucket sem permissão quanto para
bucket que nem existe (ou pertence a outra conta), então a mensagem não
distingue as duas causas.

## Uso

```bash
terraform plan
terraform apply

# configurar o kubectl local contra o cluster criado
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-east-1 --name solidarytech-eks-cluster
```

`terraform.tfvars` nunca deve ser commitado (já coberto pelo `.gitignore` da
raiz do repositório, que ignora `*.tfvars`).

## Destruição do ambiente (`terraform destroy`)

Os 3 microsserviços expõem `Service` `type: ClusterIP` (`kube-aws/040-ngo/`,
`050-donation/`, `060-volunteer/`) e são alcançados de fora via uma NLB
única (`terra/modules/nlb`), com o AWS Load Balancer Controller registrando
os pods nos target groups através de `TargetGroupBinding` - ver
`kube-aws/README.md`. Diferente de um `Service` `type: LoadBalancer` (que
faria o EKS criar uma Classic ELB fora do state do Terraform, arriscando
ENIs órfãs bloqueando a exclusão da VPC), a NLB aqui é o recurso `aws_lb` de
`terra/modules/nlb`: está no state do Terraform, então `terraform destroy` já
apaga NLB, listeners, target groups e a regra de Security Group na ordem
certa, sem passo manual.

Ainda assim, use `terra/destroy.sh` em vez de `terraform destroy` direto -
hoje é só um wrapper fino (`terraform destroy -auto-approve`), mantido como
o ponto de entrada documentado caso a destruição volte a precisar de algum
passo extra:

```bash
cd terra
./destroy.sh
```

## Pendências para o cluster ficar totalmente funcional

Estes módulos provisionam a infraestrutura AWS, mas os ajustes abaixo em
`kube/` (fora do escopo deste diretório) ainda são necessários para o
ambiente funcionar de ponta a ponta na AWS:

1. **Remover as credenciais fake do DynamoDB/SQS local.** Hoje
   `kube/050-donation/051-secret.yaml` e `kube/060-volunteer/061-secret.yaml`
   injetam `AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test` como env
   vars. Tanto o SDK Go (`aws-sdk-go-v2/config.LoadDefaultConfig`) quanto o
   boto3 do volunteer-service resolvem credenciais checando essas env vars
   *antes* do IRSA - se continuarem definidas na AWS, o SDK vai tentar
   autenticar com "test"/"test" em vez de assumir a role IRSA, e vai falhar.
2. **Criar as `ServiceAccount`s `donation-service` e `volunteer-service`**
   no namespace `solidarytech`, anotadas com
   `eks.amazonaws.com/role-arn: <output iam_outputs.donation_service_role_arn / volunteer_service_role_arn>`,
   e referenciá-las via `serviceAccountName` nos respectivos Deployments
   (hoje usam a ServiceAccount `default`).
3. **Apontar `DATABASE_URL`, `AWS_SQS_URL` e `AWS_DYNAMODB_TABLE`** para os
   valores reais gerados aqui (`terraform output`, ou lendo os parâmetros
   SSM criados pelo módulo `secrets`), no lugar dos valores atuais que
   apontam para `psql`/`elasticmq`/DynamoDB Local do Compose.
4. Como `kube/` hoje serve um único ambiente (`kubeadm-local`), provavelmente
   fará sentido introduzir overlays do Kustomize (`base` + `overlays/aws`)
   quando esse ajuste for feito, em vez de sobrescrever os manifests atuais.

Nenhum desses 4 pontos foi alterado por este commit - `kube/` continua
válido para o cluster `kubeadm-local` como está hoje.
