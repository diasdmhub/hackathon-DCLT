variable "namespace" {
  description = "Namespace Kubernetes onde o AWS Load Balancer Controller roda"
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Nome da ServiceAccount do AWS Load Balancer Controller (precisa bater com a trust policy da role IRSA em terra/modules/lb-iam)"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "role_arn" {
  description = "ARN da role IRSA do AWS Load Balancer Controller (output role_arn do módulo lb-iam)"
  type        = string
}

variable "cluster_name" {
  description = "Nome do cluster EKS (output eks_cluster_name do módulo eks) - vira o valor clusterName do chart"
  type        = string
}

variable "aws_region" {
  description = "Região AWS do cluster - vira o valor region do chart"
  type        = string
}
