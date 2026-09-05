variable "namespace" {
  description = "Namespace Kubernetes onde Prometheus roda (compartilhado com loki/tempo/alloy)"
  type        = string
}

variable "target_group_arn" {
  description = "ARN do target group da NLB para o Prometheus (output observe_target_group_arns[\"prometheus\"] do módulo nlb)"
  type        = string
}

# Grafana Cloud (remote_write de saída) - séries de SLI/SLO sobreviverem a
# uma migração para o ambiente de DR, já que o TSDB local (PVC gp3) não é
# replicado entre regiões. Opcional: url vazia desativa o remote_write por
# completo (nenhum bloco é escrito em prometheus.yml).
variable "grafana_cloud_remote_write_url" {
  description = "Endpoint remote_write do Grafana Cloud Prometheus (vazio desativa o envio)"
  type        = string
  default     = ""
}

variable "grafana_cloud_username" {
  description = "Instance ID do stack Grafana Cloud, usado como usuário no basic_auth do remote_write"
  type        = string
  default     = ""
}

variable "grafana_cloud_api_key" {
  description = "API key do Grafana Cloud, usada como senha no basic_auth do remote_write - fica só num Secret, nunca no ConfigMap"
  type        = string
  sensitive   = true
  default     = ""
}
