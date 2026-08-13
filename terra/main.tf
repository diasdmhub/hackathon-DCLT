# VPC (base de rede)
module "vpc" {
  source = "./modules/vpc"

  name_prefix   = var.name_prefix
  subnet_prefix = var.subnet_prefix
  az_count      = var.az_count
}

# EKS - depende da VPC
module "eks" {
  source = "./modules/eks"

  name_prefix              = var.name_prefix
  private_subnet_ids       = module.vpc.private_subnet_ids
  kubernetes_version       = var.eks_kubernetes_version
  node_instance_types      = var.eks_node_instance_types
  node_desired_size        = var.eks_node_desired_size
  node_min_size            = var.eks_node_min_size
  node_max_size            = var.eks_node_max_size
  enable_prefix_delegation = var.eks_enable_prefix_delegation

  depends_on = [module.vpc]
}

# RDS - depende da VPC
module "rds" {
  source = "./modules/rds"

  name_prefix        = var.name_prefix
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  instance_class     = var.rds_instance_class
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids

  depends_on = [module.vpc]
}

# Módulos independentes (não dependem de VPC/EKS)
module "sqs" {
  source = "./modules/sqs"

  name_prefix = var.name_prefix
  queue_name  = var.sqs_queue_name
}

module "dynamo" {
  source = "./modules/dynamo"

  name_prefix = var.name_prefix
  table_name  = var.dynamodb_table_name
}

# IAM/IRSA - depende do OIDC provider do EKS e dos ARNs de SQS/DynamoDB
module "iam" {
  source = "./modules/iam"

  name_prefix               = var.name_prefix
  oidc_provider_arn         = module.eks.eks_oidc_provider_arn
  oidc_provider_url         = module.eks.eks_oidc_provider_url
  namespace                 = var.k8s_namespace
  donation_service_account  = var.donation_service_account
  volunteer_service_account = var.volunteer_service_account
  sqs_queue_arn             = module.sqs.sqs_queue_arn
  dynamodb_table_arn        = module.dynamo.dynamodb_table_arn

  depends_on = [module.eks, module.sqs, module.dynamo]
}

# NLB única compartilhada pelos 3 microsserviços - depende da VPC (subnets
# públicas) e do EKS (Security Group do cluster). Ver terra/modules/nlb e
# kube-aws/README.md.
module "nlb" {
  source = "./modules/nlb"

  name_prefix               = var.name_prefix
  vpc_id                    = module.vpc.vpc_id
  vpc_cidr                  = module.vpc.vpc_cidr
  public_subnet_ids         = module.vpc.public_subnet_ids
  cluster_security_group_id = module.eks.eks_cluster_security_group_id
  observe_allowed_cidrs     = local.observe_allowed_cidrs_resolved

  depends_on = [module.vpc, module.eks]
}

# IAM/IRSA do AWS Load Balancer Controller - depende do OIDC provider do EKS.
# Nome "lb-iam" (não "lb-controller"): este módulo só cuida da role IRSA, o
# controller em si (lado Kubernetes) é o módulo "lb" abaixo.
module "lb_iam" {
  source = "./modules/lb-iam"

  name_prefix       = var.name_prefix
  oidc_provider_arn = module.eks.eks_oidc_provider_arn
  oidc_provider_url = module.eks.eks_oidc_provider_url
  namespace         = var.lb_controller_namespace
  service_account   = var.lb_controller_service_account

  depends_on = [module.eks]
}

# AWS Load Balancer Controller em si (ServiceAccount + HelmRelease) - antes
# em lb-controller/ via Flux, movido para o Terraform pelo mesmo motivo do
# resto da observabilidade (ver terra/README.md). Só a role IRSA
# (module.lb_iam acima) continua um módulo separado.
module "lb" {
  source = "./modules/lb"

  namespace       = var.lb_controller_namespace
  service_account = var.lb_controller_service_account
  role_arn        = module.lb_iam.role_arn
  cluster_name    = module.eks.eks_cluster_name
  aws_region      = var.aws_region

  depends_on = [module.eks, module.lb_iam]
}

# module.lb_controller foi renomeado para module.lb_iam (mesmo recurso,
# nome mais preciso: este módulo só provisiona a role IRSA, não o
# controller em si) - moved block evita destroy/recreate da role já
# aplicada em contas AWS reais.
moved {
  from = module.lb_controller
  to   = module.lb_iam
}

# Secrets (SSM Parameter Store) - depende dos valores gerados por rds/sqs/dynamo
module "secrets" {
  source = "./modules/secrets"

  name_prefix         = var.name_prefix
  rds_connection_url  = module.rds.rds_connection_url
  rds_password        = var.db_password
  sqs_queue_url       = module.sqs.sqs_queue_url
  dynamodb_table_name = module.dynamo.dynamodb_table_name

  depends_on = [module.rds, module.sqs, module.dynamo]
}

# Observabilidade e métricas de infraestrutura, aplicadas direto pelo
# Terraform (providers helm/kubernetes/kubectl) em vez do FluxCD - ver
# "Observabilidade via Terraform" em terra/README.md para o porquê. Só os
# microsserviços (kube-aws/) e o AWS Load Balancer Controller
# (lb-controller/) continuam sob Flux.
resource "kubernetes_namespace_v1" "observe" {
  metadata {
    name = "observe"
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }

  depends_on = [module.eks]
}

module "zabbix" {
  source = "./modules/zabbix"

  name_prefix        = var.name_prefix
  zabbix_hostname    = var.zabbix_hostname
  zabbix_server_host = var.zabbix_server_host
  zabbix_version     = var.zabbix_version

  depends_on = [module.eks]
}

# loki/tempo/prometheus dependem de module.lb (não só do namespace/nlb):
# seus recursos TargetGroupBinding (kubectl_manifest) exigem o CRD que o
# AWS Load Balancer Controller instala - com essa dependência explícita no
# grafo do Terraform, um único `terraform apply` já basta (o controller é
# criado antes desses TargetGroupBinding, sem depender do Flux ou de um
# segundo apply) - ver terra/README.md.
module "loki" {
  source = "./modules/loki"

  namespace        = kubernetes_namespace_v1.observe.metadata[0].name
  target_group_arn = module.nlb.observe_target_group_arns["loki"]

  depends_on = [kubernetes_namespace_v1.observe, module.nlb, module.lb]
}

module "tempo" {
  source = "./modules/tempo"

  namespace        = kubernetes_namespace_v1.observe.metadata[0].name
  target_group_arn = module.nlb.observe_target_group_arns["tempo"]

  depends_on = [kubernetes_namespace_v1.observe, module.nlb, module.lb]
}

module "prometheus" {
  source = "./modules/prometheus"

  namespace        = kubernetes_namespace_v1.observe.metadata[0].name
  target_group_arn = module.nlb.observe_target_group_arns["prometheus"]

  depends_on = [kubernetes_namespace_v1.observe, module.nlb, module.lb]
}

# Alloy só depende do namespace (sem TargetGroupBinding - ver
# terra/modules/alloy).
module "alloy" {
  source = "./modules/alloy"

  namespace = kubernetes_namespace_v1.observe.metadata[0].name

  depends_on = [kubernetes_namespace_v1.observe]
}
