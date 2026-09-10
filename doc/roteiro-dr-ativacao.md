| [↩️ Voltar](./) |
| --- |

# Roteiro de ativação e failback do ambiente de DR

Esta é a sequência de comandos para ativar o ambiente passivo da estratégia de Disaster Recovery ativo-passivo da SolidaryTech e, depois,retornar (_failback_) ao ambiente principal. As diferênças entre o que está sempre ligado e o que está sob demanda, bem como as razões de cada escolha, estão descritas em "Disaster Recovery" em [`terra/README.md`][terra] e em [`terra-dr/README.md`][terradr]. Este roteiro reúne apenas os passos na ordem correta, considerando as variantes de contingência quando a região principal estiver realmente indisponível.

> ⚠️ **Não espere um desastre real para chegar à Parte 1.** O ambiente principal deve estar aplicado com `enable_dr = true` (e, para failover automático de DNS, `manage_dns = true`) e o `terra-dr/terraform.tfvars` deve estar preparado com antecedência. _Veja o passo 4 de [`doc/roteiro-cluster-aws.md`][implementacao]_.

<BR>

## Ativação

> ⚠️ **Compreende-se que não vale a pena automatizar os passos de 1 a 3, pois são ações potencialmente destrutivas contra o ambiente ativo (zerar réplicas do donation/ngo), e exigem julgamento adicional sobre o estado real do desastre.**

### 1. Congele as escritas no ambiente ativo

Como os serviços `ngo` e `donation` escrevem no Postgres, a escrita deve ser interrompida. Execute o comando abaixo contra o cluster **ativo**:

```bash
for svc in ngo donation volunteer; do
  kubectl patch hpa "$svc" -n solidarytech --type merge -p '{"spec":{"minReplicas":0}}'
  kubectl scale deployment "$svc" -n solidarytech --replicas=0
done
```

Ao zerar o serviço `donation`, o _healthcheck_ do Route53 também derrubado. Isso aciona o failover automático de DNS no passo 6, sem a necessidade de edição manual do Route53.

<BR>

### 2. Confirme que o replica alcançou esse ponto

> ⚠️ **Necessário para evitar perda de dados do DB.**

```bash
aws rds describe-db-instances \
  --region us-west-2 \
  --db-instance-identifier solidarytech-rds-psql \
  --query 'DBInstances[0].StatusInfos'
```

Isso confirma apenas o `Status: replicating` / `Normal: true` (a replicação não parou), mas não apresenta o valor numérico do atraso. Para obter o número real, consulte a métrica `ReplicaLag` do CloudWatch:

```bash
aws cloudwatch get-metric-statistics --region us-west-2 \
  --namespace AWS/RDS --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value=solidarytech-rds-psql \
  --start-time "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average]' --output text
```

Repita o comando até que o `ReplicaLag` chegue próximo a zero (tipicamente em segundos, não em minutos).

> ℹ️ Mesmo com as escritas já congeladas (passo 1), essa métrica não cai monotonicamente para zero; ela oscila com ruído de _polling_ entre 0-30s em regime normal. Não espere um valor exato de zero: um valor estável de algumas dezenas de segundos por 2 a 3 leituras já é suficiente para seguir para o passo 3. Esperar por algo como 5s ou menos pode nunca acontecer.

<BR>

### 3. Promova o replica em `terra/`

**COM conectividade** - **Se a região principal ainda estiver acessível**, no caso de um simulado ou de um desastre parcial que não tenha derrubado a API da AWS.

```bash
cd terra
terraform apply -var="promote_dr_db=true"
```

Isso é uma promoção in-place (`ModifyDBInstance`) rápida, não sendo uma restauração, portanto, não há necessidade de muita espera como numa restauração de backup.

**SEM conectividade** - **Se a região principal NÃO estiver acessível**, o _refresh_ acima pode travar ou falhar, bloqueando o Terraform. Use a variante restrita à replica em vez disso:

