variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "subnet_prefix" {
  description = "Os 2 primeiros octetos do CIDR da VPC (ex.: \"10.80\")"
  type        = string
}

variable "az_count" {
  description = "Quantidade de AZs a usar (mínimo 2, exigido pelo control plane do EKS). Mantido baixo para reduzir o número de subnets/rotas."
  type        = number
  default     = 2
}

variable "public_subnet_nums" {
  description = "O terceiro octeto para subnets públicas - um por AZ"
  type        = list(number)
  default     = [11, 21]
}

variable "private_subnet_nums" {
  description = "O terceiro octeto para subnets privadas - um por AZ"
  type        = list(number)
  default     = [12, 22]
}
