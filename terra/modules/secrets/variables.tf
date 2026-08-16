variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

# Prefixo hierárquico dos parâmetros no SSM Parameter Store, ex.: /solidarytech/aws/rds/connection_url
variable "path_prefix" {
  description = "Prefixo de caminho dos parâmetros no SSM"
  type        = string
  default     = "/solidarytech/aws"
}

variable "rds_connection_url" {
  description = "URL completa de conexão PostgreSQL (output do módulo rds)"
  type        = string
  sensitive   = true
}

variable "rds_password" {
  description = "Senha do usuário master do RDS (output/variável do módulo rds)"
  type        = string
  sensitive   = true
}

variable "sqs_queue_url" {
  description = "URL da fila SQS (output do módulo sqs)"
  type        = string
}

variable "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB (output do módulo dynamo)"
  type        = string
}

# Namespace/região usados pelos Secrets Kubernetes ngo-env/donation-env/volunteer-env
variable "k8s_namespace" {
  description = "Namespace Kubernetes onde os Secrets ngo-env/donation-env/volunteer-env são criados (já deve existir - ver kubernetes_namespace_v1.solidarytech em terra/main.tf)"
  type        = string
}

variable "aws_region" {
  description = "Região da AWS, usada em AWS_REGION nos Secrets donation-env/volunteer-env"
  type        = string
}
