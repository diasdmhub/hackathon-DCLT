variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "vpc_id" {
  description = "ID da VPC (output do módulo vpc)"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs das subnets públicas onde a NLB é provisionada (output do módulo vpc)"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Security Group do cluster EKS, compartilhado por nodes/pods (output do módulo eks) - recebe a regra de ingress liberando as 3 portas para a NLB"
  type        = string
}

variable "observe_allowed_cidrs" {
  description = "CIDRs autorizados a alcançar Loki/Tempo/Prometheus (observe-aws/) pela NLB. Diferente das 3 portas de aplicação (0.0.0.0/0): esses backends não têm autenticação própria, então o ingress fica restrito a esta lista (ex.: o IP público de onde o Grafana externo consulta) em vez de aberto à internet."
  type        = list(string)
}
