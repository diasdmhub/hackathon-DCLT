# Identidade de leitura que o Zabbix usa para consultar a API do Kubernetes
# e o kube-state-metrics diretamente (templates nativas "Kubernetes nodes by
# HTTP" / "Kubernetes cluster state by HTTP" - macros {$KUBE.API.SERVER.URL}
# e {$KUBE.API.TOKEN}, configuradas manualmente no Zabbix server - ver
# README.md deste módulo). Somente leitura; nenhum verbo de escrita.
#
# O Secret abaixo (kubernetes.io/service-account-token) gera um token de
# longa duração vinculado a esta ServiceAccount - diferente do token
# projetado (1h) que os Pods recebem por padrão, este não expira sozinho, o
# que é necessário porque quem o usa (o Zabbix server/proxy) é externo ao
# ciclo de vida de um Pod.
resource "kubernetes_service_account_v1" "zabbix_k8s_reader" {
  metadata {
    name      = "zabbix-k8s-reader"
    namespace = kubernetes_namespace_v1.zabbix.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }
}

resource "kubernetes_secret_v1" "zabbix_k8s_reader_token" {
  metadata {
    name      = "zabbix-k8s-reader-token"
    namespace = kubernetes_namespace_v1.zabbix.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.zabbix_k8s_reader.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_cluster_role_v1" "zabbix_k8s_reader" {
  metadata {
    name = "zabbix-k8s-reader"
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "pods", "namespaces", "events", "endpoints", "componentstatuses", "resourcequotas"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes/proxy", "nodes/stats", "nodes/metrics"]
    verbs      = ["get"]
  }

  # Necessário só no namespace "zabbix": permite ao Zabbix alcançar o
  # /metrics do kube-state-metrics através do proxy da própria API do
  # Kubernetes (sem expor o Service publicamente).
  rule {
    api_groups = [""]
    resources  = ["services/proxy"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "daemonsets", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["nodes", "pods"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "zabbix_k8s_reader" {
  metadata {
    name = "zabbix-k8s-reader"
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.zabbix_k8s_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.zabbix_k8s_reader.metadata[0].name
    namespace = kubernetes_namespace_v1.zabbix.metadata[0].name
  }
}
