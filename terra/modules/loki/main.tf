locals {
  labels = {
    "app.kubernetes.io/part-of" = "solidarytech"
    "Project"                   = "SolidaryTech"
    "Environment"               = "primary"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "loki_data" {
  metadata {
    name      = "loki-data"
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
  # gp3 usa volumeBindingMode WaitForFirstConsumer - o PVC só entra em Bound
  # quando o Deployment abaixo agenda o pod, então não espera aqui.
  wait_until_bound = false
}

resource "kubernetes_config_map_v1" "loki_config" {
  metadata {
    name      = "loki-config"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "config.yaml" = file("${path.module}/config.yaml")
  }
}

resource "kubernetes_deployment_v1" "loki" {
  metadata {
    name      = "loki"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "loki" })
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "loki" }
    }
    template {
      metadata {
        labels = merge(local.labels, { app = "loki" })
        annotations = {
          # Força o rollout quando config.yaml muda - equivalente ao sufixo
          # de hash do configMapGenerator usado em observe/ (kubeadm-local, Flux).
          "checksum/config" = filesha256("${path.module}/config.yaml")
        }
      }
      spec {
        security_context {
          fs_group = 10001
        }
        container {
          name  = "loki"
          image = "docker.io/grafana/loki:latest"
          args  = ["-config.file=/etc/loki/config.yaml"]
          port {
            container_port = 3100
          }
          port {
            container_port = 9096
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/loki"
          }
          volume_mount {
            name       = "data"
            mount_path = "/loki"
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
              port = 3100
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }
          liveness_probe {
            http_get {
              path = "/ready"
              port = 3100
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
            name = kubernetes_config_map_v1.loki_config.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.loki_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "loki" {
  metadata {
    name      = "loki"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    # ClusterIP, não LoadBalancer: a exposição externa é a NLB única
    # provisionada por terra/modules/nlb, via TargetGroupBinding abaixo.
    type     = "ClusterIP"
    selector = { app = "loki" }
    port {
      name        = "http"
      port        = 3100
      target_port = 3100
    }
  }
}

# TargetGroupBinding é um CRD instalado pelo AWS Load Balancer Controller
# (terra/modules/lb, também Terraform) - via kubectl_manifest, não
# kubernetes_manifest, porque este último valida o schema do CRD contra o
# cluster já no `terraform plan`, o que quebraria numa primeira execução
# contra um cluster novo, antes de module.lb ter sido aplicado (ver
# terra/README.md). O depends_on em terra/main.tf garante que module.lb
# aplica primeiro.
resource "kubectl_manifest" "loki_target_group_binding" {
  yaml_body = <<-YAML
    apiVersion: elbv2.k8s.aws/v1beta1
    kind: TargetGroupBinding
    metadata:
      name: loki
      namespace: ${var.namespace}
      labels:
        app.kubernetes.io/part-of: solidarytech
        Project: SolidaryTech
        Environment: primary
    spec:
      serviceRef:
        name: loki
        port: 3100
      targetGroupARN: ${var.target_group_arn}
      targetType: ip
  YAML

  depends_on = [kubernetes_service_v1.loki]
}
