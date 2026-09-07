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
| Read replica cross-region sempre-vivo do RDS, numa VPC mínima própria | Sempre ativo (custo baixo: uma instância `db.t3.micro`, sem NAT/EKS) | `module.rds_dr_replica`/`module.dr_standby_vpc` em `terra/main.tf`, controlado por `enable_dr` |
| Réplica da tabela DynamoDB (Global Tables) | Sempre ativa (custo baixo) | `module.dynamo` em `terra/main.tf`, `replica_regions` controlado por `enable_dr` |
| Hosted zone Route53 + registro PRIMARY | Sempre ativo, se `manage_dns = true` | `terra/main.tf` |
| VPC de app/EKS/NLB/observabilidade do ambiente passivo | **Desligado** - este state normalmente fica vazio | `terra-dr/` (este diretório) |

Ou seja: os dados ficam continuamente em sincronia (lag tipicamente de
segundos, não minutos - ver "Disaster Recovery" em `terra/README.md` para o
porquê disso importar para o `donation-service`), mas nenhum compute pesado
do ambiente passivo roda (nem é cobrado) enquanto não há um desastre.
"Ativar" o ambiente passivo tem duas partes: promover o replica em `terra/`
e só então aplicar este diretório pela primeira vez (ou de novo, depois de
um `terraform destroy` usado para encerrar um simulado).

## Pré-requisitos

- Que `terra/` já tenha sido aplicado com `enable_dr = true` (e, se quiser
  failover automático de DNS, `manage_dns = true`) - ver
  `terra/terraform.tfvars.example`. Sem isso, não há replica do RDS nem
  réplica do DynamoDB para usar aqui.
- Mesmos pré-requisitos de `terra/README.md` (Terraform >= 1.6, AWS CLI v2
  configurado) - já contra a conta AWS, sem precisar reconfigurar nada
  específico para a segunda região.

## Ativação (runbook)

A ativação tem 3 partes: congelar escritas no ativo, promover o replica em
`terra/`, e então subir o compute deste diretório.

**1. Congele as escritas no ambiente ativo.** `ngo-service` e
`donation-service` escrevem no Postgres; como cada um tem um HPA com
`minReplicas: 1` (`kube-aws/0NN-hpa.yaml`), um `scale --replicas=0` sozinho
não gruda - o HPA reverte. Rode contra o cluster **ativo**:

```bash
for svc in ngo-service donation-service volunteer-service; do
  kubectl patch hpa "$svc" -n solidarytech --type merge -p '{"spec":{"minReplicas":0}}'
  kubectl scale deployment "$svc" -n solidarytech --replicas=0
done
```

Zerar `donation-service` também derruba o healthcheck do Route53
(`aws_route53_health_check.primary`, porta 8082) - é o que aciona o
failover automático de DNS no passo 6, sem precisar editar o Route53 na
mão.

**2. Confirme que o replica alcançou esse ponto:**

```bash
aws rds describe-db-instances \
  --region us-west-2 \
  --db-instance-identifier solidarytech-rds-psql \
  --query 'DBInstances[0].StatusInfos'
```

Repita até o `ReplicaLag` chegar a (perto de) zero - tipicamente segundos,
não minutos.

**3. Promova o replica em `terra/`:**

```bash
cd terra
terraform apply -var="promote_dr_db=true"
```

Isso é uma promoção in-place (`ModifyDBInstance`), rápida - não é um
restore, não há espera de minutos como numa restauração de backup.

**4. Copie e edite as variáveis de `terra-dr/`:**

```bash
cd ../terra-dr
cp terraform.tfvars.example terraform.tfvars
# edite: db_password (IGUAL à senha real do ambiente ativo),
# route53_zone_id/dns_record_name (se usar failover automático de DNS -
# copie route53_zone_id do output route53_zone_id de terra/).
./init.sh   # reaproveita o bucket S3/tabela DynamoDB de lock já criados por terra/init.sh, lê rds_dr_vpc_id/rds_dr_vpc_cidr/rds_dr_connection_url direto do state remoto de terra/ (sem cópia manual) e sobe VPC/EKS/peering/NLB/Flux/observabilidade
```

`rds_dr_vpc_id`/`rds_dr_vpc_cidr`/`rds_dr_connection_url` não precisam mais
ser preenchidos em `terraform.tfvars`: `init.sh` os lê direto do state
remoto de `terra/` (mesmo bucket S3, key `terraform.tfstate`) via `aws s3
cp` + `jq` a cada execução - útil sobretudo para `rds_dr_connection_url`,
que só reflete o endpoint promovido depois do passo 3. Preencher essas 3
variáveis em `terraform.tfvars` continua funcionando como *fallback*, usado
só se o fetch automático vier vazio (por exemplo, `terra/` ainda com
`enable_dr = false`).

**5. Feche o peering.** `init.sh` já criou o VPC peering
(`aws_vpc_peering_connection.to_rds_standby`) e a rota no sentido
`terra-dr/` → replica, mas a rota de volta (replica → `terra-dr/`) só existe
depois de um segundo apply em `terra/`, agora que o peering existe:

```bash
cd ../terra-dr
terraform output dr_standby_peering_connection_id
```

