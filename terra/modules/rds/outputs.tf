output "rds_address" {
  description = "Hostname do RDS (sem porta)"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  description = "Porta do RDS"
  value       = aws_db_instance.this.port
}

output "rds_endpoint" {
  description = "Endpoint do RDS (hostname:porta)"
  value       = aws_db_instance.this.endpoint
}

output "rds_arn" {
  description = "ARN da instância RDS - usado como replicate_source_db_arn de uma réplica cross-region (ver terra/modules/dr-standby-vpc e terra/main.tf, estratégia de DR)"
  value       = aws_db_instance.this.arn
}

output "rds_connection_url" {
  # Uma réplica/instância promovida (replicate_source_db_arn != null) herda
  # usuário/senha da origem - var.db_password não os define nesse caminho,
  # então em terra-dr/terraform.tfvars ela precisa ser IGUAL à senha real do
  # ambiente ativo para esta URL sair correta (ver terra-dr/README.md).
  description = "URL completa de conexão PostgreSQL (equivalente ao DATABASE_URL usado pelos serviços)"
  value       = "postgresql://${var.db_username}:${var.db_password}@${aws_db_instance.this.endpoint}/${var.db_name}"
  sensitive   = true
}

output "rds_security_group_id" {
  description = "ID do Security Group do RDS"
  value       = aws_security_group.rds.id
}
