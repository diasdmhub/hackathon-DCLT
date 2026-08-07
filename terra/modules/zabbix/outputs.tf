output "namespace" {
  description = "Namespace Kubernetes onde o Zabbix Proxy/Agent2/kube-state-metrics rodam"
  value       = kubernetes_namespace_v1.zabbix.metadata[0].name
}

output "k8s_reader_token_secret" {
  description = "Nome do Secret com o token de longa duração da ServiceAccount zabbix-k8s-reader (usar em {$KUBE.API.TOKEN} no Zabbix server: kubectl get secret <valor> -n <namespace> -o jsonpath='{.data.token}' | base64 -d)"
  value       = kubernetes_secret_v1.zabbix_k8s_reader_token.metadata[0].name
}
