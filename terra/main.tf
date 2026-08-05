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
  public_subnet_ids         = module.vpc.public_subnet_ids
  cluster_security_group_id = module.eks.eks_cluster_security_group_id

  depends_on = [module.vpc, module.eks]
}

# IAM/IRSA do AWS Load Balancer Controller - depende do OIDC provider do EKS
module "lb_controller" {
  source = "./modules/lb-controller"

  name_prefix       = var.name_prefix
  oidc_provider_arn = module.eks.eks_oidc_provider_arn
  oidc_provider_url = module.eks.eks_oidc_provider_url
  namespace         = var.lb_controller_namespace
  service_account   = var.lb_controller_service_account

  depends_on = [module.eks]
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
