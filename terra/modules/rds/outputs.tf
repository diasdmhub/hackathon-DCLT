output "rds_address" {
  description = "Hostname do RDS (sem porta)"
  value       = local.db_instance.address
}

output "rds_port" {
  description = "Porta do RDS"
  value       = local.db_instance.port
}

output "rds_endpoint" {
  description = "Endpoint do RDS (hostname:porta)"
  value       = local.db_instance.endpoint
}

output "rds_arn" {
  description = "ARN da instância RDS - usado como source_db_instance_arn de aws_db_instance_automated_backups_replication (ver terra/main.tf, estratégia de DR)"
  value       = local.db_instance.arn
}

output "rds_connection_url" {
  # Um restore (aws_db_instance.restored) herda usuário/senha do backup de
  # origem - var.db_password não os define nesse caminho, então em
  # terra-dr/terraform.tfvars ela precisa ser IGUAL à senha real do ambiente
  # ativo para esta URL sair correta (ver terra-dr/README.md).
  description = "URL completa de conexão PostgreSQL (equivalente ao DATABASE_URL usado pelos serviços)"
  value       = "postgresql://${var.db_username}:${var.db_password}@${local.db_instance.endpoint}/${var.db_name}"
  sensitive   = true
}

output "rds_security_group_id" {
  description = "ID do Security Group do RDS"
  value       = aws_security_group.rds.id
}
