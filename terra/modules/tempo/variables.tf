variable "namespace" {
  description = "Namespace Kubernetes onde Tempo roda (compartilhado com loki/alloy/prometheus)"
  type        = string
}

variable "target_group_arn" {
  description = "ARN do target group da NLB para o Tempo (output observe_target_group_arns[\"tempo\"] do módulo nlb)"
  type        = string
}
