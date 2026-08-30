# terra-dr/

Ambiente **passivo** da estratégia de Disaster Recovery (DR) ativo-passivo do
SolidaryTech - ver "Disaster Recovery" em `terra/README.md` para a
estratégia completa. Este diretório é um root Terraform independente de
`terra/`, mas reaplica os mesmos módulos compartilhados (`../terra/modules/*`)
numa região AWS diferente, garantindo a mesma configuração do ambiente ativo
sem duplicar código.

## O que fica sempre ligado, e o que não fica

| Camada | Estado normal (sem desastre) | Onde vive |
|---|---|---|
| Backups automatizados do RDS replicados cross-region | Sempre ativo (custo baixo: só storage S3) | `aws_db_instance_automated_backups_replication` em `terra/main.tf`, controlado por `enable_dr` |
| Réplica da tabela DynamoDB (Global Tables) | Sempre ativa (custo baixo) | `module.dynamo` em `terra/main.tf`, `replica_regions` controlado por `enable_dr` |
| Hosted zone Route53 + registro PRIMARY | Sempre ativo, se `manage_dns = true` | `terra/main.tf` |
| VPC/EKS/RDS/SQS/NLB/observabilidade do ambiente passivo | **Desligado** - este state normalmente fica vazio | `terra-dr/` (este diretório) |

Ou seja: os dados são protegidos continuamente, mas nenhum compute do
ambiente passivo roda (nem é cobrado) enquanto não há um desastre. "Ativar"
o ambiente passivo é simplesmente rodar `terraform apply` aqui pela primeira
vez (ou de novo, depois de um `terraform destroy` usado para encerrar um
simulado).

## Pré-requisitos

- Que `terra/` já tenha sido aplicado com `enable_dr = true` (e, se quiser
  failover automático de DNS, `manage_dns = true`) - ver
  `terra/terraform.tfvars.example`. Sem isso, não há backup replicado nem
  réplica do DynamoDB para restaurar/usar aqui.
- `rds_backup_retention_period` do ambiente ativo precisa estar rodando há
  tempo suficiente para existir pelo menos um backup replicado (a
  replicação começa a partir do próximo backup automatizado depois que
  `aws_db_instance_automated_backups_replication` é criado, não retroage a
  backups antigos).
- Mesmos pré-requisitos de `terra/README.md` (Terraform >= 1.6, AWS CLI v2
  configurado) - já contra a conta AWS, sem precisar reconfigurar nada
  específico para a segunda região.

## Ativação (runbook)

**1. Copie e edite as variáveis:**

```bash
cd terra-dr
cp terraform.tfvars.example terraform.tfvars
# edite: db_password (IGUAL à senha real do ambiente ativo),
# observe_allowed_cidrs, route53_zone_id/dns_record_name (se usar failover
# automático de DNS - copie route53_zone_id do output route53_zone_id de
# terra/).
```

**2. Descubra o ARN do backup replicado mais recente**, na região do
ambiente passivo (`var.aws_region` aqui = `var.dr_aws_region` em `terra/`):

```bash
aws rds describe-db-instance-automated-backups \
  --region us-west-2 \
  --db-instance-identifier solidarytech-rds-psql \
  --query 'DBInstanceAutomatedBackups[0].DBInstanceAutomatedBackupsArn' \
  --output text
```

Cole o valor retornado em `rds_restore_source_arn` no `terraform.tfvars`
(ou passe via `-var`).

> Este passo não tem, hoje, um data source Terraform equivalente estável -
> por isso é uma consulta AWS CLI manual antes do `apply`, não algo que o
> Terraform resolva sozinho. Com o FluxCD também instalado pelo Terraform
> (ver passo 5 abaixo), esta é a única etapa não totalmente automatizada de
> toda a ativação.

**3. Suba a infraestrutura:**

