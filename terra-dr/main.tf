# Ambiente passivo (DR) do SolidaryTech - reaplica os mesmos módulos
# compartilhados de terra/modules/* numa região AWS diferente
# (var.aws_region, ver terraform.tfvars.example), garantindo a mesma
# configuração do ambiente ativo. Normalmente este state fica vazio (nunca
# aplicado, ou destruído após um simulado de failover) - "ativar" o
# ambiente passivo é rodar `terraform apply` aqui. Ver terra-dr/README.md
# para o runbook completo de ativação/failback e "Disaster Recovery" em
# terra/README.md para a estratégia geral.
#
# Diferenças deste root em relação a terra/main.tf:
# - Sem module "dynamo": a tabela já existe nesta região como réplica da
#   Global Table criada por terra/ (module.dynamo, replica_regions, só
#   quando enable_dr = true por lá). O ARN é montado em local.dynamodb_table_arn
#   abaixo via data.aws_caller_identity, sem gerenciar o recurso aqui.
# - Sem module "rds": o Postgres não é mais criado/restaurado por este root.
#   terra/main.tf mantém um read replica cross-region sempre-vivo do RDS
#   (module.rds_dr_replica, numa VPC mínima própria - module.dr_standby_vpc),
#   promovido a standalone via var.promote_dr_db em terra/ (não aqui). Este
#   root só se conecta a ele: um VPC peering (aws_vpc_peering_connection.to_rds_standby
#   abaixo) até a VPC mínima do replica, e var.rds_dr_connection_url (copiado
#   do output dr_replica_connection_url de terra/, depois de promovido) para
#   os Secrets ngo-env/donation-env - ver terra-dr/README.md para o runbook
#   completo de ativação.
# - module "eks"/"iam"/"lb_iam" recebem role_name_suffix = "-dr": IAM é um
#   namespace global por conta AWS, então mesmo usando o mesmo name_prefix
#   do ambiente ativo (necessário para os target groups da NLB baterem com
#   kube-aws/*.yaml - ver terra-dr/variables.tf), as IAM roles (cluster/nodes/
#   EBS CSI do EKS, e as IRSA de donation/volunteer/lb-controller) precisam
#   de um nome distinto - sem isso, o apply falha com "EntityAlreadyExists"
#   contra as roles já criadas pelo ambiente ativo.
# - Route53: só o registro SECONDARY + health check da própria NLB,
#   referenciando a zone já criada por terra/ (var.route53_zone_id).

data "aws_caller_identity" "current" {}

# VPC (base de rede)
module "vpc" {
  source = "../terra/modules/vpc"

  name_prefix   = var.name_prefix
  subnet_prefix = var.subnet_prefix
  az_count      = var.az_count
}

# EKS - depende da VPC
module "eks" {
  source = "../terra/modules/eks"

  name_prefix              = var.name_prefix
  private_subnet_ids       = module.vpc.private_subnet_ids
  kubernetes_version       = var.eks_kubernetes_version
  node_instance_types      = var.eks_node_instance_types
  node_desired_size        = var.eks_node_desired_size
  node_min_size            = var.eks_node_min_size
  node_max_size            = var.eks_node_max_size
  enable_prefix_delegation = var.enable_prefix_delegation
  role_name_suffix         = "-dr"

  depends_on = [module.vpc]
}

# VPC peering até a VPC mínima do replica do RDS (module.dr_standby_vpc em
# terra/main.tf, mesma região - ver terra/variables.tf, dr_aws_region).
# auto_accept = true: as duas VPCs pertencem à mesma conta AWS, então não é
# necessário um aws_vpc_peering_connection_accepter separado do lado de
# terra/. var.rds_dr_vpc_id/var.rds_dr_vpc_cidr são copiados dos outputs
# dr_standby_vpc_id/dr_standby_vpc_cidr de terra/ (mesma convenção manual de
# var.route53_zone_id, sem terraform_remote_state) - ver o runbook de
# ativação em terra-dr/README.md.
resource "aws_vpc_peering_connection" "to_rds_standby" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = var.rds_dr_vpc_id
  auto_accept = true

  tags = { Name = "${var.name_prefix}-dr-app-to-rds-standby-pcx" }
}

