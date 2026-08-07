variable "namespace" {
  description = "Namespace Kubernetes onde Loki roda (compartilhado com tempo/alloy/prometheus)"
  type        = string
}

variable "target_group_arn" {
  description = "ARN do target group da NLB para o Loki (output observe_target_group_arns[\"loki\"] do módulo nlb)"
  type        = string
}
