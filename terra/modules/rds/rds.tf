resource "aws_db_subnet_group" "rds" {
  name       = "${var.name_prefix}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name_prefix}-rds-subnet-group" }
}

# Permite tráfego na porta 5432 apenas de dentro da VPC (os nodes do EKS)
resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Security Group para o RDS PostgreSQL"
  vpc_id      = var.vpc_id

  ingress {
    description = "Acesso ao PostgreSQL a partir da VPC (nodes do EKS)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-rds-sg" }
}

resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-rds-psql"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = null
  storage_type          = "gp3"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az = false

  # Sem backup automático e sem Performance Insights, para minimizar custo.
  backup_retention_period      = 0
  skip_final_snapshot          = true
  performance_insights_enabled = false

  tags = { Name = "${var.name_prefix}-rds-psql" }

  depends_on = [aws_db_subnet_group.rds, aws_security_group.rds]
}
