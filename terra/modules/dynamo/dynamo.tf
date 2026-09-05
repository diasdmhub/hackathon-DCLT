locals {
  # Global Tables (v2) com billing PROVISIONED exige auto scaling de escrita
  # já configurado no momento em que a réplica é criada - mas a réplica é
  # declarada no mesmo recurso que cria a tabela (bloco replica abaixo), e o
  # aws_appautoscaling_target só pode ser criado depois da tabela existir
  # (referencia aws_dynamodb_table.volunteers.name). Não há ordem de
  # aplicação num terraform apply só em que o auto scaling já exista antes
  # da AWS validar a réplica (tentativa anterior: "Table write capacity
  # should either be Pay-Per-Request or AutoScaled"). PAY_PER_REQUEST evita
  # o problema por completo, não exige capacidade nem auto scaling
  # configurado - custo real é pequeno dado o volume deste ambiente, mas,
  # diferente de PROVISIONED 5/5, não entra no always-free tier do DynamoDB.
  # Só ativado quando há réplica (var.replica_regions); sem DR, a tabela
  # continua PROVISIONED 5/5 como antes.
  has_replica = length(var.replica_regions) > 0
}

resource "aws_dynamodb_table" "volunteers" {
  name         = var.table_name
  billing_mode = local.has_replica ? "PAY_PER_REQUEST" : "PROVISIONED"
  hash_key     = var.hash_key

  attribute {
    name = var.hash_key
    type = "S"
  }

  # null (omitido) quando PAY_PER_REQUEST - a API rejeita capacidade
  # explícita nesse billing_mode.
  read_capacity  = local.has_replica ? null : var.read_capacity
  write_capacity = local.has_replica ? null : var.write_capacity

  # DynamoDB Streams é pré-requisito de Global Tables (v2) - só habilitado
  # quando há réplica configurada (var.replica_regions), para não acender
  # streams à toa fora do uso de DR.
  stream_enabled   = local.has_replica
  stream_view_type = local.has_replica ? "NEW_AND_OLD_IMAGES" : null

  # Réplica(s) da estratégia de DR ativo-passivo (terra-dr/) - ver
  # "Disaster Recovery" em terra/README.md.
  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region_name = replica.value
    }
  }

  tags = { Name = var.table_name }
}
