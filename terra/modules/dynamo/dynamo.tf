resource "aws_dynamodb_table" "volunteers" {
  name         = var.table_name
  billing_mode = "PROVISIONED"
  hash_key     = var.hash_key

  attribute {
    name = var.hash_key
    type = "S"
  }

  read_capacity  = var.read_capacity
  write_capacity = var.write_capacity

  # DynamoDB Streams é pré-requisito de Global Tables (v2) - só habilitado
  # quando há réplica configurada (var.replica_regions), para não acender
  # streams à toa fora do uso de DR.
  stream_enabled   = length(var.replica_regions) > 0
  stream_view_type = length(var.replica_regions) > 0 ? "NEW_AND_OLD_IMAGES" : null

  # Réplica(s) da estratégia de DR ativo-passivo (terra-dr/) - ver
  # "Disaster Recovery" em terra/README.md. Nota: com billing PROVISIONED,
  # a AWS espera capacidade equivalente configurada (idealmente via
  # auto scaling) em cada região da Global Table para absorver o tráfego de
  # replicação sem throttling; dado o volume baixo deste ambiente, os
  # read_capacity/write_capacity acima (5/5) começam sem auto scaling - se
  # aparecer throttling de replicação, adicionar aws_appautoscaling_target/
  # policy é o próximo passo, não contemplado aqui.
  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region_name = replica.value
    }
  }

  tags = { Name = var.table_name }
}
