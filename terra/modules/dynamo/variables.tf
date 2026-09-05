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
  description = "Capacidade de escrita provisionada (também o mínimo do auto scaling, quando há réplica - ver write_capacity_max)"
  type        = number
  default     = 5
}

# Teto do auto scaling de WriteCapacityUnits, exigido pela AWS para Global
# Tables (v2) com billing PROVISIONED - ver comentário em dynamo.tf. 10
# mantém folga sobre os 5 WCU normais sem chegar perto do teto do always-free
# tier (25 WCU/conta/região).
variable "write_capacity_max" {
  description = "Teto do auto scaling de capacidade de escrita (só usado quando há réplica, ver replica_regions)"
  type        = number
  default     = 10
}

# Variável de Disaster Recovery (ver "Disaster Recovery" em terra/README.md)
#############################
variable "replica_regions" {
  description = "Regiões AWS onde criar uma réplica desta tabela via DynamoDB Global Tables (v2). Usado só pelo ambiente ativo (terra/), para manter a tabela de voluntários replicada continuamente na região do ambiente passivo - terra-dr/ não instancia este módulo, só referencia a tabela já existente (mesmo nome) por lá. Vazio ([], padrão) = tabela sem réplica, comportamento anterior."
  type        = list(string)
  default     = []
}
