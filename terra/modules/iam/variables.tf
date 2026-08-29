variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN do OIDC provider do cluster EKS (output do módulo eks)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL do OIDC provider do cluster EKS, sem https:// (output do módulo eks)"
  type        = string
}

# Estas roles usam IRSA: precisam ser associadas a uma ServiceAccount do
# Kubernetes com o mesmo namespace/nome e a anotação
# `eks.amazonaws.com/role-arn`. Isso ainda não existe em kube/ hoje (os pods
# usam a ServiceAccount "default" e credenciais estáticas fake via Secret) -
# é um ajuste pendente em kube/ ao apontar o Flux para este cluster.
variable "namespace" {
  description = "Namespace Kubernetes onde os serviços rodam"
  type        = string
  default     = "solidarytech"
}

variable "donation_service_account" {
  description = "Nome da ServiceAccount do donation-service"
  type        = string
  default     = "donation-service"
}

variable "volunteer_service_account" {
  description = "Nome da ServiceAccount do volunteer-service"
  type        = string
  default     = "volunteer-service"
}

variable "sqs_queue_arn" {
  description = "ARN da fila SQS (output do módulo sqs)"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN da tabela DynamoDB (output do módulo dynamo)"
  type        = string
}

variable "role_name_suffix" {
  description = "Sufixo aplicado ao nome das IAM roles IRSA. Diferente da maioria dos recursos deste repositório (escopados por região, sem risco de colisão entre terra/ e terra-dr/ na mesma conta AWS), nomes de IAM role são um namespace global por conta - por isso terra-dr/ define este valor (ex.: \"-dr\") para não colidir com a role já criada pelo ambiente ativo com o mesmo name_prefix. Vazio (padrão) no ambiente ativo."
  type        = string
  default     = ""
}
