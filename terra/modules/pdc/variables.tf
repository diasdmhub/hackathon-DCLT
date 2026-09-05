variable "namespace" {
  description = "Namespace Kubernetes onde o agente PDC roda (compartilhado com loki/tempo/alloy/prometheus)"
  type        = string
}

# Token e cluster vêm da tela de criação da network de Private Datasource
# Connect no Grafana Cloud, que gera um comando pronto (helm/docker) com os
# valores já preenchidos - confirme ali os nomes exatos das flags do
# pdc-agent (-token/-cluster) antes do primeiro apply, podem mudar entre
# versões do agente.
variable "grafana_pdc_token" {
  description = "Token da network de Private Datasource Connect (PDC) do Grafana Cloud - autentica o agente no túnel de saída. Nunca fica num ConfigMap: só num Secret dedicado (ver kubernetes_secret_v1.pdc_token em main.tf)."
  type        = string
  sensitive   = true
}

variable "grafana_pdc_cluster" {
  description = "Nome do cluster PDC do stack Grafana Cloud (ex.: prod-sa-east-1, mesma região do endpoint de remote_write do Prometheus)"
  type        = string
}
