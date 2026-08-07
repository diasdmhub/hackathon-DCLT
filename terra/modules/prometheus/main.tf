locals {
  labels = {
    "app.kubernetes.io/part-of" = "solidarytech"
    "Project"                   = "SolidaryTech"
    "Environment"               = "dev"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "prometheus_data" {
  metadata {
    name      = "prometheus-data"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    # gp3: StorageClass default provisionada por terra/modules/eks (EBS
    # CSI), equivalente ao "local-path" usado em observe/ (kubeadm-local).
    storage_class_name = "gp3"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_config_map_v1" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "prometheus.yml" = file("${path.module}/prometheus.yml")
  }
}

resource "kubernetes_deployment_v1" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "prometheus" })
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "prometheus" }
    }
    template {
      metadata {
        labels = merge(local.labels, { app = "prometheus" })
        annotations = {
          "checksum/config" = filesha256("${path.module}/prometheus.yml")
        }
      }
      spec {
        security_context {
          fs_group = 65534
        }
        container {
          name  = "prometheus"
          image = "docker.io/prom/prometheus:latest"
          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=168h",
            # Habilita o endpoint remote_write (desativado por padrão) para
            # receber as métricas de service-graph/span-metrics do Tempo
            "--web.enable-remote-write-receiver",
          ]
          port {
            container_port = 9090
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/prometheus"
          }
          volume_mount {
            name       = "data"
            mount_path = "/prometheus"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/-/ready"
              port = 9090
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }
          liveness_probe {
            http_get {
              path = "/-/healthy"
              port = 9090
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.prometheus_config.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.prometheus_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    # ClusterIP, não LoadBalancer: a exposição externa é a NLB única, via
    # TargetGroupBinding abaixo.
    type     = "ClusterIP"
    selector = { app = "prometheus" }
    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
  }
}

# Ver comentário equivalente em terra/modules/loki/main.tf sobre
# kubectl_manifest vs kubernetes_manifest para este CRD.
resource "kubectl_manifest" "prometheus_target_group_binding" {
  yaml_body = <<-YAML
    apiVersion: elbv2.k8s.aws/v1beta1
    kind: TargetGroupBinding
    metadata:
      name: prometheus
      namespace: ${var.namespace}
      labels:
        app.kubernetes.io/part-of: solidarytech
        Project: SolidaryTech
        Environment: dev
    spec:
      serviceRef:
        name: prometheus
        port: 9090
      targetGroupARN: ${var.target_group_arn}
      targetType: ip
  YAML

  depends_on = [kubernetes_service_v1.prometheus]
}
