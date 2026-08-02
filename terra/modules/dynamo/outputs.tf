output "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB"
  value       = aws_dynamodb_table.volunteers.name
}

output "dynamodb_table_arn" {
  description = "ARN da tabela DynamoDB"
  value       = aws_dynamodb_table.volunteers.arn
}
