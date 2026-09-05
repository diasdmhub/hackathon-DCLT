locals {
  labels = {
    "app.kubernetes.io/part-of" = "solidarytech"
    "Project"                   = "SolidaryTech"
    "Environment"               = "primary"
  }
}

resource "kubernetes_service_account_v1" "alloy" {
  metadata {
    name      = "alloy"
    namespace = var.namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_v1" "alloy" {
  metadata {
    name   = "alloy"
    labels = local.labels
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "nodes", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "alloy" {
  metadata {
    name   = "alloy"
    labels = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.alloy.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.alloy.metadata[0].name
    namespace = var.namespace
  }
}

locals {
  # Renderizado uma vez e reaproveitado no checksum/config abaixo - mesmo
  # padrão de terra/modules/prometheus/main.tf.
  alloy_config_rendered = templatefile("${path.module}/config.alloy.tpl", {
    grafana_cloud_loki_url       = var.grafana_cloud_loki_url
    grafana_cloud_loki_username  = var.grafana_cloud_loki_username
    grafana_cloud_tempo_endpoint = var.grafana_cloud_tempo_endpoint
    grafana_cloud_tempo_username = var.grafana_cloud_tempo_username
  })
}

resource "kubernetes_config_map_v1" "alloy_config" {
  metadata {
    name      = "alloy-config"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "config.alloy" = local.alloy_config_rendered
  }
}

# API keys do Grafana Cloud (Logs/Traces) num Secret dedicado, nunca no
# ConfigMap acima - mesmo padrão de
# kubernetes_secret_v1.prometheus_grafana_cloud em
# terra/modules/prometheus/main.tf. Sempre criado (mesmo com as chaves
# vazias, quando o envio ao Grafana Cloud está desativado) para manter o
# volume/volume_mount abaixo incondicional.
resource "kubernetes_secret_v1" "alloy_grafana_cloud" {
  metadata {
    name      = "alloy-grafana-cloud"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "loki-api-key"  = var.grafana_cloud_loki_api_key
    "tempo-api-key" = var.grafana_cloud_tempo_api_key
  }
}

resource "kubernetes_daemon_set_v1" "alloy" {
  metadata {
    name      = "alloy"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "alloy" })
  }
  spec {
    selector {
      match_labels = { app = "alloy" }
    }
    template {
      metadata {
        labels = merge(local.labels, { app = "alloy" })
        annotations = {
          "checksum/config" = sha256(local.alloy_config_rendered)
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.alloy.metadata[0].name
        container {
          name  = "alloy"
          image = "docker.io/grafana/alloy:latest"
          args = [
            "run",
            "--server.http.listen-addr=0.0.0.0:12345",
            "--storage.path=/var/lib/alloy/data",
            "--disable-reporting",
            "/etc/alloy/config.alloy",
          ]
          port {
            container_port = 12345
          }
          port {
            container_port = 4317
          }
          port {
            container_port = 4318
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/alloy"
          }
          volume_mount {
            name       = "varlogpods"
            mount_path = "/var/log/pods"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/alloy/data"
          }
          volume_mount {
            name       = "grafana-cloud-secret"
            mount_path = "/etc/alloy-secrets/grafana-cloud"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/-/ready"
              port = 12345
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }
          liveness_probe {
            http_get {
              path = "/-/ready"
              port = 12345
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.alloy_config.metadata[0].name
          }
        }
        volume {
          name = "varlogpods"
          host_path {
            path = "/var/log/pods"
          }
        }
        # hostPath, não emptyDir: perder o positions file no restart do pod
        # causa um re-tail completo dos logs históricos - ver CLAUDE.md.
        volume {
          name = "data"
          host_path {
            path = "/var/lib/alloy/data"
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "grafana-cloud-secret"
          secret {
            secret_name = kubernetes_secret_v1.alloy_grafana_cloud.metadata[0].name
          }
        }
      }
    }
  }
}

# Ponto de entrada OTLP dos microserviços (traces), roteado pelo Alloy ao
# Tempo - sem TargetGroupBinding, só alcançado internamente.
resource "kubernetes_service_v1" "alloy" {
  metadata {
    name      = "alloy"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector = { app = "alloy" }
    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
    }
    port {
      name        = "otlp-http"
      port        = 4318
      target_port = 4318
    }
  }
}
