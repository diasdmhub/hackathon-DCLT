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

output "dynamodb_table_arn" {
  description = "ARN da tabela DynamoDB nesta região (réplica da Global Table do ambiente ativo - não gerenciada por este state, ver local.dynamodb_table_arn em main.tf)"
  value       = local.dynamodb_table_arn
}

output "sqs_outputs" {
  description = "Outputs do módulo sqs"
  value       = module.sqs
}

output "iam_outputs" {
  description = "Outputs do módulo iam (ARNs das roles IRSA desta região - usar no Secret irsa-role-arns de clusters/eks-aws-dr/flux-system)"
  value       = module.iam
}

output "nlb_outputs" {
  description = "Outputs do módulo nlb (DNS/ARN da NLB e ARN do target group de cada serviço)"
  value       = module.nlb
}

output "nlb_dns_name" {
  description = "DNS name da NLB única compartilhada pelos 3 serviços - atalho de nlb_outputs.nlb_dns_name, para uso direto com `terraform output -raw` (mesmo padrão de terra/outputs.tf)"
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

output "configure_kubectl" {
  description = "Comando para configurar o kubectl/aws-cli local contra o cluster do ambiente passivo"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.eks_cluster_name}"
}