# Habilita resolução de DNS through peering nos dois sentidos - sem isso, o
# endpoint do RDS (um hostname, não um IP fixo) não resolveria para o IP
# privado alcançável via peering a partir dos pods do EKS.
resource "aws_vpc_peering_connection_options" "to_rds_standby" {
  vpc_peering_connection_id = aws_vpc_peering_connection.to_rds_standby.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

# Rota da VPC de app até a VPC mínima do replica, via o peering acima. A
# rota no sentido contrário (aws_route.dr_standby_to_app_vpc em terra/main.tf)
# só é criada depois, num segundo apply de terra/ com
# var.dr_app_vpc_peering_connection_id = aws_vpc_peering_connection.to_rds_standby.id
# (output dr_standby_peering_connection_id abaixo) - ver o runbook de
# ativação em terra-dr/README.md.
resource "aws_route" "app_vpc_to_rds_standby" {
  route_table_id            = module.vpc.private_route_table_id
  destination_cidr_block    = var.rds_dr_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.to_rds_standby.id
}

# SQS - fila nova e independente, não replicada do ambiente ativo (eventos
# de doação em trânsito não são reprocessados na ativação - ver
# terra-dr/README.md).
module "sqs" {
  source = "../terra/modules/sqs"

  name_prefix = var.name_prefix
  queue_name  = var.sqs_queue_name
}

locals {
  # A tabela já existe nesta região como réplica da Global Table (ver
  # terra/main.tf, module.dynamo com replica_regions) - só referenciada
  # aqui, não criada. Réplicas de Global Tables mantêm o mesmo nome de
  # tabela em toda região.
  dynamodb_table_arn = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}"
}

# IAM/IRSA - depende do OIDC provider do EKS e dos ARNs de SQS/DynamoDB
module "iam" {
  source = "../terra/modules/iam"

  name_prefix               = var.name_prefix
  role_name_suffix          = "-dr"
  oidc_provider_arn         = module.eks.eks_oidc_provider_arn
  oidc_provider_url         = module.eks.eks_oidc_provider_url
  namespace                 = var.k8s_namespace
  donation_service_account  = var.donation_service_account
  volunteer_service_account = var.volunteer_service_account
  sqs_queue_arn             = module.sqs.sqs_queue_arn
  dynamodb_table_arn        = local.dynamodb_table_arn

  depends_on = [module.eks, module.sqs]
}

# NLB única compartilhada pelos 3 microsserviços - mesmos target groups
# determinísticos (${name_prefix}-<service>-tg) que kube-aws/*.yaml já
# referencia via targetGroupName, sem precisar de nenhum ajuste nos
# manifests compartilhados.
module "nlb" {
  source = "../terra/modules/nlb"

  name_prefix               = var.name_prefix
  vpc_id                    = module.vpc.vpc_id
  public_subnet_ids         = module.vpc.public_subnet_ids
  cluster_security_group_id = module.eks.eks_cluster_security_group_id

  depends_on = [module.vpc, module.eks]
}

# IAM/IRSA do AWS Load Balancer Controller
module "lb_iam" {
  source = "../terra/modules/lb-iam"

  name_prefix       = var.name_prefix
  role_name_suffix  = "-dr"
  oidc_provider_arn = module.eks.eks_oidc_provider_arn
  oidc_provider_url = module.eks.eks_oidc_provider_url
  namespace         = var.lb_controller_namespace
  service_account   = var.lb_controller_service_account

  depends_on = [module.eks]
}

# AWS Load Balancer Controller em si (ServiceAccount + HelmRelease)
module "lb" {
  source = "../terra/modules/lb"

  namespace       = var.lb_controller_namespace
  service_account = var.lb_controller_service_account
  role_arn        = module.lb_iam.role_arn
  cluster_name    = module.eks.eks_cluster_name
  aws_region      = var.aws_region

  depends_on = [module.eks, module.lb_iam]
}

# Namespace solidarytech - mesmo raciocínio de terra/main.tf: criado aqui
# (não pelo Flux) para que os Secrets *-env possam ser aplicados no mesmo
# `terraform apply` que provisiona RDS/SQS.
resource "kubernetes_namespace_v1" "solidarytech" {
  metadata {
    name = var.k8s_namespace
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "dr"
    }
  }

  depends_on = [module.eks]
}

