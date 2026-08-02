output "donation_service_role_arn" {
  description = "ARN da role IRSA do donation-service (usar na anotação eks.amazonaws.com/role-arn da ServiceAccount)"
  value       = aws_iam_role.donation_service.arn
}

output "volunteer_service_role_arn" {
  description = "ARN da role IRSA do volunteer-service (usar na anotação eks.amazonaws.com/role-arn da ServiceAccount)"
  value       = aws_iam_role.volunteer_service.arn
}
