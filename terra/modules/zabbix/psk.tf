# Secret com o arquivo de PSK (Pre-Shared Key) usado pelo Zabbix Proxy na
# conexão TLS de saída para o Zabbix server externo (ZBX_TLSCONNECT=psk em
# helm.tf). O valor da PSK nunca é passado como variável de ambiente direta
# (ficaria visível em "kubectl describe pod"/no spec do Pod) - o próprio
# design do Zabbix espera um arquivo (ZBX_TLSPSKFILE), montado aqui via
# volume comum de Secret.
resource "kubernetes_secret_v1" "zabbix_proxy_psk" {
  metadata {
    name      = "zabbix-proxy-tls-psk"
    namespace = kubernetes_namespace_v1.zabbix.metadata[0].name
  }

  data = {
    tls_psk_file = var.zabbix_proxy_tls_psk
  }

  type = "Opaque"
}
