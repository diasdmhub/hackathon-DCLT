# Parâmetros da camada Standard do SSM Parameter Store: sem custo por
# parâmetro nem por API call dentro do uso normal (diferente do Secrets
# Manager, que cobra por segredo/mês). SecureString usa a chave gerenciada
# padrão "alias/aws/ssm" (sem custo de KMS customizado).

resource "aws_ssm_parameter" "rds_connection_url" {
  name        = "${var.path_prefix}/rds/connection_url"
  description = "URL completa de conexão PostgreSQL (equivalente ao DATABASE_URL)"
  type        = "SecureString"
  value       = var.rds_connection_url
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-rds-connection-url" }
}

resource "aws_ssm_parameter" "rds_password" {
  name        = "${var.path_prefix}/rds/password"
  description = "Senha do usuário master do RDS"
  type        = "SecureString"
  value       = var.rds_password
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-rds-password" }
}

resource "aws_ssm_parameter" "sqs_queue_url" {
  name        = "${var.path_prefix}/sqs/queue_url"
  description = "URL da fila SQS de eventos de doação"
  type        = "String"
  value       = var.sqs_queue_url
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-sqs-queue-url" }
}

resource "aws_ssm_parameter" "dynamodb_table_name" {
  name        = "${var.path_prefix}/dynamodb/table_name"
  description = "Nome da tabela DynamoDB de voluntários"
  type        = "String"
  value       = var.dynamodb_table_name
  tier        = "Standard"

  tags = { Name = "${var.name_prefix}-ssm-dynamodb-table-name" }
}

# Secrets ngo-env/donation-env/volunteer-env que kube-aws/ espera via
# envFrom (042-ngo.yaml, 052-donation.yaml, 062-volunteer.yaml). Criados
# aqui, direto pelo provider kubernetes, em vez de aplicados manualmente
# fora do Flux: mesmo raciocínio de terra/modules/{zabbix,loki,tempo,alloy,
# prometheus} (ver "Observabilidade via Terraform" em terra/README.md) -
# evita um passo manual sem tirar o dado sensível (senha do RDS) do Flux/git.
resource "kubernetes_secret_v1" "ngo_env" {
  metadata {
    name      = "ngo-env"
    namespace = var.k8s_namespace
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }

  data = {
    PORT         = "8081"
    DATABASE_URL = var.rds_connection_url
  }
}

resource "kubernetes_secret_v1" "donation_env" {
  metadata {
    name      = "donation-env"
    namespace = var.k8s_namespace
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }

  data = {
    PORT         = "8082"
    DATABASE_URL = var.rds_connection_url
    AWS_REGION   = var.aws_region
    AWS_SQS_URL  = var.sqs_queue_url
  }
}

resource "kubernetes_secret_v1" "volunteer_env" {
  metadata {
    name      = "volunteer-env"
    namespace = var.k8s_namespace
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }

  data = {
    PORT               = "8083"
    AWS_REGION         = var.aws_region
    AWS_DYNAMODB_TABLE = var.dynamodb_table_name
  }
}
