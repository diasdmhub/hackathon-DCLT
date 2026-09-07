# VPC mínima, sempre ativa, só para hospedar o read replica cross-region do
# RDS (terra/modules/rds instanciado com replicate_source_db_arn) na
# estratégia de DR ativo-passivo - ver "Disaster Recovery" em
# terra/README.md. Sem Internet Gateway/NAT Gateway: a replicação do RDS
# trafega pelo canal interno gerenciado da AWS, não pela internet da VPC
# (ver a nota sobre USER_ReadRepl.XRgn.html em terra/README.md) - só o
# tráfego de aplicação (EKS de terra-dr/, depois de ativado) alcança esta
# VPC via peering, não a internet.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  vpc_cidr = "${var.subnet_prefix}.0.0/16"

  az_count = max(2, min(length(data.aws_availability_zones.available.names), var.az_count))
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  private_subnet_cidrs = [
    for i in range(local.az_count) :
    "${var.subnet_prefix}.${var.private_subnet_nums[i]}.0/24"
  ]
}

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-dr-standby-vpc" }
}

resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.name_prefix}-dr-standby-subnet-${var.private_subnet_nums[count.index]}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-dr-standby-private-rtb" }
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
