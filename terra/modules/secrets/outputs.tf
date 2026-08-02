output "rds_connection_url_parameter_name" {
  description = "Nome do parâmetro SSM com a URL de conexão do RDS"
  value       = aws_ssm_parameter.rds_connection_url.name
}

output "sqs_queue_url_parameter_name" {
  description = "Nome do parâmetro SSM com a URL da fila SQS"
  value       = aws_ssm_parameter.sqs_queue_url.name
}

output "dynamodb_table_name_parameter_name" {
  description = "Nome do parâmetro SSM com o nome da tabela DynamoDB"
  value       = aws_ssm_parameter.dynamodb_table_name.name
}
