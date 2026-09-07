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

output "private_route_table_id" {
  description = "ID da route table privada - usado em terra-dr/main.tf para adicionar a rota de VPC peering até a VPC mínima do replica do RDS (terra/modules/dr-standby-vpc), na ativação do ambiente passivo (ver \"Disaster Recovery\" em terra/README.md)"
  value       = aws_route_table.private.id
}

output "nat_gateway_public_ip" {
  description = "Elastic IP do NAT Gateway - IP de origem visto externamente para todo tráfego de saída de pods em subnet privada; usado para liberar esse IP em firewalls/NAT fora da AWS"
  value       = aws_eip.nat.public_ip
}
