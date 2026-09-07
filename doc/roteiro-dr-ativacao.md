| [↩️ Voltar](./) |
| --- |

# Roteiro de ativação e failback do ambiente de DR

Esta é a sequência de comandos para ativar o ambiente passivo (`terra-dr/`) da estratégia de Disaster Recovery ativo-passivo do SolidaryTech, e para depois voltar (failback) ao ambiente principal (`terra/`). O que fica sempre ligado versus sob demanda, e o porquê de cada escolha, estão em "Disaster Recovery" em [`terra/README.md`][terra] e em [`terra-dr/README.md`][terradr]; este roteiro só reúne os passos na ordem certa, já com as variantes de contingência quando a região principal está mesmo indisponível.

> ⚠️ **Não espere um desastre real para chegar à Parte 1.** `terra/` precisa já estar aplicado com `enable_dr = true` (e, para failover automático de DNS, `manage_dns = true`), e `terra-dr/terraform.tfvars` deve estar preparado com antecedência - ver passo 4 de [`doc/roteiro-cluster-aws.md`][implementacao].

<BR>

## Parte 1 — Ativação

### 1. Congele as escritas no ambiente ativo

`ngo-service` e `donation-service` escrevem no Postgres. Como cada um tem um HPA com `minReplicas: 1` (`kube-aws/0NN-hpa.yaml`), um `scale --replicas=0` sozinho não gruda — o HPA reverte. Rode contra o cluster **ativo**:

```bash
for svc in ngo-service donation-service volunteer-service; do
  kubectl patch hpa "$svc" -n solidarytech --type merge -p '{"spec":{"minReplicas":0}}'
  kubectl scale deployment "$svc" -n solidarytech --replicas=0
done
```

Zerar `donation-service` também derruba o healthcheck do Route53 (`aws_route53_health_check.primary`, porta 8082) — é o que aciona o failover automático de DNS no passo 6, sem precisar editar o Route53 na mão.

### 2. Confirme que o replica alcançou esse ponto

```bash
aws rds describe-db-instances \
  --region us-west-2 \
  --db-instance-identifier solidarytech-rds-psql \
  --query 'DBInstances[0].StatusInfos'
```

Repita até o `ReplicaLag` chegar a (perto de) zero — tipicamente segundos, não minutos.

### 3. Promova o replica em `terra/`

**Se a região principal (`us-east-1`) ainda está acessível** (simulado, ou desastre parcial que não derrubou a API da AWS ali):

```bash
cd terra
terraform apply -var="promote_dr_db=true"
```

Isso é uma promoção in-place (`ModifyDBInstance`), rápida — não é um restore, não há espera de minutos como numa restauração de backup.

**Se a região principal está mesmo inacessível** (o cenário real que este roteiro existe para cobrir): o comando acima roda contra o state inteiro de `terra/`, que também contém todo o ambiente ativo (EKS, VPC, NLB, a própria instância RDS primária). Por padrão, `terraform apply` faz refresh de todos os recursos do state antes de aplicar qualquer coisa — se a região principal estiver fora do ar, esse refresh pode travar ou falhar, bloqueando exatamente o comando que você mais precisa que funcione. Use a variante restrita ao replica em vez disso:

```bash
cd terra
terraform apply -refresh=false \
  -target=module.dr_standby_vpc \
  -target=module.rds_dr_replica \
  -var="promote_dr_db=true"
```

`module.rds_dr_replica` referencia a instância primária só como `module.rds.rds_arn` (`terra/main.tf`), um valor já conhecido no state — `-refresh=false` evita qualquer chamada à API da região principal para obtê-lo, usando o dado já salvo. O backend deste state (bucket S3 + tabela DynamoDB de lock) fica em `us-west-2`, a mesma região do ambiente passivo, não na região ativa — de propósito, para que o backend continue acessível justamente quando a região principal está indisponível (ver "Bootstrap do backend remoto" em [`terra/README.md`][terra]).

