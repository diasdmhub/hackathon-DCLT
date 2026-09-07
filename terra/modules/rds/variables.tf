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

variable "extra_ingress_cidrs" {
  description = "CIDRs adicionais liberados na porta 5432 do Security Group, além de var.vpc_cidr - usado para permitir tráfego vindo de uma VPC peered (ex.: a VPC de app de terra-dr/ alcançando, via peering, o replica hospedado por este módulo em terra/modules/dr-standby-vpc). Vazio ([], padrão) na instância primária do ambiente ativo."
  type        = list(string)
  default     = []
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

# Variáveis de Disaster Recovery (ver "Disaster Recovery" em terra/README.md)
#############################
variable "backup_retention_period" {
  description = "Dias de retenção de backup automatizado. Precisa ser > 0 tanto na instância primária (pré-requisito para criar réplicas a partir dela) quanto numa réplica que por sua vez sirva de origem a outra réplica (failback) - antes deste recurso, este módulo criava a instância com backup_retention_period = 0 (sem backups)."
  type        = number
  default     = 7
}

variable "replicate_source_db_arn" {
  description = "ARN da instância RDS de origem, para criar este recurso como read replica cross-region em vez de uma instância nova/vazia. null (padrão) = instância primária do ambiente ativo (terra/), criada do zero. Definido quando este módulo é instanciado como o replica sempre-vivo da estratégia de DR (terra/modules/dr-standby-vpc) ou, no failback, como o replica reverso criado de volta na região original - ver \"Disaster Recovery\" em terra/README.md."
  type        = string
  default     = null
}

variable "promote" {
  description = "Quando true (só tem efeito se replicate_source_db_arn != null), promove a réplica a instância standalone in-place, removendo replicate_source_db - é o mecanismo usado tanto para ativar o ambiente passivo quanto para o failback de volta ao ambiente ativo. Ignorado (instância sempre primária) quando replicate_source_db_arn é null."
  type        = bool
  default     = false
}
