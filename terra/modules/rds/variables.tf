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

# Variáveis de Disaster Recovery (ver "Disaster Recovery" em terra/README.md)
#############################
variable "backup_retention_period" {
  description = "Dias de retenção de backup automatizado. Precisa ser > 0 para permitir a replicação cross-region de backups (aws_db_instance_automated_backups_replication, criado em terra/main.tf) usada pela estratégia de DR ativo-passivo - antes deste recurso, este módulo criava a instância com backup_retention_period = 0 (sem backups)."
  type        = number
  default     = 7
}

variable "restore_source_arn" {
  description = "ARN do backup automatizado replicado nesta região (aws_db_instance_automated_backups_replication) a partir do qual restaurar via restore_to_point_in_time, em vez de criar uma instância nova/vazia. null (padrão) = cria do zero, o comportamento normal do ambiente ativo (terra/). Definido apenas ao ativar o ambiente passivo em terra-dr/ - ver terra-dr/README.md para como descobrir esse ARN."
  type        = string
  default     = null
}