```bash
cd terra
terraform apply -refresh=false \
  -target=module.dr_standby_vpc \
  -target=module.rds_dr_replica \
  -var="promote_dr_db=true"
```

O `module.rds_dr_replica` faz referência à instância primária apenas como `module.rds.rds_arn` (`terra/main.tf`), um valor já conhecido no _state_. O parâmetro `-refresh=false` evita qualquer chamada à API da região principal para obtê-lo, utilizando o dado já salvo. O backend deste _state_ (bucket S3 + tabela DynamoDB de _statelock_) fica em `us-west-2`, a mesma do ambiente passivo, e não na região ativa. Isso foi proposital para que o backend continue acessível quando a região  principal estiver indisponível (_veja "Bootstrap do backend remoto" em [`terra/README.md`][terra]_).

> ⚠️ **Valide este comando num simulado antes de confiar nele no dia real.** Uma forma simples de simular a região principal fora do ar é bloquear localmente a resolução do domínio `ec2.us-east-1.amazonaws.com`/`rds.us-east-1.amazonaws.com` (por exemplo, via arquivo `/etc/hosts` apontando para `127.0.0.1`), e confirmar que o `apply` acima ainda é concluído.

<BR>

### 4. Copie e edite as variáveis de `terra-dr/`

```bash
cd ../terra-dr
cp terraform.tfvars.example terraform.tfvars
# edite: db_password (IGUAL à senha real do ambiente ativo) e
# dns_record_name (se usar failover automático de DNS - precisa ser IGUAL
# ao usado em terra/terraform.tfvars)

./init.sh
```

O script `init.sh` aproveita o bucket S3 e a tabela DynamoDB de _lock_ já criados pelo `terra/init.sh`. Ele lê `rds_dr_vpc_id`/`rds_dr_vpc_cidr`/`rds_dr_connection_url`/`route53_zone_id` diretamente do _state_ remoto do `terra/` e inicializa os recursos VPC/EKS/peering/NLB/Flux/observabilidade. O preenchimento dessas 4 variáveis em `terraform.tfvars` continua funcionando como _fallback_, sendo utilizado apenas se o _fetch_ automático estiver vazio.

<BR>

### 5. Feche o peering

Nesta etapa, o `init.sh` já criou o VPC peering e a rota no sentido `terra-dr/` > replica, mas a rota de volta (replica > `terra-dr/`) só existe após um segundo apply em `terra/`, agora que o peering existe:

```bash
terraform output dr_standby_peering_connection_id
```

```bash
cd ../terra
terraform apply -var="promote_dr_db=true" -var="dr_app_vpc_peering_connection_id=<id copiado acima>"
```

Sem esse passo, o EKS do ambiente passivo não consegue alcançar a réplica promovida. Os serviços `donation-service`/`ngo-service` são iniciados, mas não conseguem se comunicar com o Postgres.

<BR>

### 6. Aponte o `kubectl` para verificar o FluxCD, os microsserviços e o DNS

No passo 4, o `terraform apply` já instalou o FluxCD neste cluster e aplicou o `GitRepository`, a `Kustomization` `solidarytech` e o Secret `irsa-role-arns` com os ARNs reais **deste** _state_ e `role_name_suffix = "-dr"`, obtidos diretamente do `module.iam`. Aponte o `kubectl` local para este novo cluster antes de consultá-lo:

```bash
cd ../terra-dr
$(terraform output -raw configure_kubectl 2>/dev/null) || \
  aws eks update-kubeconfig --region us-west-2 --name solidarytech-eks-cluster
```

```bash
# requer o Flux CLI - opcional
flux get kustomizations
# alternativamente use o kubectl para verificar os pods
kubectl get pods -n solidarytech
```

Se `manage_dns = true` em `terra/` e se `route53_zone_id`/`dns_record_name` estiverem definidos aqui, o Route53 já deve ter alterado o status de `PRIMARY` para `SECONDARY` automaticamente. Sem o `manage_dns`, é necessário repetir manualmente a atualização de DNS (DNS/DDNS externo para o `nlb_dns_name` deste _state_).

