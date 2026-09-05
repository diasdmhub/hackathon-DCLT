locals {
  labels = {
    "app.kubernetes.io/part-of" = "solidarytech"
    "Project"                   = "SolidaryTech"
    "Environment"               = "primary"
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
        # Retenção curta (ver retention.time abaixo): desde que o
        # remote_write para o Grafana Cloud passou a cobrir todas as séries
        # (não só golden metrics/SLI), o disco local só precisa de um buffer
        # operacional, não mais do histórico de SLO - isso já vive no
        # Prometheus do Grafana Cloud. 2Gi segue de sobra mesmo assim (uso
        # medido no cluster kubeadm-local foi ~7MB/dia).
        storage = "2Gi"
      }
    }
  }
  wait_until_bound = false
}

locals {
  # Renderizado uma vez e reaproveitado no checksum/config abaixo, para que
  # o hash reflita o conteúdo final (incluindo o bloco remote_write
  # condicional), não só os bytes estáticos do arquivo.
  prometheus_config_rendered = templatefile("${path.module}/prometheus.yml.tpl", {
    grafana_cloud_remote_write_url = var.grafana_cloud_remote_write_url
    grafana_cloud_username         = var.grafana_cloud_username
  })
}

resource "kubernetes_config_map_v1" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "prometheus.yml" = local.prometheus_config_rendered
  }
}

# API key do Grafana Cloud num Secret dedicado, nunca no ConfigMap acima -
# mesmo padrão de terra/modules/secrets (ngo-env/donation-env/volunteer-env)
# para não deixar segredo em texto puro num objeto sem esse propósito.
# Sempre criado (mesmo com api_key vazia quando o remote_write está
# desativado) para manter o volume/volume_mount abaixo incondicional.
resource "kubernetes_secret_v1" "prometheus_grafana_cloud" {
  metadata {
    name      = "prometheus-grafana-cloud"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "api-key" = var.grafana_cloud_api_key
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
          "checksum/config" = sha256(local.prometheus_config_rendered)
        }
      }
      spec {
        # ServiceAccount própria (rbac.tf), não "default": precisa da
        # ClusterRole "prometheus" para descoberta via kubernetes_sd_configs
        # e para o job "kubelet-resource" (proxy do apiserver ao kubelet).
        service_account_name = kubernetes_service_account_v1.prometheus.metadata[0].name
        security_context {
          fs_group = 65534
        }
        container {
          name  = "prometheus"
          image = "docker.io/prom/prometheus:latest"
          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            # Buffer curto: o remote_write para o Grafana Cloud (ver
            # prometheus.yml.tpl) já cobre todas as séries, então o disco
            # local não precisa mais reter o histórico de SLO (30d) - só o
            # suficiente para consulta/depuração local.
            "--storage.tsdb.retention.time=24h",
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
          volume_mount {
            name       = "grafana-cloud-secret"
            mount_path = "/etc/prometheus-secrets/grafana-cloud"
            read_only  = true
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
        volume {
          name = "grafana-cloud-secret"
          secret {
            secret_name = kubernetes_secret_v1.prometheus_grafana_cloud.metadata[0].name
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
    # ClusterIP: sem exposição externa - o Prometheus não é mais consultado
    # de fora do cluster (ver "Logs e traces para o Grafana Cloud"/
    # "Remote_write para o Grafana Cloud" em terra/README.md), só alcançado
    # internamente (Tempo empurra spanmetrics via remote_write).
    type     = "ClusterIP"
    selector = { app = "prometheus" }
    port {
      name        = "http"
      port        = 9090
      target_port = 9090
    }
  }
}