> ⚠️ **Valide este comando num simulado antes de confiar nele no dia real.** O comportamento exato de `-target` combinado com `-refresh=false` já mudou entre versões do Terraform. Um jeito simples de simular a região principal fora do ar: bloquear localmente a resolução de `ec2.us-east-1.amazonaws.com`/`rds.us-east-1.amazonaws.com` (por exemplo, via `/etc/hosts` apontando para `127.0.0.1`) e confirmar que o `apply` acima ainda completa.

### 4. Copie e edite as variáveis de `terra-dr/`

```bash
cd ../terra-dr
cp terraform.tfvars.example terraform.tfvars
# edite: db_password (IGUAL à senha real do ambiente ativo) e
# dns_record_name (se usar failover automático de DNS - precisa ser IGUAL
# ao usado em terra/terraform.tfvars)

./init.sh
```

`init.sh` reaproveita o bucket S3/tabela DynamoDB de lock já criados por `terra/init.sh`, lê `rds_dr_vpc_id`/`rds_dr_vpc_cidr`/`rds_dr_connection_url`/`route53_zone_id` direto do state remoto de `terra/` (sem cópia manual) e sobe VPC/EKS/peering/NLB/Flux/observabilidade. Preencher essas 4 variáveis em `terraform.tfvars` continua funcionando como *fallback*, usado só se o fetch automático vier vazio.

### 5. Feche o peering

`init.sh` já criou o VPC peering (`aws_vpc_peering_connection.to_rds_standby`) e a rota no sentido `terra-dr/` → replica, mas a rota de volta (replica → `terra-dr/`) só existe depois de um segundo apply em `terra/`, agora que o peering existe:

```bash
terraform output dr_standby_peering_connection_id
```

```bash
cd ../terra
terraform apply -var="promote_dr_db=true" -var="dr_app_vpc_peering_connection_id=<id copiado acima>"
```

Sem esse passo, o EKS do ambiente passivo não alcança o replica promovido — `donation-service`/`ngo-service` ficam de pé mas sem conseguir falar com o Postgres.

### 6. Aponte o `kubectl`, e verifique o FluxCD, os microsserviços e o DNS

O `terraform apply` do passo 4 já instalou o FluxCD neste cluster (`../terra/modules/flux`, mesmo módulo de `terra/`) e aplicou o `GitRepository`, a `Kustomization` `solidarytech` e o Secret `irsa-role-arns` (com os ARNs reais **deste** state, `role_name_suffix = "-dr"`, vindos direto de `module.iam` — sem copiar/colar manual). Aponte o `kubectl` local para este novo cluster antes de consultá-lo:

```bash
cd ../terra-dr
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-west-2 --name solidarytech-eks-cluster
```

```bash
flux get kustomizations       # requer o Flux CLI - opcional
kubectl get pods -n solidarytech
```

Se `manage_dns = true` em `terra/` e `route53_zone_id`/`dns_record_name` definidos aqui, o Route53 já deve ter trocado `PRIMARY` para `SECONDARY` sozinho (o healthcheck do passo 1 começou a falhar assim que `donation-service` zerou no ativo, dentro do `failure_threshold`/TTL configurados). Sem `manage_dns`, repita manualmente o repoint de DNS (atualizar o DNS/DDNS externo para o `nlb_dns_name` deste state).

<BR>

## O que **não** é levado para o ambiente passivo

- **Fila SQS**: `module.sqs` em `terra-dr/` cria uma fila nova e vazia — eventos de doação em trânsito na fila do ambiente ativo no momento do desastre não são reprocessados. Aceitável dado que a doação já foi persistida no RDS (a fila só carrega o evento assíncrono pós-gravação) — ver `build/donation-service/main.go`.
- **Estado dos Pods/HPA**: sobe do zero (`minReplicas: 1` de cada HPA, antes de qualquer congelamento manual), igual a qualquer `terraform apply` novo do ambiente ativo.

<BR>

## O que esta estratégia não cobre

Este roteiro resolve falha de infraestrutura da AWS na região ativa (a instância RDS, o cluster EKS, uma zona de disponibilidade inteira ficando indisponível). Ele não resolve um problema diferente: indisponibilidade de rede entre um grupo específico de usuários e a região ativa, com os recursos da AWS continuando saudáveis.

