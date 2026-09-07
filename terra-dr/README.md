# terra-dr/

Ambiente **passivo** da estratégia de Disaster Recovery (DR) ativo-passivo do
SolidaryTech - ver "Disaster Recovery" em `terra/README.md` para a
estratégia completa. Este diretório é um root Terraform independente de
`terra/`, mas reaplica os mesmos módulos compartilhados (`../terra/modules/*`)
numa região AWS diferente, garantindo a mesma configuração do ambiente ativo
sem duplicar código.

<BR>

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

<BR>

## Pré-requisitos

- Que `terra/` já tenha sido aplicado com `enable_dr = true` (e, se quiser
  failover automático de DNS, `manage_dns = true`) - ver
  `terra/terraform.tfvars.example`. Sem isso, não há replica do RDS nem
  réplica do DynamoDB para usar aqui.
- Mesmos pré-requisitos de `terra/README.md` (Terraform >= 1.6, AWS CLI v2
  configurado) - já contra a conta AWS, sem precisar reconfigurar nada
  específico para a segunda região.

<BR>

## Ativação e failback

O passo a passo completo (congelamento de escritas, promoção do replica,
`init.sh` deste diretório, VPC peering e, na volta, o failback) vira
[`doc/roteiro-dr-ativacao.md`][roteirodr] - mantido fora deste README para
não misturar referência de módulo com runbook operacional. Vale a pena
preparar `terraform.tfvars` (passo 4 do roteiro) com antecedência, aproveitando
que o ambiente ativo está saudável, em vez de deixar isso para o momento do
desastre.

<BR>

## Custos

Além do que já é cobrado independente de região (o replica sempre-vivo do
RDS + a réplica DynamoDB, ambos pequenos - ver "Disaster Recovery" em
`terra/README.md`): ativar o compute deste diretório custa exatamente o
mesmo que o ambiente ativo já custa hoje (EKS control plane, NAT Gateway,
NLB, node group - ver "Custos que não têm free tier" em `terra/README.md`),
pelo tempo em que ficar de pé.

[roteirodr]: /doc/roteiro-dr-ativacao.md
