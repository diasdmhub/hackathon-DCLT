# Role IRSA do donation-service: permissão apenas para publicar na fila SQS
# de eventos de doação (equivalente ao SqsSvc.SendMessage em main.go).
data "aws_iam_policy_document" "donation_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.donation_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "donation_service" {
  name               = "${var.name_prefix}-donation-service-irsa"
  assume_role_policy = data.aws_iam_policy_document.donation_assume_role.json

  tags = { Name = "${var.name_prefix}-donation-service-irsa" }
}

data "aws_iam_policy_document" "donation_sqs" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.sqs_queue_arn]
  }
}

resource "aws_iam_role_policy" "donation_sqs" {
  name   = "${var.name_prefix}-donation-service-sqs"
  role   = aws_iam_role.donation_service.id
  policy = data.aws_iam_policy_document.donation_sqs.json
}

# Role IRSA do volunteer-service: permissão apenas para ler/escrever na
# tabela DynamoDB de voluntários (equivalente às chamadas boto3 em app.py).
data "aws_iam_policy_document" "volunteer_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.volunteer_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "volunteer_service" {
  name               = "${var.name_prefix}-volunteer-service-irsa"
  assume_role_policy = data.aws_iam_policy_document.volunteer_assume_role.json

  tags = { Name = "${var.name_prefix}-volunteer-service-irsa" }
}

data "aws_iam_policy_document" "volunteer_dynamodb" {
  statement {
    effect  = "Allow"
    actions = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:Query"]
    resources = [
      var.dynamodb_table_arn,
      "${var.dynamodb_table_arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "volunteer_dynamodb" {
  name   = "${var.name_prefix}-volunteer-service-dynamodb"
  role   = aws_iam_role.volunteer_service.id
  policy = data.aws_iam_policy_document.volunteer_dynamodb.json
}
