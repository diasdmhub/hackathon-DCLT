output "vpc_id" {
  description = "ID da VPC mínima do replica"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "Bloco CIDR da VPC mínima do replica"
  value       = local.vpc_cidr
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas (usadas pelo DB subnet group do replica em terra/modules/rds)"
  value       = aws_subnet.private[*].id
}

output "private_route_table_id" {
  description = "ID da route table privada - usado para adicionar a rota de volta ao peering com a VPC de app de terra-dr/ na ativação (ver var.dr_app_vpc_peering_connection_id em terra/variables.tf)"
  value       = aws_route_table.private.id
}
