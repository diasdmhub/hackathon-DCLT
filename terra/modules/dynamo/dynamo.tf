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

  tags = { Name = var.table_name }
}
