variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "subnet_prefix" {
  description = "Os 2 primeiros octetos do CIDR desta VPC (ex.: \"10.95\") - distinto tanto do ambiente ativo (10.80) quanto da VPC de app do ambiente passivo (10.90, terra-dr/), para não colidir quando as duas forem conectadas via VPC peering na ativação"
  type        = string
}

variable "az_count" {
  description = "Quantidade de AZs (mínimo 2, exigido por um DB subnet group multi-AZ)"
  type        = number
  default     = 2
}

variable "private_subnet_nums" {
  description = "O terceiro octeto para as subnets privadas - um por AZ"
  type        = list(number)
  default     = [12, 22]
}
