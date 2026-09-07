output "vpc_outputs" {
  description = "Outputs do módulo vpc"
  value       = module.vpc
}

output "eks_outputs" {
  description = "Outputs do módulo eks"
  value       = module.eks
}

output "rds_outputs" {
  description = "Outputs do módulo rds"
  value       = module.rds
  sensitive   = true
}

output "dynamo_outputs" {
  description = "Outputs do módulo dynamo"
  value       = module.dynamo
}

output "sqs_outputs" {
  description = "Outputs do módulo sqs"
  value       = module.sqs
}

output "iam_outputs" {
  description = "Outputs do módulo iam (ARNs das roles IRSA)"
  value       = module.iam
}

output "nlb_outputs" {
  description = "Outputs do módulo nlb (DNS/ARN da NLB e ARN do target group de cada serviço)"
  value       = module.nlb
}

output "nlb_dns_name" {
  description = "DNS name da NLB única compartilhada pelos 3 serviços - atalho de nlb_outputs.nlb_dns_name, para uso direto com `terraform output -raw` (ver doc/roteiro-cluster-aws.md)"
  value       = module.nlb.nlb_dns_name
}

output "lb_iam_outputs" {
  description = "Outputs do módulo lb-iam (ARN da role IRSA do AWS Load Balancer Controller)"
  value       = module.lb_iam
}

output "secrets_outputs" {
  description = "Outputs do módulo secrets (nomes dos parâmetros SSM)"
  value       = module.secrets
}

output "route53_zone_id" {
  description = "Zone ID da hosted zone Route53 (existe só quando var.manage_dns = true) - copiar para route53_zone_id em terra-dr/terraform.tfvars, para o registro SECONDARY de failover do ambiente passivo."
  value       = var.manage_dns ? aws_route53_zone.dr[0].zone_id : null
}

output "route53_name_servers" {
  description = "Nameservers da hosted zone Route53 (existe só quando var.manage_dns = true) - cadastrar como registros NS do subdomínio var.dns_zone_name no provedor DNS do domínio raiz, para delegar a resolução a esta zone."
  value       = var.manage_dns ? aws_route53_zone.dr[0].name_servers : null
}

output "dr_standby_vpc_id" {
  description = "ID da VPC mínima do read replica sempre-vivo do RDS (module.dr_standby_vpc, só existe quando var.enable_dr = true) - copiar para rds_dr_vpc_id em terra-dr/terraform.tfvars na ativação, para o VPC peering. Ver \"Disaster Recovery\" em terra/README.md."
  value       = var.enable_dr ? module.dr_standby_vpc[0].vpc_id : null
}

output "dr_standby_vpc_cidr" {
  description = "CIDR da VPC mínima do read replica sempre-vivo - copiar para rds_dr_vpc_cidr em terra-dr/terraform.tfvars na ativação."
  value       = var.enable_dr ? module.dr_standby_vpc[0].vpc_cidr : null
}

output "dr_replica_connection_url" {
  description = "URL de conexão Postgres do read replica sempre-vivo (module.rds_dr_replica, só existe quando var.enable_dr = true) - só fica utilizável de fato depois de promovido (var.promote_dr_db = true, ver o runbook de ativação em terra-dr/README.md). Copiar para rds_dr_connection_url em terra-dr/terraform.tfvars."
  value       = var.enable_dr ? module.rds_dr_replica[0].rds_connection_url : null
  sensitive   = true
}

output "configure_kubectl" {
  description = "Comando para configurar o kubectl/aws-cli local contra o cluster criado"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.eks_cluster_name}"
}
