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
  # Só criada quando não há restauração pendente (uso normal do ambiente
  # ativo) - ver aws_db_instance.restored abaixo para o caminho de ativação
  # do ambiente passivo (terra-dr/).
  count = var.restore_source_arn == null ? 1 : 0

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

  # backup_retention_period > 0 (antes era 0, sem backup algum) - necessário
  # para a replicação cross-region de backups usada pela estratégia de DR
  # ativo-passivo (ver "Disaster Recovery" em terra/README.md).
  # skip_final_snapshot continua true e Performance Insights continua
  # desligado, para não elevar custo além do necessário para o DR.
  backup_retention_period      = var.backup_retention_period
  skip_final_snapshot          = true
  performance_insights_enabled = false

  tags = { Name = "${var.name_prefix}-rds-psql" }

  depends_on = [aws_db_subnet_group.rds, aws_security_group.rds]
}

# Instância do ambiente passivo (terra-dr/): restaurada a partir do backup
# automatizado replicado cross-region (aws_db_instance_automated_backups_replication,
# criado no state do ambiente ativo - ver terra/main.tf), em vez de criada
# vazia - é assim que os dados chegam na região de DR. engine/engine_version/
# db_name/username/password/allocated_storage não são informados: um
# restore herda esses valores do backup de origem. Ver terra-dr/README.md
# para o passo a passo de ativação (como descobrir restore_source_arn).
resource "aws_db_instance" "restored" {
  count = var.restore_source_arn == null ? 0 : 1

  identifier     = "${var.name_prefix}-rds-psql"
  instance_class = var.instance_class
  storage_type   = "gp3"

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az = false

  backup_retention_period      = var.backup_retention_period
  skip_final_snapshot          = true
  performance_insights_enabled = false

  restore_to_point_in_time {
    source_db_instance_automated_backups_arn = var.restore_source_arn
    use_latest_restorable_time               = true
  }

  tags = { Name = "${var.name_prefix}-rds-psql" }

  depends_on = [aws_db_subnet_group.rds, aws_security_group.rds]
}

locals {
  # Referência única para outputs.tf, independente de qual dos dois
  # recursos acima foi criado.
  db_instance = var.restore_source_arn == null ? aws_db_instance.main[0] : aws_db_instance.restored[0]
}
