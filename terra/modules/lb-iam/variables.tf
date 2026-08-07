variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN do OIDC provider do cluster EKS (output do módulo eks)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL do OIDC provider do cluster EKS, sem https:// (output do módulo eks)"
  type        = string
}

# Assim como donation-service/volunteer-service em terra/modules/iam, esta
# role IRSA precisa de uma ServiceAccount Kubernetes com o mesmo
# namespace/nome e a anotação eks.amazonaws.com/role-arn - ver
# terra/modules/lb, que cria essa ServiceAccount.
variable "namespace" {
  description = "Namespace Kubernetes onde o AWS Load Balancer Controller roda"
  type        = string
  default     = "kube-system"
}

variable "service_account" {
  description = "Nome da ServiceAccount do AWS Load Balancer Controller"
  type        = string
  default     = "aws-load-balancer-controller"
}
