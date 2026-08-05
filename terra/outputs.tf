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

output "lb_controller_outputs" {
  description = "Outputs do módulo lb-controller (ARN da role IRSA do AWS Load Balancer Controller)"
  value       = module.lb_controller
}

output "secrets_outputs" {
  description = "Outputs do módulo secrets (nomes dos parâmetros SSM)"
  value       = module.secrets
}

output "configure_kubectl" {
  description = "Comando para configurar o kubectl/aws-cli local contra o cluster criado"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.eks_cluster_name}"
}
