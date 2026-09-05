global:
  scrape_interval: 15s

# Além de receber (remote_write) as métricas de RED/service-graph geradas
# pelo metrics-generator do Tempo, este Prometheus também faz scraping das
# métricas de cluster/pod que antes vinham do Zabbix - ver terra/README.md,
# seção "Métricas de cluster via Prometheus". Deliberadamente enxuto: só o
# necessário para a saúde do cluster e dos pods da solidarytech, não todo
# detalhe que o kube-state-metrics/kubelet conseguem expor.
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # kube-state-metrics (estado dos pods/deployments/daemonsets/statefulsets/
  # replicasets/nodes) e node-exporter (CPU/memória/disco/rede por node) -
  # ambos no namespace "observe" (terra/modules/prometheus/helm.tf),
  # descobertos pelo convênio "prometheus.io/scrape: true" que os dois
  # charts já aplicam por padrão ao respectivo Service. O label
  # "app.kubernetes.io/name" do Service vira o label "job" da série, em vez
  # do nome completo do release do Helm.
  - job_name: kubernetes-service-endpoints
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [observe]
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        regex: "true"
        action: keep
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
        target_label: job
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node

  # Métricas de negócio dos 3 microsserviços da solidarytech (ex.:
  # solidarytech_ngos_total, solidarytech_donations_total/amount_sum),
  # calculadas na fonte (Postgres) a cada coleta, não a partir de logs -
  # substitui os antigos painéis Grafana "(total)" baseados em
  # count_over_time() sobre o Loki, presos à retenção de 168h do Loki (ver
  # terra/README.md). Mesmo convênio "prometheus.io/scrape: true" usado
  # acima, mas namespace solidarytech; volunteer-service fica de fora (ver
  # job abaixo) por causa da diferença de custo do scrape.
  - job_name: solidarytech-service-endpoints
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [solidarytech]
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        regex: "true"
        action: keep
      - source_labels: [__meta_kubernetes_service_name]
        regex: volunteer
        action: drop
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
        target_label: job

  # volunteer-service num job à parte, com scrape_interval de 5m em vez do
  # padrão global de 15s: sua métrica de total é calculada com um Scan
  # completo da tabela DynamoDB (Select=COUNT), que consome as mesmas RCUs
  # de um scan normal - a 15s isso competiria com a capacidade provisionada
  # da tabela (5 RCU, ver terra/README.md).
  - job_name: solidarytech-volunteer-metrics
    scrape_interval: 5m
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [solidarytech]
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        regex: "true"
        action: keep
      - source_labels: [__meta_kubernetes_service_name]
        regex: volunteer
        action: keep
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
        target_label: job

  # CPU/memória por node/pod/container, direto do kubelet via proxy do
  # apiserver (endpoint /metrics/resource - resumo enxuto, bem mais leve que
  # /metrics/cadvisor completo). Exige a ClusterRole "prometheus" (rbac.tf)
  # com acesso a nodes/proxy; a ServiceAccount "prometheus" (rbac.tf) é a
  # usada pelo Deployment (main.tf), cujo token/CA montados por padrão em
  # /var/run/secrets/kubernetes.io/serviceaccount/ autenticam contra a
  # própria API do EKS.
  - job_name: kubelet-resource
    scheme: https
    kubernetes_sd_configs:
      - role: node
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    relabel_configs:
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/$${1}/proxy/metrics/resource
%{ if grafana_cloud_remote_write_url != "" ~}

# Envio contínuo das séries de golden metrics/SLI (traces_spanmetrics_*,
# geradas pelo metrics-generator do Tempo) para o Grafana Cloud (SaaS
# externo à AWS, fora do raio de um desastre regional) - o TSDB local (PVC
# gp3, 35d de retenção) não é replicado entre regiões, então sem isso o
# histórico de SLO (janelas fixas de 30d,
# ver doc/grafana/dashboard-solidarytech-golden-metrics.json) reseta a cada
# ativação de terra-dr/. A senha vem de um Secret montado (password_file),
# nunca deste ConfigMap - ver kubernetes_secret_v1.prometheus_grafana_cloud
# em main.tf. Credenciais em si ficam só em terraform.tfvars (gitignored).
remote_write:
  - url: ${grafana_cloud_remote_write_url}
    basic_auth:
      username: "${grafana_cloud_username}"
      password_file: /etc/prometheus-secrets/grafana-cloud/api-key
    write_relabel_configs:
      # Só as séries usadas pelos painéis de golden metrics/SLO - não a base
      # inteira do Prometheus (kube-state-metrics, node-exporter, métricas de
      # negócio já protegidas via RDS/DynamoDB, ver doc/plano-continuidade-negocios.md).
      - source_labels: [__name__]
        regex: "traces_spanmetrics_(calls_total|latency_bucket|latency_sum|latency_count)"
        action: keep
%{ endif ~}
