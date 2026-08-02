variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

# Mantido igual ao nome já usado pelo volunteer-service e pelo dynamodb-init
# local (build/docker-compose.yaml e kube/030-dynamodb) para não exigir
# nenhuma mudança de código/env var ao migrar para a AWS.
variable "table_name" {
  description = "Nome da tabela DynamoDB"
  type        = string
  default     = "SolidaryTechVolunteers"
}

variable "hash_key" {
  description = "Partition key da tabela"
  type        = string
  default     = "volunteer_id"
}

# PROVISIONED com 5/5 fica dentro do always-free tier do DynamoDB (25 RCU +
# 25 WCU + 25GB de storage, sem limite de tempo, diferente do free tier de 12
# meses de outros serviços). PAY_PER_REQUEST não entra nesse always-free.
variable "read_capacity" {
  description = "Capacidade de leitura provisionada"
  type        = number
  default     = 5
}

variable "write_capacity" {
  description = "Capacidade de escrita provisionada"
  type        = number
  default     = 5
}
