resource "aws_db_subnet_group" "rds" {
  name       = "${var.name_prefix}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name_prefix}-rds-subnet-group" }
}

# Permite tráfego na porta 5432 a partir da própria VPC (nodes do EKS) e,
# quando este módulo hospeda uma réplica/instância promovida alcançada via
# VPC peering (ver terra/modules/dr-standby-vpc e "Disaster Recovery" em
# terra/README.md), a partir dos CIDRs extras em var.extra_ingress_cidrs.
resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Security Group para o RDS PostgreSQL"
  vpc_id      = var.vpc_id

  ingress {
    description = "Acesso ao PostgreSQL a partir da VPC - nodes do EKS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = var.extra_ingress_cidrs
    content {
      description = "Acesso adicional ao PostgreSQL - ex. VPC de app alcancada via peering"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-rds-sg" }
}

# Um único recurso, reutilizado nos 3 papéis da estratégia de DR (ver
# "Disaster Recovery" em terra/README.md):
#   - var.replicate_source_db_arn == null: instância primária, criada do
#     zero (papel do ambiente ativo, terra/, no dia a dia).
#   - var.replicate_source_db_arn != null && !var.promote: read replica
#     cross-region, sempre viva (papel "sempre-on" do módulo
#     terra/modules/dr-standby-vpc). engine/db_name/username/password/
#     allocated_storage ficam null: um replica sempre herda esses valores
#     da origem, mesmo depois de promovido.
#   - var.replicate_source_db_arn != null && var.promote: mesmo recurso,
#     mas sem replicate_source_db - o provider Terraform interpreta essa
#     mudança como uma promoção in-place (ModifyDBInstance), não um
#     destroy/recreate. É o mecanismo usado tanto na ativação do ambiente
#     passivo quanto no failback de volta ao ambiente ativo.
resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-rds-psql"

  engine         = var.replicate_source_db_arn == null ? "postgres" : null
  engine_version = var.replicate_source_db_arn == null ? var.engine_version : null
  db_name        = var.replicate_source_db_arn == null ? var.db_name : null
  username       = var.replicate_source_db_arn == null ? var.db_username : null
  password       = var.replicate_source_db_arn == null ? var.db_password : null

  allocated_storage     = var.replicate_source_db_arn == null ? var.allocated_storage : null
  max_allocated_storage = null

  replicate_source_db = var.promote ? null : var.replicate_source_db_arn

  instance_class = var.instance_class
  storage_type   = "gp3"

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az = false

  # backup_retention_period > 0 também numa réplica: além de ser
  # pré-requisito para a replicação cross-region em si, uma réplica com
  # backup próprio pode por sua vez servir de origem para uma nova réplica
  # (usado no failback - ver terra-dr/README.md).
  backup_retention_period      = var.backup_retention_period
  skip_final_snapshot          = true
  performance_insights_enabled = false

  tags = { Name = "${var.name_prefix}-rds-psql" }

  depends_on = [aws_db_subnet_group.rds, aws_security_group.rds]
}
