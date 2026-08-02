# Parâmetros da camada Standard do SSM Parameter Store: sem custo por
# parâmetro nem por API call dentro do uso normal (diferente do Secrets
# Manager, que cobra por segredo/mês). SecureString usa a chave gerenciada
# padrão "alias/aws/ssm" (sem custo de KMS customizado).

resource "aws_ssm_parameter" "rds_connection_url" {
  name        = "${var.path_prefix}/rds/connection_url"
  description = "URL completa de conexão PostgreSQL (equivalente ao DATABASE_URL)"
  type        = "SecureString"
  value       = var.rds_connection_url
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-rds-connection-url" }
}

resource "aws_ssm_parameter" "rds_password" {
  name        = "${var.path_prefix}/rds/password"
  description = "Senha do usuário master do RDS"
  type        = "SecureString"
  value       = var.rds_password
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-rds-password" }
}

resource "aws_ssm_parameter" "sqs_queue_url" {
  name        = "${var.path_prefix}/sqs/queue_url"
  description = "URL da fila SQS de eventos de doação"
  type        = "String"
  value       = var.sqs_queue_url
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-sqs-queue-url" }
}

resource "aws_ssm_parameter" "dynamodb_table_name" {
  name        = "${var.path_prefix}/dynamodb/table_name"
  description = "Nome da tabela DynamoDB de voluntários"
  type        = "String"
  value       = var.dynamodb_table_name
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-dynamodb-table-name" }
}
