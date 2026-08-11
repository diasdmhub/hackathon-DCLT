locals {
  labels = {
    "app.kubernetes.io/part-of" = "solidarytech"
    "Project"                   = "SolidaryTech"
    "Environment"               = "dev"
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

resource "kubernetes_config_map_v1" "alloy_config" {
  metadata {
    name      = "alloy-config"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "config.alloy" = file("${path.module}/config.alloy")
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
          "checksum/config" = filesha256("${path.module}/config.alloy")
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