```bash
cd ../terra
terraform apply -var="promote_dr_db=true" -var="dr_app_vpc_peering_connection_id=<id copiado acima>"
```

Sem esse passo, o EKS deste cluster não alcança o replica promovido -
`donation-service`/`ngo-service` ficam de pé mas sem conseguir falar com o
Postgres.

**6. Verifique o FluxCD, os microsserviços e o DNS.** O `terraform apply`
do passo 4 já instalou o FluxCD neste cluster (`../terra/modules/flux`,
mesmo módulo de `terra/` - ver "FluxCD via Terraform" em `terra/README.md`)
e aplicou o `GitRepository`, a `Kustomization` `solidarytech` e o Secret
`irsa-role-arns` (com os ARNs reais **deste** state, `role_name_suffix =
"-dr"`, vindos direto de `module.iam` - sem copiar/colar manual):

```bash
flux get kustomizations       # requer o Flux CLI - opcional
kubectl get pods -n solidarytech
```

Se `manage_dns = true` em `terra/` e `route53_zone_id`/`dns_record_name`
definidos aqui, o Route53 já deve ter trocado `PRIMARY` para `SECONDARY`
sozinho (o healthcheck do passo 1 começou a falhar assim que
`donation-service` zerou no ativo, dentro do `failure_threshold`/TTL
configurados). Sem `manage_dns`, repita manualmente o repoint de DNS
(atualizar o DNS/DDNS externo para o `nlb_dns_name` deste state).

## O que **não** é levado para o ambiente passivo

- **Fila SQS**: `module.sqs` aqui cria uma fila nova e vazia - eventos de
  doação em trânsito na fila do ambiente ativo no momento do desastre não
  são reprocessados. Aceitável dado que a doação já foi persistida no RDS
  (a fila só carrega o evento assíncrono pós-gravação) - ver
  `build/donation-service/main.go`.
- **Estado dos Pods/HPA**: sobe do zero (`minReplicas: 1` de cada HPA, antes
  de qualquer congelamento manual), igual a qualquer `terraform apply` novo
  do ambiente ativo.

## Failback (voltar para o ambiente ativo)

Espelha o mesmo mecanismo da ativação, na direção contrária - a instância
original de `terra/` é destruída e recriada como replica do novo primário
(limitação da própria AWS: não existe conversão in-place de standalone para
replica), resincroniza, e é promovida de volta.

Depois que a região original estiver saudável de novo:

1. Congele as escritas no ambiente **agora-ativo** (o antigo passivo) - mesmo
   procedimento do passo 1 da ativação, mas contra este cluster.
2. Pegue o ARN da instância atualmente ativa (o replica promovido em
   `terra-dr/` durante a ativação):

   ```bash
   cd terra-dr
   terraform output -raw rds_outputs 2>/dev/null || \
     aws rds describe-db-instances --region us-west-2 \
       --db-instance-identifier solidarytech-rds-psql --query 'DBInstances[0].DBInstanceArn' --output text
   ```
3. Em `terra/`, recrie a instância **primária** (`module.rds`) como replica
   dessa origem - `var.dr_failback_source_arn`/`var.dr_failback_promote`
   existem exatamente para isso (ver `terra/variables.tf`), sem precisar
   editar `main.tf` na mão. AWS não suporta converter uma instância
   standalone em replica in-place, então este passo destrói e recria
   `module.rds` (sem perda de dado - a réplica nova resincroniza a partir
   da origem atual, só perde a "identidade" da instância antiga):

   ```bash
   cd ../terra
   terraform apply -var="dr_failback_source_arn=<ARN copiado no passo 2>"
   ```
4. Confirme `ReplicaLag` ≈ 0 (mesmo comando do passo 2 da ativação, contra
   este novo replica) e promova:

   ```bash
   terraform apply \
     -var="dr_failback_source_arn=<mesmo ARN do passo 3>" \
     -var="dr_failback_promote=true"
   ```
5. Reponte `dns_record_name` para `terra/` (automaticamente, quando
   `aws_route53_health_check.primary` voltar a passar - reative
   `donation-service` no ativo antes) ou manualmente.
6. Depois da confirmação de que o tráfego voltou para `terra/`, restabeleça
   o replica sempre-vivo na região de DR (reaplique `terra/` sem
   `dr_failback_source_arn`/`dr_failback_promote` - volta ao padrão,
   `module.rds_dr_replica` já aponta para `module.rds.rds_arn`) e encerre o
   compute do ambiente passivo:

```bash
cd terra-dr
terraform destroy
```

Isso destrói VPC/EKS/NLB/observabilidade/peering deste state - o replica
sempre-vivo do RDS e a réplica DynamoDB continuam vivos em `terra/`
(controlados por `enable_dr`), prontos para uma próxima ativação.

## Custos

Além do que já é cobrado independente de região (o replica sempre-vivo do
RDS + a réplica DynamoDB, ambos pequenos - ver "Disaster Recovery" em
`terra/README.md`): ativar o compute deste diretório custa exatamente o
mesmo que o ambiente ativo já custa hoje (EKS control plane, NAT Gateway,
NLB, node group - ver "Custos que não têm free tier" em `terra/README.md`),
pelo tempo em que ficar de pé.