Um exemplo concreto: se a maior parte das doações vem de uma região geográfica específica, e essa região perde a rota de rede até `us-east-1` (um problema de backbone ou de um ISP local, por exemplo), o administrador e a própria AWS ainda enxergam tudo funcionando normalmente ali. Promover o replica e migrar para `us-west-2` não corrige esse cenário por si só: nada garante que a rota até a nova região esteja íntegra para os mesmos usuários afetados, já que o problema não está na AWS.

Esse segundo tipo de indisponibilidade pertence a outra categoria de solução, tipicamente uma configuração ativo-ativo com roteamento por latência ou geolocalização no Route53, ou o AWS Global Accelerator (que usa a rede backbone própria da AWS via IPs anycast e faz failover na camada de rede, não por TTL de DNS). Qualquer uma dessas opções exige manter múltiplas regiões ativas ao mesmo tempo, o que contradiz a premissa de custo deste projeto (região passiva praticamente desligada, só com a réplica de dados barata e contínua — ver "Disaster Recovery" em [`terra/README.md`][terra]). Por isso, essa classe de problema fica fora do escopo desta estratégia, por decisão deliberada e não por descuido.

<BR>

## Parte 2 — Failback (voltar para o ambiente principal)

Espelha o mesmo mecanismo da ativação, na direção contrária — a instância original de `terra/` é destruída e recriada como replica do novo primário (limitação da própria AWS: não existe conversão in-place de standalone para replica), resincroniza, e é promovida de volta. Faça isso só depois que a região original estiver confirmada saudável de novo.

### 1. Congele as escritas no ambiente agora-ativo

Mesmo procedimento do passo 1 da ativação, mas contra o cluster que hoje está no ar (o antigo passivo, `terra-dr/`).

### 2. Pegue o ARN da instância atualmente ativa

O replica promovido em `terra-dr/` durante a ativação:

```bash
cd terra-dr
terraform output -raw rds_outputs 2>/dev/null || \
  aws rds describe-db-instances --region us-west-2 \
    --db-instance-identifier solidarytech-rds-psql --query 'DBInstances[0].DBInstanceArn' --output text
```

### 3. Recrie a instância primária como replica dessa origem

`var.dr_failback_source_arn`/`var.dr_failback_promote` existem exatamente para isso (ver `terra/variables.tf`), sem precisar editar `main.tf` na mão. A AWS não suporta converter uma instância standalone em replica in-place, então este passo destrói e recria `module.rds` (sem perda de dado — a réplica nova resincroniza a partir da origem atual, só perde a "identidade" da instância antiga):

```bash
cd ../terra
terraform apply -var="dr_failback_source_arn=<ARN copiado no passo 2>"
```

### 4. Confirme o lag e promova

Mesmo comando do passo 2 da ativação, contra este novo replica. Quando `ReplicaLag` ≈ 0:

```bash
terraform apply \
  -var="dr_failback_source_arn=<mesmo ARN do passo 3>" \
  -var="dr_failback_promote=true"
```

### 5. Reponte o DNS

Automaticamente, quando `aws_route53_health_check.primary` voltar a passar (reative `donation-service` no ativo antes) — ou manualmente, se `manage_dns` não estiver habilitado.

### 6. Restabeleça o replica sempre-vivo e encerre o passivo

Depois da confirmação de que o tráfego voltou para `terra/`, reaplique `terra/` sem `dr_failback_source_arn`/`dr_failback_promote` (volta ao padrão, `module.rds_dr_replica` já aponta de novo para `module.rds.rds_arn`) e encerre o compute do ambiente passivo:

```bash
cd terra-dr
terraform destroy
```

Isso destrói VPC/EKS/NLB/observabilidade/peering deste state — o replica sempre-vivo do RDS e a réplica DynamoDB continuam vivos em `terra/` (controlados por `enable_dr`), prontos para uma próxima ativação.

<BR>

| [⬆️ Top](#roteiro-de-ativação-e-failback-do-ambiente-de-dr) |
| --- |

[terra]: /terra/README.md
[terradr]: /terra-dr/README.md
[implementacao]: /doc/roteiro-cluster-aws.md
