variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "queue_name" {
  description = "Nome da fila SQS"
  type        = string
  default     = "donation-events"
}

variable "visibility_timeout_seconds" {
  description = "Timeout de visibilidade da mensagem"
  type        = number
  default     = 30
}

variable "message_retention_seconds" {
  description = "Tempo de retenção da mensagem na fila"
  type        = number
  default     = 345600 # 4 dias
}
