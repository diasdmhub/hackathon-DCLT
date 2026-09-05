discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
    separator     = "/"
    target_label  = "__path__"
    replacement   = "/var/log/pods/*$1/*.log"
  }
}

local.file_match "pods" {
  path_targets = discovery.relabel.pods.output
}

loki.source.file "pods" {
  targets    = local.file_match.pods.targets
  forward_to = [loki.process.pods.receiver]
}

loki.process "pods" {
  forward_to = [loki.write.default.receiver%{ if grafana_cloud_loki_url != "" }, loki.write.grafanacloud.receiver%{ endif }]

  stage.cri {}

  // Descarta entradas mais velhas que o limite de aceitação do Loki
  // (limits_config.reject_old_samples_max_age) para não derrubar o lote
  // inteiro quando arquivos de log antigos (ex.: restarts históricos de
  // DaemonSets de sistema) forem lidos junto com entradas recentes.
  stage.drop {
    older_than = "160h"
  }
}

loki.write "default" {
  endpoint {
    url = "http://loki.observe.svc.cluster.local:3100/loki/api/v1/push"
  }
}
%{ if grafana_cloud_loki_url != "" ~}

// Segunda via de escrita dos mesmos logs, para o Grafana Cloud (SaaS
// externo à AWS, fora do raio de um desastre regional) - o Loki local (PVC
// local-path/gp3) não é replicado entre regiões, então sem isso o
// histórico de logs some numa ativação de terra-dr/. A senha vem de um
// Secret montado (password_file), nunca deste ConfigMap - ver
// kubernetes_secret_v1.alloy_grafana_cloud em main.tf.
loki.write "grafanacloud" {
  endpoint {
    url = "${grafana_cloud_loki_url}"

    basic_auth {
      username      = "${grafana_cloud_loki_username}"
      password_file = "/etc/alloy-secrets/grafana-cloud/loki-api-key"
    }
  }
}
%{ endif ~}

// Recebe traces OTLP dos microserviços e os roteia ao Tempo.
// O Alloy é o único ponto de entrada de telemetria do cluster:
// logs (tail dos arquivos CRI acima) e traces (OTLP abaixo).
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  http {
    endpoint = "0.0.0.0:4318"
  }
  output {
    traces = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  output {
    traces = [otelcol.exporter.otlp.tempo.input%{ if grafana_cloud_tempo_endpoint != "" }, otelcol.exporter.otlp.grafanacloud.input%{ endif }]
  }
}

otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo.observe.svc.cluster.local:4317"
    tls {
      insecure = true
    }
  }
}
%{ if grafana_cloud_tempo_endpoint != "" ~}

// Segunda via de exportação dos mesmos traces, para o Grafana Cloud (SaaS
// externo à AWS) - mesmo motivo do loki.write.grafanacloud acima: o Tempo
// local não é replicado entre regiões. A senha vem de um Secret montado
// (password_file), nunca deste ConfigMap.
otelcol.auth.basic "grafanacloud" {
  client_auth {
    username      = "${grafana_cloud_tempo_username}"
    password_file = "/etc/alloy-secrets/grafana-cloud/tempo-api-key"
  }
}

otelcol.exporter.otlp "grafanacloud" {
  client {
    endpoint = "${grafana_cloud_tempo_endpoint}"
    auth     = otelcol.auth.basic.grafanacloud.handler
  }
}
%{ endif ~}
