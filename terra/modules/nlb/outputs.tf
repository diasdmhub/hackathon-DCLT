output "nlb_dns_name" {
  description = "DNS name da NLB única compartilhada pelos 3 serviços"
  value       = aws_lb.solidarytech.dns_name
}

output "nlb_arn" {
  description = "ARN da NLB"
  value       = aws_lb.solidarytech.arn
}

output "target_group_arns" {
  description = "ARN do target group de cada serviço (ngo/donation/volunteer) - usar no targetGroupARN dos TargetGroupBinding em kube-aws/"
  value       = { for k, tg in aws_lb_target_group.services : k => tg.arn }
}

output "observe_target_group_arns" {
  description = "ARN do target group de cada backend de observabilidade (loki/tempo/prometheus) - usar no target_group_arn dos módulos terra/modules/{loki,tempo,prometheus}"
  value       = { for k, tg in aws_lb_target_group.observe : k => tg.arn }
}
