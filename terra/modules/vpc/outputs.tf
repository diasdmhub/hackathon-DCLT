output "vpc_id" {
  description = "ID da VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "Bloco CIDR da VPC"
  value       = local.vpc_cidr
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas"
  value       = aws_subnet.private[*].id
}
