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
# - module "rds" recebe var.rds_restore_source_arn: em vez de criar um banco
#   vazio, restaura a partir do backup automatizado replicado cross-region
#   por terra/ (aws_db_instance_automated_backups_replication) - ver
#   terra-dr/README.md para como descobrir esse ARN na ativação.
# - module "iam"/"lb_iam" recebem role_name_suffix = "-dr": IAM é um
#   namespace global por conta AWS, então mesmo usando o mesmo name_prefix
#   do ambiente ativo (necessário para os target groups da NLB baterem com
#   kube-aws/*.yaml - ver terra-dr/variables.tf), as roles IRSA precisam de
#   um nome distinto.
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

  depends_on = [module.vpc]
}

# RDS - depende da VPC. restore_source_arn (var.rds_restore_source_arn)
# controla se a instância é criada vazia ou restaurada do backup replicado -
# ver terra/modules/rds/rds.tf.
module "rds" {
  source = "../terra/modules/rds"

  name_prefix             = var.name_prefix
  db_name                 = var.db_name
  db_username             = var.db_username
  db_password             = var.db_password
  instance_class          = var.rds_instance_class
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = module.vpc.vpc_cidr
  private_subnet_ids      = module.vpc.private_subnet_ids
  backup_retention_period = var.rds_backup_retention_period
  restore_source_arn      = var.rds_restore_source_arn

  depends_on = [module.vpc]
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
  vpc_cidr                  = module.vpc.vpc_cidr
  public_subnet_ids         = module.vpc.public_subnet_ids
  cluster_security_group_id = module.eks.eks_cluster_security_group_id
  observe_allowed_cidrs     = local.observe_allowed_cidrs_resolved

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
# volunteer-env), com os valores reais desta região (RDS restaurado, fila
# SQS nova, mesma tabela DynamoDB).
module "secrets" {
  source = "../terra/modules/secrets"

  name_prefix         = var.name_prefix
  rds_connection_url  = module.rds.rds_connection_url
  rds_password        = var.db_password
  sqs_queue_url       = module.sqs.sqs_queue_url
  dynamodb_table_name = var.dynamodb_table_name
  k8s_namespace       = kubernetes_namespace_v1.solidarytech.metadata[0].name
  aws_region          = var.aws_region

  depends_on = [module.rds, module.sqs, kubernetes_namespace_v1.solidarytech]
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

  namespace        = kubernetes_namespace_v1.observe.metadata[0].name
  target_group_arn = module.nlb.observe_target_group_arns["loki"]

  depends_on = [kubernetes_namespace_v1.observe, module.nlb, module.lb]
}

module "tempo" {
  source = "../terra/modules/tempo"

  namespace        = kubernetes_namespace_v1.observe.metadata[0].name
  target_group_arn = module.nlb.observe_target_group_arns["tempo"]

  depends_on = [kubernetes_namespace_v1.observe, module.nlb, module.lb]
}

module "prometheus" {
  source = "../terra/modules/prometheus"

  namespace        = kubernetes_namespace_v1.observe.metadata[0].name
  target_group_arn = module.nlb.observe_target_group_arns["prometheus"]

  depends_on = [kubernetes_namespace_v1.observe, module.nlb, module.lb]
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
# acoplar os dois states.
resource "aws_route53_health_check" "secondary" {
  count = var.route53_zone_id == "" ? 0 : 1

  fqdn              = module.nlb.nlb_dns_name
  port              = 8081
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
