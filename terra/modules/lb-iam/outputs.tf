output "role_arn" {
  description = "ARN da role IRSA do AWS Load Balancer Controller (usada como role_arn do módulo terra/modules/lb, na anotação eks.amazonaws.com/role-arn da ServiceAccount que ele cria)"
  value       = aws_iam_role.lb_controller.arn
}
