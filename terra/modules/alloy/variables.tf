variable "namespace" {
  description = "Namespace Kubernetes onde Alloy roda (compartilhado com loki/tempo/prometheus)"
  type        = string
}

# Segunda via de escrita dos logs (loki.write) para o Grafana Cloud, além do
# Loki local - mesmo motivo/padrão de terra/modules/prometheus
# (grafana_cloud_remote_write_url): sobreviver a uma migração para
# terra-dr/, já que o Loki local não é replicado entre regiões. Opcional:
# url vazia desativa esse segundo loki.write por completo (ver
# config.alloy.tpl).
variable "grafana_cloud_loki_url" {
  description = "Endpoint loki.write do Grafana Cloud (ex.: https://logs-prod-024.grafana.net/loki/api/v1/push) - vazio desativa o envio"
  type        = string
  default     = ""
}

variable "grafana_cloud_loki_username" {
  description = "Instance ID do stack de Logs do Grafana Cloud, usado como usuário no basic_auth do loki.write"
  type        = string
  default     = ""
}

variable "grafana_cloud_loki_api_key" {
  description = "API key do Grafana Cloud com escopo de escrita em Logs - fica só num Secret, nunca no ConfigMap"
  type        = string
  sensitive   = true
  default     = ""
}

# Segunda via de exportação dos traces (otelcol.exporter.otlp) para o
# Grafana Cloud, além do Tempo local - mesmo motivo/padrão acima.
variable "grafana_cloud_tempo_endpoint" {
  description = "Endpoint gRPC OTLP do Grafana Cloud Tempo (ex.: tempo-prod-17-prod-sa-east-1.grafana.net:443) - vazio desativa o envio"
  type        = string
  default     = ""
}

variable "grafana_cloud_tempo_username" {
  description = "Instance ID do stack de Traces (Tempo) do Grafana Cloud, usado como usuário no otelcol.auth.basic"
  type        = string
  default     = ""
}

variable "grafana_cloud_tempo_api_key" {
  description = "API key do Grafana Cloud com escopo de escrita em Traces - fica só num Secret, nunca no ConfigMap"
  type        = string
  sensitive   = true
  default     = ""
}
