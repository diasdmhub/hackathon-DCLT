# terra-dr/

Este é p ambiente **passivo** da estratégia de Disaster Recovery (DR) ativo-passivo da SolidaryTech (_ver "Disaster Recovery" em `terra/README.md` para a estratégia completa_). Este diretório é um _root_ Terraform independente de `terra/`, mas reaplica os mesmos módulos compartilhados (`../terra/modules/*`) numa região AWS diferente, garantindo a mesma configuração do ambiente ativo sem duplicar código.

<BR>

## O que fica sempre ligado, e o que não fica

| Camada | Estado normal (sem desastre) | Onde vive |
|---|---|---|
| Read replica cross-region sempre ativa do RDS, numa VPC mínima própria | Sempre ativo (custo baixo: uma instância `db.t3.micro`, sem NAT/EKS) | `module.rds_dr_replica`/`module.dr_standby_vpc` em `terra/main.tf`, controlado por `enable_dr` |
| Réplica da tabela DynamoDB (Global Tables) | Sempre ativa (custo baixo) | `module.dynamo` em `terra/main.tf`, `replica_regions` controlado por `enable_dr` |
| Hosted zone Route53 + registro PRIMARY | Sempre ativo, se `manage_dns = true` | `terra/main.tf` |
| VPC de app/EKS/NLB/observabilidade do ambiente passivo | **Desligado** - este _state_ normalmente fica vazio | `terra-dr/` (este diretório) |

Ou seja: os dados ficam continuamente em sincronia (atraso tipicamente de segundos, não minutos - _ver "Disaster Recovery" em `terra/README.md` para o porquê disso importar para o `donation-service`_), mas nenhum compute pesado do ambiente passivo roda (nem é cobrado) enquanto não há um desastre. "Ativar" o ambiente passivo tem duas partes: promover a réplica em `terra/` e só então aplicar este diretório.

<BR>

## Pré-requisitos

- Que `terra/` já tenha sido aplicado com `enable_dr = true`. (_ver `terra/terraform.tfvars.example`_). Sem isso, não há réplica do RDS nem réplica do DynamoDB para usar aqui.
- Mesmos pré-requisitos de `terra/README.md` (Terraform >= 1.6, AWS CLI v2 configurado).

<BR>

## Ativação e failback

O passo a passo completo (congelamento de escritas, promoção do replica, `init.sh` deste diretório, VPC peering e, na volta, o failback) está disponível em [`doc/roteiro-dr-ativacao.md`][roteirodr], mantido fora deste README para não misturar referência de módulo com _runbook_ operacional. Vale a pena preparar `terraform.tfvars` (passo 4 do roteiro) com antecedência, aproveitando que o ambiente ativo está saudável, em vez de deixar isso para o momento do desastre.

<BR>

## Custos

Além do que já é cobrado independente de região, a réplica do RDS e a réplica DynamoDB, ambas pequenas. (_ver "Disaster Recovery" em `terra/README.md`_). Ativar o _compute_ deste diretório custa exatamente o mesmo que o ambiente ativo já custa hoje pelo tempo em que ficar ativo (EKS control plane, NAT Gateway, NLB, node group - _ver "Custos que não têm free tier" em `terra/README.md`_).

[roteirodr]: /doc/roteiro-dr-ativacao.md