> ℹ️ Logo após o `apply` deste passo, o healthcheck `SECONDARY` do Route53 pode reportar `Connection timed out` por 1-2 minutos mesmo com o `TargetGroupBinding` já reconciliado e o _target group_ já `healthy` internamente. Isso é o tempo normal de propagação do NLB recém-criado até ficar alcançável pela rede pública, não um erro de configuração.

<BR>

## O que **não** é levado para o ambiente passivo

- **Fila SQS**: o `module.sqs` em `terra-dr/` cria uma fila nova e vazia. Os eventos de doação em trânsito na fila do ambiente ativo no momento do desastre não possuem mecanismo de reprossamento pois estão fora do contexto destre projeto. Isso é aceitável dado que a doação já foi persistida no RDS (a fila só carrega o evento assíncrono após a gravação no DB).
- **Estado dos Pods/HPA**: sobe de zero (`minReplicas: 1` de cada HPA), o que é igual a qualquer `terraform apply` novo do ambiente ativo.

<BR>

## O que esta estratégia não cobre

Este roteiro corrige falhas de infraestrutura da AWS da região ativa, como a indisponibilidade de uma instância RDS, de um cluster EKS ou de uma zona de disponibilidade inteira. No entanto, ele não resolve um problema diferente: a indisponibilidade de rede entre um grupo específico de usuários e a região ativa, mesmo com os recursos da AWS funcionando normalmente.

Por exemplo, se a maior parte das doações vier de uma região geográfica específica e essa região perder a rota de rede até `us-east-1` (por causa de um problema no backbone ou em um ISP local, por exemplo), o administrador e a própria AWS ainda verão tudo funcionando normalmente. Promover a replicação e migrar para `us-west-2` não corrige esse cenário por si só, pois nada garante que a rota até a nova região esteja íntegra para os mesmos usuários afetados, já que o problema não está na AWS.

Esse segundo tipo de indisponibilidade exige uma solução diferente, tipicamente uma configuração "ativo-ativo" com roteamento por latência ou geolocalização no Route53, ou o AWS Global Accelerator (que usa a própria rede backbone da AWS e realiza failover na camada de rede). Qualquer uma dessas opções exige a manutenção de múltiplas regiões ativas simultaneamente, o que elevaria muito o custo deste projeto. Por isso, essa classe de problema fica fora do escopo desta estratégia.

<BR>

## Parte 2 — Failback (voltar para o ambiente principal)

O mesmo mecanismo de ativação é espelhado, na direção contrária: a instância original de `terra/` é destruída e recriada como réplica do novo primário (_não existe conversão in-place de _standalone_ para replica_), é resincronizada e é promovida de volta. Faça isso somente após a confirmação da saúde da região original.

### 1. Congele as escritas no ambiente agora ativo

O mesmo procedimento do passo 1 da ativação, mas contra o cluster que hoje está no ativo (_o antigo passivo, `terra-dr/`_).

> ℹ️ **Esta operação só se aplica a um simulado, não a um desastre real**. Se o "ambiente ativo original" foi zerado manualmente (passo 1 da ativação) apenas para simular o desastre, ele permanecerá zerado nesta altura. Uma recuperação real da região não apresentaria essa marca. Após o passo 4 abaixo (promoção concluída), lembre de executar o mesmo comando para cada serviço contra o cluster **original**, antes de esperar o failover de DNS. \
> `for svc in ngo donation volunteer; do kubectl scale deployment "$svc" -n solidarytech --replicas=1; kubectl patch hpa "$svc" -n solidarytech --type merge -p '{"spec":{"minReplicas":1}}'; done`

<BR>

### 2. ARN da instância atualmente ativa

Consulte o ARN da replica promovida em `terra-dr/` durante a ativação:

