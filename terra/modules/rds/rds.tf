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
#     destroy/recreate. É o mecanismo usado na ativação do ambiente passivo
#     (promove o replica sempre-vivo) e na etapa final do failback (promove
#     de volta o replica recriado na região original - ver abaixo).
#
# ⚠️ Validado em simulado real (2026-09-08) - a direção OPOSTA (uma
# instância standalone existente virando replica, sem nunca ter sido criada
# como replica) NÃO é suportada in-place pela AWS: tentar isso (por exemplo,
# só reaplicar terra/ com var.dr_failback_source_arn preenchido, sem mais
# nada) resulta em "Error: cannot elect new source database for
# replication" - a API rejeita, sem efeito colateral (nenhum dado é
# tocado), mas também não faz o que o failback precisa. Terraform também
# não marca essa mudança como "forces replacement" no plano (mostra como
# update in-place, o que é enganoso). O failback (passo 3 do runbook) e o
# reestabelecimento do replica sempre-vivo (passo 6) por isso exigem forçar
# a substituição explicitamente:
#   terraform apply -target=<endereço deste recurso> -replace=<mesmo endereço> -var=...
# -target é essencial junto com -replace: sem ele, o -replace force-destrói
# esta instância e o Terraform recalcula o restante do grafo a partir dela,
# o que pode arrastar outra instância deste mesmo módulo (a que ainda está
# servindo tráfego real) para dentro do mesmo apply só porque ela referencia
# o ARN desta como replicate_source_db_arn - ver "Failback" em
# doc/roteiro-dr-ativacao.md para os comandos exatos e o motivo.
#
# Efeito colateral inofensivo, também validado no simulado: ao sair do papel
# de replica (replicate_source_db_arn volta a null), engine_version e
# password voltam a ser gerenciados por este recurso (linhas abaixo) - um
# apply subsequente pode mostrar essas duas mudanças mesmo sem nenhuma
# intenção de alterá-las. Não é uma regressão de versão real (AWS não faz
# downgrade silencioso; "18" é só a forma abreviada de fixar a major
# version, compatível com o "18.x" já em execução) nem uma rotação de senha
# real (mesmo valor de var.db_password de sempre) - apenas o campo voltando
# a ficar sob gestão explícita do Terraform.
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
