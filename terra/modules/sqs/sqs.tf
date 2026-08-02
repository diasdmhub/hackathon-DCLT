# Fila standard: sem custo de capacidade provisionada, cobrada por requisição
# (1M de requisições/mês sempre gratuitas, sem limite de 12 meses).
resource "aws_sqs_queue" "donation_events" {
  name = "${var.name_prefix}-${var.queue_name}"

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds

  tags = { Name = "${var.name_prefix}-${var.queue_name}" }
}
