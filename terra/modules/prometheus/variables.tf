variable "namespace" {
  description = "Namespace Kubernetes onde Prometheus roda (compartilhado com loki/tempo/alloy)"
  type        = string
}

variable "target_group_arn" {
  description = "ARN do target group da NLB para o Prometheus (output observe_target_group_arns[\"prometheus\"] do módulo nlb)"
  type        = string
}
