# Identidade que o próprio Prometheus usa para (1) descoberta via
# kubernetes_sd_configs (role: endpoints/node no prometheus.yml) e (2)
# alcançar o endpoint de métricas de recurso do kubelet através do proxy do
# apiserver (job "kubelet-resource" - GET /api/v1/nodes/<node>/proxy/metrics/
# resource). Só leitura; nenhum verbo de escrita.
resource "kubernetes_service_account_v1" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = var.namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_v1" "prometheus" {
  metadata {
    name   = "prometheus"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }

  # nodes/proxy é o que permite ao Prometheus alcançar
  # /api/v1/nodes/<node>/proxy/metrics/resource no kubelet - ver job
  # "kubelet-resource" em prometheus.yml.
  rule {
    api_groups = [""]
    resources  = ["nodes/proxy"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "prometheus" {
  metadata {
    name   = "prometheus"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.prometheus.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.prometheus.metadata[0].name
    namespace = var.namespace
  }
}
