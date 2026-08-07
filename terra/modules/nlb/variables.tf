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
  description = "CIDRs autorizados a alcançar Loki/Tempo/Prometheus (terra/modules/{loki,tempo,prometheus}) pela NLB. Diferente das 3 portas de aplicação (0.0.0.0/0): esses backends não têm autenticação própria, então o ingress fica restrito a esta lista (ex.: o IP público de onde o Grafana externo consulta) em vez de aberto à internet."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR da VPC (output do módulo vpc) - liberado à parte nas portas de observabilidade só para o health check da própria NLB, que não vem de observe_allowed_cidrs (o IP do Grafana externo), e sim de dentro da VPC (ver comentário em nlb.tf)."
  type        = string
}
