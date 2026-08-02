# Busca as AZs disponíveis na região
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  vpc_cidr = "${var.subnet_prefix}.0.0/16"

  # Limita a quantidade de AZs usadas para reduzir custo (menos subnets/rotas),
  # respeitando o mínimo de 2 exigido pelo control plane do EKS.
  az_count = max(2, min(length(data.aws_availability_zones.available.names), var.az_count))
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  public_subnet_cidrs = [
    for i in range(local.az_count) :
    "${var.subnet_prefix}.${var.public_subnet_nums[i]}.0/24"
  ]

  private_subnet_cidrs = [
    for i in range(local.az_count) :
    "${var.subnet_prefix}.${var.private_subnet_nums[i]}.0/24"
  ]

  # Nome do cluster EKS, usado apenas para as tags de descoberta de subnets.
  # Precisa ser mantido em sincronia com o nome gerado pelo módulo eks.
  eks_cluster_name = "${var.name_prefix}-eks-cluster"
}

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                              = "${var.name_prefix}-subnet-pub-${var.public_subnet_nums[count.index]}"
    Tier                                              = "public"
    "kubernetes.io/role/elb"                          = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                                              = "${var.name_prefix}-subnet-priv-${var.private_subnet_nums[count.index]}"
    Tier                                              = "private"
    "kubernetes.io/role/internal-elb"                 = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-public-rtb"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private-rtb"
  }
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Um único NAT Gateway (não um por AZ) para manter custo mínimo. Ponto único
# de saída para as subnets privadas; aceitável para o volume deste ambiente.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.name_prefix}-nat-gw"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route" "private_internet_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
