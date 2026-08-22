# kube-state-metrics: expõe /metrics com o estado dos objetos do Kubernetes
# (pods, deployments, daemonsets, statefulsets, replicasets, nodes) - é a
# peça que dá ao Prometheus visão de saúde dos pods (fase, restarts,
# disponibilidade), não só uso de recurso. "collectors" restringe o chart só
# aos objetos relevantes aqui: por padrão ele cobre praticamente todo tipo
# de objeto do cluster (secrets, ingresses, PDBs, webhooks, RBAC...), o que
# neste ambiente seria ruído sem uso real nos dashboards - ver pedido do
# usuário de monitorar "somente as partes mais importantes".
resource "helm_release" "kube_state_metrics" {
  name       = "kube-state-metrics"
  namespace  = var.namespace
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = "8.4.0"

  values = [
    yamlencode({
      collectors = [
        "nodes",
        "pods",
        "deployments",
        "daemonsets",
        "statefulsets",
        "replicasets",
      ]
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
    })
  ]

  # O chart já marca o Service com "prometheus.io/scrape: true" por padrão
  # (prometheusScrape=true) - é assim que o job "kubernetes-service-
  # endpoints" em prometheus.yml o descobre, sem precisar de ServiceMonitor/
  # Prometheus Operator (que este ambiente não usa).
}

# node-exporter: métricas de host por node (CPU, memória, disco, rede) - a
# camada que o antigo Zabbix Agent2 cobria. DaemonSet com hostNetwork/hostPID
# (default do chart), um pod por node do EKS.
resource "helm_release" "node_exporter" {
  name       = "node-exporter"
  namespace  = var.namespace
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-node-exporter"
  version    = "4.56.1"

  values = [
    yamlencode({
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "100m", memory = "64Mi" }
      }
    })
  ]

  # Mesmo convênio "prometheus.io/scrape: true" do kube-state-metrics acima
  # - já vem por padrão no Service deste chart.
}