# Secrets (SSM Parameter Store + Secrets Kubernetes ngo-env/donation-env/
# volunteer-env), com os valores reais desta região (RDS promovido, fila
# SQS nova, mesma tabela DynamoDB).
module "secrets" {
  source = "../terra/modules/secrets"

  name_prefix         = var.name_prefix
  rds_connection_url  = var.rds_dr_connection_url
  rds_password        = var.db_password
  sqs_queue_url       = module.sqs.sqs_queue_url
  dynamodb_table_name = var.dynamodb_table_name
  k8s_namespace       = kubernetes_namespace_v1.solidarytech.metadata[0].name
  aws_region          = var.aws_region

  depends_on = [module.sqs, kubernetes_namespace_v1.solidarytech]
}

# FluxCD - mesmo módulo compartilhado de terra/main.tf, aplicado com o YAML
# próprio deste cluster (clusters/eks-aws-dr/) e os ARNs de IRSA com o
# sufixo "-dr" (module.iam acima, role_name_suffix = "-dr"). Ver "FluxCD via
# Terraform" em terra/README.md.
locals {
  flux_git_repository_yaml = file("${path.module}/../clusters/eks-aws-dr/flux-system/gotk-sync.yaml")
  flux_kustomization_yaml  = file("${path.module}/../clusters/eks-aws-dr/solidarytech-kustomization.yaml")
}

module "flux" {
  source = "../terra/modules/flux"

  chart_version              = var.flux_chart_version
  git_repository_yaml        = local.flux_git_repository_yaml
  kustomization_yaml         = local.flux_kustomization_yaml
  donation_service_role_arn  = module.iam.donation_service_role_arn
  volunteer_service_role_arn = module.iam.volunteer_service_role_arn

  depends_on = [module.eks, module.lb, module.iam, kubernetes_namespace_v1.solidarytech, module.secrets]
}

# Observabilidade e métricas de infraestrutura, idêntico a terra/main.tf.
resource "kubernetes_namespace_v1" "observe" {
  metadata {
    name = "observe"
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "dr"
    }
  }

  depends_on = [module.eks]
}

module "loki" {
  source = "../terra/modules/loki"

  namespace = kubernetes_namespace_v1.observe.metadata[0].name

  depends_on = [kubernetes_namespace_v1.observe]
}

module "tempo" {
  source = "../terra/modules/tempo"

  namespace = kubernetes_namespace_v1.observe.metadata[0].name

  depends_on = [kubernetes_namespace_v1.observe]
}

module "prometheus" {
  source = "../terra/modules/prometheus"

  namespace = kubernetes_namespace_v1.observe.metadata[0].name

  depends_on = [kubernetes_namespace_v1.observe]
}

module "alloy" {
  source = "../terra/modules/alloy"

  namespace = kubernetes_namespace_v1.observe.metadata[0].name

  depends_on = [kubernetes_namespace_v1.observe]
}

# Registro SECONDARY de failover - a hosted zone e o registro PRIMARY já
# existem no state do ambiente ativo (terra/, aws_route53_zone.dr +
# aws_route53_record.primary, só quando manage_dns = true por lá).
# Referenciamos a zone existente via var.route53_zone_id (copiado do output
# route53_zone_id de terra/) em vez de terraform_remote_state, para não
# acoplar os dois states. Aponta para o donation-service (porta 8082), o
# hot path da plataforma, em vez do ngo-service - mesmo endpoint checado
# pelo health check primary em terra/.
resource "aws_route53_health_check" "secondary" {
  count = var.route53_zone_id == "" ? 0 : 1

  fqdn              = module.nlb.nlb_dns_name
  port              = 8082
  type              = "HTTP"
  resource_path     = "/health"
  request_interval  = 30
  failure_threshold = 3

  tags = { Name = "${var.name_prefix}-dr-secondary-health" }
}

resource "aws_route53_record" "secondary" {
  count = var.route53_zone_id == "" ? 0 : 1

  zone_id = var.route53_zone_id
  name    = var.dns_record_name
  type    = "CNAME"
  ttl     = 30
  records = [module.nlb.nlb_dns_name]

  set_identifier = "secondary"
  failover_routing_policy {
    type = "SECONDARY"
  }
  health_check_id = aws_route53_health_check.secondary[0].id
}
