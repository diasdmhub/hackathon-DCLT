locals {
  labels = {
    "app.kubernetes.io/part-of" = "solidarytech"
    "Project"                   = "SolidaryTech"
    "Environment"               = "primary"
  }
}

# Token num Secret dedicado, nunca em texto puro em ConfigMap/args visíveis -
# mesmo padrão de terra/modules/prometheus (kubernetes_secret_v1.
# prometheus_grafana_cloud) e terra/modules/secrets. O agente lê o valor via
# variável de ambiente (PDC_TOKEN abaixo), expandida na flag -token pelo
# próprio Kubernetes ($(PDC_TOKEN) em args - não é interpolação Terraform).
resource "kubernetes_secret_v1" "pdc_token" {
  metadata {
    name      = "pdc-agent-token"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    token = var.grafana_pdc_token
  }
}

# Sem Service/TargetGroupBinding: o agente só abre uma conexão de saída
# (HTTPS) para o Grafana Cloud, viabilizada pela NAT Gateway já existente
# (terra/modules/vpc) - nenhuma exposição de entrada é necessária, ao
# contrário de loki/tempo/prometheus (ver terra/README.md, seção
# "Remote_write para o Grafana Cloud", sobre a diferença entre as duas
# direções). Uma vez validado, esta é a peça que permite remover a
# exposição via NLB dessas 3 backends por completo.
resource "kubernetes_deployment_v1" "pdc_agent" {
  metadata {
    name      = "pdc-agent"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "pdc-agent" })
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "pdc-agent" }
    }
    template {
      metadata {
        labels = merge(local.labels, { app = "pdc-agent" })
      }
      spec {
        container {
          name  = "pdc-agent"
          image = "docker.io/grafana/pdc-agent:latest"
          env {
            name = "PDC_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.pdc_token.metadata[0].name
                key  = "token"
              }
            }
          }
          args = [
            "-token=$(PDC_TOKEN)",
            "-cluster=${var.grafana_pdc_cluster}",
          ]
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}
