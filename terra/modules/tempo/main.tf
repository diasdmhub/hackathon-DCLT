locals {
  labels = {
    "app.kubernetes.io/part-of" = "solidarytech"
    "Project"                   = "SolidaryTech"
    "Environment"               = "dev"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "tempo_data" {
  metadata {
    name      = "tempo-data"
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

resource "kubernetes_config_map_v1" "tempo_config" {
  metadata {
    name      = "tempo-config"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "config.yaml" = file("${path.module}/config.yaml")
  }
}

resource "kubernetes_deployment_v1" "tempo" {
  metadata {
    name      = "tempo"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "tempo" })
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "tempo" }
    }
    template {
      metadata {
        labels = merge(local.labels, { app = "tempo" })
        annotations = {
          "checksum/config" = filesha256("${path.module}/config.yaml")
        }
      }
      spec {
        security_context {
          fs_group = 10001
        }
        container {
          name  = "tempo"
          image = "docker.io/grafana/tempo:latest"
          args  = ["-config.file=/etc/tempo/config.yaml"]
          port {
            container_port = 3200
          }
          port {
            container_port = 4317
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/tempo"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/tempo"
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
              path = "/ready"
              port = 3200
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }
          liveness_probe {
            http_get {
              path = "/ready"
              port = 3200
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
            name = kubernetes_config_map_v1.tempo_config.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.tempo_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "tempo" {
  metadata {
    name      = "tempo"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    # ClusterIP, não LoadBalancer: a exposição externa (porta 3200) é a NLB
    # única, via TargetGroupBinding abaixo. A porta 4317 (OTLP gRPC) fica só
    # interna, recebendo do Alloy via DNS do cluster.
    type     = "ClusterIP"
    selector = { app = "tempo" }
    port {
      name        = "http"
      port        = 3200
      target_port = 3200
    }
    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
    }
  }
}

# Ver comentário equivalente em terra/modules/loki/main.tf sobre
# kubectl_manifest vs kubernetes_manifest para este CRD.
resource "kubectl_manifest" "tempo_target_group_binding" {
  yaml_body = <<-YAML
    apiVersion: elbv2.k8s.aws/v1beta1
    kind: TargetGroupBinding
    metadata:
      name: tempo
      namespace: ${var.namespace}
      labels:
        app.kubernetes.io/part-of: solidarytech
        Project: SolidaryTech
        Environment: dev
    spec:
      serviceRef:
        name: tempo
        port: 3200
      targetGroupARN: ${var.target_group_arn}
      targetType: ip
  YAML

  depends_on = [kubernetes_service_v1.tempo]
}
