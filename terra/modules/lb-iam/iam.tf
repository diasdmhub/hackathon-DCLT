# Role IRSA do AWS Load Balancer Controller. A policy é a JSON oficial
# publicada pelo próprio projeto (iam_policy.json, baixado de
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json) -
# concede só o necessário para reconciliar Service/Ingress/TargetGroupBinding
# (describe/create/modify de NLB/ALB, target groups, security groups etc.),
# escopado por tag elbv2.k8s.aws/cluster onde a AWS permite condition keys.
data "aws_iam_policy_document" "lb_controller_assume_role" {
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
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.name_prefix}-aws-load-balancer-controller-irsa${var.role_name_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume_role.json

  tags = { Name = "${var.name_prefix}-aws-load-balancer-controller-irsa${var.role_name_suffix}" }
}

resource "aws_iam_role_policy" "lb_controller" {
  name   = "${var.name_prefix}-aws-load-balancer-controller-policy"
  role   = aws_iam_role.lb_controller.id
  policy = file("${path.module}/iam_policy.json")
}