```bash
cd terra-dr
terraform output -raw rds_outputs 2>/dev/null || \
  aws rds describe-db-instances --region us-west-2 \
    --db-instance-identifier solidarytech-rds-psql --query 'DBInstances[0].DBInstanceArn' --output text
```

<BR>

### 3. Recrie a instância primária como replica dessa origem

As variáveis `var.dr_failback_source_arn` e `var.dr_failback_promote` existem exatamente para isso (_ver `terra/variables.tf`_). A AWS não suporta converter uma instância _standalone_ em replica _in-place_, portanto esse passo deve destruir e recriar o módulo RDS sem perda de dados, pois a nova réplica resincroniza a partir da origem atual; só perde a "identidade" da instância antiga.

```bash
cd ../terra
terraform apply -target=module.rds.aws_db_instance.this -replace=module.rds.aws_db_instance.this -var="dr_failback_source_arn=<ARN copiado no passo 2>"
```

> ℹ️ O uso conjunto dos parâmetros `-target` e `-replace` limita a mudança à instância parada. _Veja o comentário em `terra/modules/rds/rds.tf` para mais detalhes técnicos._

<BR>

### 4. Confirme o lag e promova

O mesmo comando (com a variante CloudWatch) do passo 2 da ativação deve ser executado contra essa nova réplica (agora na região original). Quando `ReplicaLag ≈ 0`:

```bash
terraform apply -target=module.rds.aws_db_instance.this \
  -var="dr_failback_source_arn=<mesmo ARN do passo 3>" \
  -var="dr_failback_promote=true" \
  -var="promote_dr_db=true"
```

`promote_dr_db=true` também deve permanecer presente aqui seguindo o mesmo padrão do passo 5 da ativação. Sem ele, `module.rds_dr_replica[0]` (ainda a instância ativa neste momento) tentaria se tornar uma réplica novamente. O parâmetro `-target` mantém o apply restrito à instância que está sendo 

<BR>

### 5. Reapontamento do DNS

O processo é automático quando `aws_route53_health_check.primary` voltar a passar (reative os 3 serviços ativos anteriormente e reative `donation` especificamente), ou manual, se `manage_dns` não estiver habilitado.

<BR>

### 6. Restabeleça a replica sempre ativa e encerre a passiva

Após a confirmação de que o tráfego foi restabelecido para o ambiente principal, force a recriação de `module.rds_dr_replica[0]` como uma réplica nova (mesma razão do passo 3: não há conversão _in-place_ de _standalone_ para replica) e encerre o processamento no ambiente passivo.

```bash
cd ../terra
terraform apply -target='module.rds_dr_replica[0].aws_db_instance.this' -replace='module.rds_dr_replica[0].aws_db_instance.this'
```

Sem as variáveis `dr_failback_source_arn` e `dr_failback_promote`, elas variáveis voltam ao padrão (`null`/`false`) e `module.rds_dr_replica` volta a apontar para `module.rds.rds_arn` como réplica sempre ativa, exatamente como no papel original. Como depende de `module.rds`, o `-target` também reavalia esse recurso, mas não o substitui. Espere ver `engine_version`/`password` aparecerem como alterados nele. Isso é um efeito colateral inofensivo, documentado em `terra/modules/rds/rds.tf` (não há downgrade real, a senha continua a mesma). Em simulação real, a criação de uma réplica cross-region do zero pode ser o passo mais lento do failback.

Por fim, encerre o processamento do ambiente passivo:

```bash
cd ../terra-dr
terraform destroy
```

Isso destrói VPC/EKS/NLB/observabilidade/peering deste _state_. A réplica sempre ativa do RDS e a réplica DynamoDB continuam ativas em `terra/` (controlados por `enable_dr`), prontas para uma próxima ativação.

<BR>

| [⬆️ Top](#roteiro-de-ativação-e-failback-do-ambiente-de-dr) |
| --- |

[terra]: /terra/README.md
[terradr]: /terra-dr/README.md
[implementacao]: /doc/roteiro-cluster-aws.md
