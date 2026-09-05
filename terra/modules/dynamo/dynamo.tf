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
  # "Disaster Recovery" em terra/README.md.
  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region_name = replica.value
    }
  }

  tags = { Name = var.table_name }

  # Necessário para o auto scaling abaixo não entrar em conflito com o
  # write_capacity declarado aqui a cada plan/apply, senão o Terraform
  # reverte para var.write_capacity (5) toda vez, brigando com a policy -
  # mesmo problema já resolvido para o HPA em kube-aws/ (Deployments sem
  # spec.replicas). Fica sempre presente (mesmo sem réplica) porque
  # ignore_changes não aceita expressão condicional; write_capacity é
  # tratado como piso fixo aqui, então mudar var.write_capacity exige
  # remover esta linha temporariamente, aplicar, e devolvê-la depois.
  lifecycle {
    ignore_changes = [write_capacity]
  }
}

# Global Tables (v2) com billing PROVISIONED exige capacidade de escrita
# com auto scaling configurado - a API rejeita a criação da réplica com
# capacidade fixa ("Table write capacity should either be Pay-Per-Request
# or AutoScaled"). Só criado quando há réplica (var.replica_regions), no
# mesmo espírito condicional do stream_enabled acima; sem réplica, a tabela
# de região única funciona normalmente com capacidade fixa.
resource "aws_appautoscaling_target" "volunteers_write" {
  count = length(var.replica_regions) > 0 ? 1 : 0

  max_capacity       = var.write_capacity_max
  min_capacity       = var.write_capacity
  resource_id        = "table/${aws_dynamodb_table.volunteers.name}"
  scalable_dimension = "dynamodb:table:WriteCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "volunteers_write" {
  count = length(var.replica_regions) > 0 ? 1 : 0

  name               = "${var.table_name}-write-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.volunteers_write[0].resource_id
  scalable_dimension = aws_appautoscaling_target.volunteers_write[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.volunteers_write[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBWriteCapacityUtilization"
    }
    target_value = 70
  }
}
