output "role_arn" {
  description = "ARN da role IRSA do AWS Load Balancer Controller (usar na anotação eks.amazonaws.com/role-arn da ServiceAccount em lb-controller/000-serviceaccount.yaml)"
  value       = aws_iam_role.lb_controller.arn
}
