variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

# Segue a mesma convenção do Dockerfile-psql (build/): um único database
# ("sol_db") compartilhado pelas tabelas do ngo-service e do donation-service,
# em vez dos dois databases separados descritos no fluxo manual do README.
variable "db_name" {
  description = "Nome do database inicial no RDS"
  type        = string
  default     = "sol_db"
}

variable "db_username" {
  description = "Usuário master do PostgreSQL"
  type        = string
  default     = "sol"
}

variable "db_password" {
  description = "Senha do usuário master (defina via terraform.tfvars, não versionado)"
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  description = "ID da VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC (usado no Security Group)"
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs das subnets privadas"
  type        = list(string)
}

# db.t3.micro é elegível ao free tier (750h/mês nos primeiros 12 meses de conta nova).
variable "instance_class" {
  description = "Classe da instância RDS"
  type        = string
  default     = "db.t3.micro"
}

# 20 GiB é o limite do free tier de storage do RDS.
variable "allocated_storage" {
  description = "Armazenamento alocado (GiB)"
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "Versão major do PostgreSQL (mantida igual à imagem postgres:18-alpine usada em build/Dockerfile-psql)"
  type        = string
  default     = "18"
}
