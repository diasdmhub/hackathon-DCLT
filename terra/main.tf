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
  enable_prefix_delegation = var.enable_prefix_delegation

  depends_on = [module.vpc]
}

# RDS - depende da VPC
module "rds" {
  source = "./modules/rds"

  name_prefix             = var.name_prefix
  db_name                 = var.db_name
  db_username             = var.db_username
  db_password             = var.db_password
  instance_class          = var.rds_instance_class
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = module.vpc.vpc_cidr
  private_subnet_ids      = module.vpc.private_subnet_ids
  backup_retention_period = var.rds_backup_retention_period

  depends_on = [module.vpc]
}

# Replicação cross-region dos backups automatizados do RDS para a região do
# ambiente passivo (terra-dr/) - a peça "sempre viva" (e barata: só storage
# S3 dos backups) da estratégia de DR ativo-passivo. Não cria a instância
# RDS do ambiente passivo em si - isso só acontece quando terra-dr/ é
# aplicado, restaurando a partir do backup mais recente replicado aqui (ver
# aws_db_instance.restored em terra/modules/rds e terra-dr/README.md).
resource "aws_db_instance_automated_backups_replication" "dr" {
  count = var.enable_dr ? 1 : 0

  provider               = aws.dr
  source_db_instance_arn = module.rds.rds_arn

  depends_on = [module.rds]
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

  # Réplica contínua (Global Tables) na região do ambiente passivo - ver
  # "Disaster Recovery" em terra/README.md. terra-dr/ não cria seu próprio
  # module "dynamo": a tabela já existe nessa região como réplica desta.
  replica_regions = var.enable_dr ? [var.dr_aws_region] : []
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

# Namespace solidarytech - criado aqui (não pelo Flux) para que os Secrets
# ngo-env/donation-env/volunteer-env (module.secrets abaixo) possam ser
# aplicados no mesmo `terraform apply` que provisiona RDS/SQS/DynamoDB, sem
# depender do `flux bootstrap` já ter rodado. kube-aws/ não declara mais
# esse Namespace (removido de kube-aws/kustomization.yaml) para evitar dois
# donos do mesmo objeto - mesmo raciocínio de kubernetes_namespace_v1.observe
# abaixo.
resource "kubernetes_namespace_v1" "solidarytech" {
  metadata {
    name = var.k8s_namespace
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }

  depends_on = [module.eks]
}

# Secrets (SSM Parameter Store + Secrets Kubernetes ngo-env/donation-env/
# volunteer-env) - depende dos valores gerados por rds/sqs/dynamo e do
# namespace solidarytech já existir.
module "secrets" {
  source = "./modules/secrets"

  name_prefix         = var.name_prefix
  rds_connection_url  = module.rds.rds_connection_url
  rds_password        = var.db_password
  sqs_queue_url       = module.sqs.sqs_queue_url
  dynamodb_table_name = module.dynamo.dynamodb_table_name
  k8s_namespace       = kubernetes_namespace_v1.solidarytech.metadata[0].name
  aws_region          = var.aws_region

  depends_on = [module.rds, module.sqs, module.dynamo, kubernetes_namespace_v1.solidarytech]
}

# FluxCD (controladores + o GitRepository/Kustomization "solidarytech" de
# bootstrap) instalado via Helm em vez de `flux install` + `kubectl apply -f`
# manual - reduz a passos manuais tanto a implementação inicial quanto
# atualizações futuras (nova versão do Flux, ou mudança de url/branch/path/
# interval nesses dois objetos) a um único `terraform apply`, no mesmo
# padrão do resto deste diretório - ver "FluxCD via Terraform" em
# terra/README.md. O YAML aplicado é o mesmo já versionado em
# clusters/eks-aws/ (lido abaixo via file(), única fonte de verdade) - isso
# não muda a decisão de não autogerenciar o Flux via `flux bootstrap` (ver
# clusters/eks-aws/flux-system/gotk-sync.yaml), só a forma como os
# controladores e esses dois objetos chegam no cluster.
locals {
  flux_git_repository_yaml = file("${path.module}/../clusters/eks-aws/flux-system/gotk-sync.yaml")
  flux_kustomization_yaml  = file("${path.module}/../clusters/eks-aws/solidarytech-kustomization.yaml")
}

module "flux" {
  source = "./modules/flux"

  chart_version              = var.flux_chart_version
  git_repository_yaml        = local.flux_git_repository_yaml
  kustomization_yaml         = local.flux_kustomization_yaml
  donation_service_role_arn  = module.iam.donation_service_role_arn
  volunteer_service_role_arn = module.iam.volunteer_service_role_arn

  # module.lb: o CRD TargetGroupBinding usado pelos manifests de ./kube-aws
  # (reconciliados pela Kustomization aplicada aqui) precisa existir antes -
  # mesmo raciocínio de terra/modules/{loki,tempo,prometheus}. module.secrets
  # e kubernetes_namespace_v1.solidarytech: a Kustomization espera que o
  # namespace e os Secrets ngo-env/donation-env/volunteer-env já existam
  # (ver kube-aws/README.md).
  depends_on = [module.eks, module.lb, module.iam, kubernetes_namespace_v1.solidarytech, module.secrets]
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

  grafana_cloud_remote_write_url = var.grafana_cloud_remote_write_url
  grafana_cloud_username         = var.grafana_cloud_username
  grafana_cloud_api_key          = var.grafana_cloud_api_key

  depends_on = [kubernetes_namespace_v1.observe, module.nlb, module.lb]
}

# Alloy só depende do namespace (sem TargetGroupBinding - ver
# terra/modules/alloy).
module "alloy" {
  source = "./modules/alloy"

  namespace = kubernetes_namespace_v1.observe.metadata[0].name

  depends_on = [kubernetes_namespace_v1.observe]
}

# Hosted zone + failover DNS da estratégia de DR ativo-passivo (ver
# "Disaster Recovery" em terra/README.md). Só o registro PRIMARY e a zone em
# si vivem aqui - terra-dr/ cria o registro SECONDARY + seu próprio health
# check, referenciando esta zone por ID (var.route53_zone_id em
# terra-dr/terraform.tfvars, copiado do output route53_zone_id abaixo) em
# vez de terraform_remote_state, para não acoplar os dois states.
resource "aws_route53_zone" "dr" {
  count = var.manage_dns ? 1 : 0
  name  = var.dns_zone_name

  tags = { Name = "${var.name_prefix}-dr-zone" }
}

# Health check HTTP no /health do ngo-service (porta 8081) como
# representante de "esta região está servindo tráfego" - mesmo endpoint já
# usado pelo smoke-test (build/scripts/smoke-test.sh) e pelos
# readiness/liveness probes dos Deployments. Aponta para o donation-service
# (porta 8082), o hot path da plataforma, em vez do ngo-service.
resource "aws_route53_health_check" "primary" {
  count = var.manage_dns ? 1 : 0

  fqdn              = module.nlb.nlb_dns_name
  port              = 8082
  type              = "HTTP"
  resource_path     = "/health"
  request_interval  = 30
  failure_threshold = 3

  tags = { Name = "${var.name_prefix}-primary-health" }
}

resource "aws_route53_record" "primary" {
  count = var.manage_dns ? 1 : 0

  zone_id = aws_route53_zone.dr[0].zone_id
  name    = var.dns_record_name
  type    = "CNAME"
  ttl     = 30
  records = [module.nlb.nlb_dns_name]

  set_identifier = "primary"
  failover_routing_policy {
    type = "PRIMARY"
  }
  health_check_id = aws_route53_health_check.primary[0].id
}
