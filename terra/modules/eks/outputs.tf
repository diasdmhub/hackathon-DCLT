output "eks_cluster_name" {
  description = "Nome do cluster EKS"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Endpoint da API do cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_ca" {
  description = "Certificado CA do cluster (base64)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "eks_cluster_security_group_id" {
  description = "Security Group criado automaticamente pelo cluster"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "eks_oidc_provider_arn" {
  description = "ARN do OIDC provider do cluster (usado para IRSA)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "eks_oidc_provider_url" {
  description = "URL do OIDC provider do cluster, sem o esquema https:// (usado para IRSA)"
  value       = trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")
}

output "node_role_arn" {
  description = "ARN da IAM role usada pelos nodes do cluster"
  value       = aws_iam_role.nodes.arn
}