```bash
./init.sh   # reaproveita o bucket S3/tabela DynamoDB de lock já criados por terra/init.sh

# Mesma limitação de Terraform+EKS de terra/ (cluster precisa existir antes
# dos providers kubernetes/helm/kubectl poderem se conectar) - ver "Uso" em
# terra/README.md.
terraform apply -target=module.eks
terraform apply
```

**4. Aponte o `kubectl` local para o cluster recém-criado:**

```bash
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-west-2 --name solidarytech-eks-cluster
```

**5. Verifique o FluxCD e os microsserviços.** O `terraform apply` do passo
3 já instalou o FluxCD neste cluster (`../terra/modules/flux`, mesmo módulo
de `terra/` - ver "FluxCD via Terraform" em `terra/README.md`) e aplicou o
`GitRepository`, a `Kustomization` `solidarytech` e o Secret
`irsa-role-arns` (com os ARNs reais **deste** state, `role_name_suffix =
"-dr"`, vindos direto de `module.iam` - sem copiar/colar manual). Nenhum
`flux install`/`kubectl apply -f` é necessário aqui; este passo só confirma
que os 3 microsserviços (mesmos manifests de `kube-aws/`, sem nenhum
ajuste) subiram saudáveis:

```bash
flux get kustomizations       # requer o Flux CLI - opcional
kubectl get pods -n solidarytech
```

**6. Confirme o failover de DNS.** Se `manage_dns = true` em `terra/` e
`route53_zone_id`/`dns_record_name` definidos aqui, o health check
`aws_route53_health_check.secondary` já está registrado - assim que o
`aws_route53_health_check.primary` do ambiente ativo (`terra/`) começar a
falhar, o Route53 já resolve `dns_record_name` para a NLB deste cluster
automaticamente (dentro do TTL de 30s configurado). Sem `manage_dns`, repita
manualmente o mesmo repoint que já é feito hoje para `observe_allowed_cidrs`
(atualizar o DNS/DDNS externo para o `nlb_dns_name` deste state).

## O que **não** é levado para o ambiente passivo

- **Fila SQS**: `module.sqs` aqui cria uma fila nova e vazia - eventos de
  doação em trânsito na fila do ambiente ativo no momento do desastre não
  são reprocessados. Aceitável dado que a doação já foi persistida no RDS
  (a fila só carrega o evento assíncrono pós-gravação) - ver
  `build/donation-service/main.go`.
- **Estado dos Pods/HPA**: sobe do zero (`minReplicas: 1` de cada HPA),
  igual a qualquer `terraform apply` novo do ambiente ativo.

## Failback (voltar para o ambiente ativo)

Depois que a região original estiver saudável de novo:

1. Não existe um mecanismo automático de "sincronizar de volta" os dados
   escritos no ambiente passivo durante a janela de failover - trate como
   uma segunda migração manual (dump/restore do RDS do ambiente passivo
   para o ativo, ou promova o RDS do passivo a fonte de verdade e refaça a
   replicação no sentido contrário) antes de repontar o DNS de volta.
2. Reponte `dns_record_name` para o ambiente ativo (automaticamente, quando
   `aws_route53_health_check.primary` voltar a passar) ou manualmente.
3. Depois da confirmação de que o tráfego voltou para `terra/`, encerre o
   ambiente passivo para não continuar sendo cobrado:

```bash
cd terra-dr
terraform destroy
```

Isso destrói VPC/EKS/RDS/NLB/observabilidade deste state - a réplica
DynamoDB e a replicação de backups do RDS continuam vivas em `terra/`
(controladas por `enable_dr`), prontas para uma próxima ativação.

## Custos

Além do que já é cobrado independente de região (nada aqui, enquanto o state
está vazio): ativar o ambiente passivo custa exatamente o mesmo que o
ambiente ativo já custa hoje (EKS control plane, NAT Gateway, NLB, node
group - ver "Custos que não têm free tier" em `terra/README.md`), pelo tempo
em que ficar de pé. A parte "sempre ligada" (réplica DynamoDB + replicação
de backups do RDS) é pequena o bastante para não pesar no orçamento deste
ambiente.
