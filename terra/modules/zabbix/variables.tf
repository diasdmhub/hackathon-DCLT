variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "namespace" {
  description = "Namespace Kubernetes onde o Zabbix Proxy/Agent2/kube-state-metrics rodam"
  type        = string
  default     = "zabbix"
}

# Identificam a infraestrutura pessoal do Zabbix server externo - ver
# terra/variables.tf (sem default de propósito, definidos em terraform.tfvars).
variable "zabbix_hostname" {
  description = "Nome do objeto \"Proxy\" criado manualmente no Zabbix server (Data collection -> Proxies, modo Active)"
  type        = string
}

variable "zabbix_server_host" {
  description = "Hostname/IP do Zabbix server externo (porta 10051)"
  type        = string
}

variable "zabbix_version" {
  description = "Versão major.minor do Zabbix Proxy/Agent2 (ex: \"7.4\") - monta a tag de imagem \"ol-<versão>-latest\" (zabbixImageTag no chart)"
  type        = string
}

# PSK (Pre-Shared Key) da conexão TLS entre o Zabbix Proxy e o Zabbix server
# externo (porta 10051) - ver terra/variables.tf (sem default de propósito,
# definidos em terraform.tfvars).
variable "zabbix_proxy_tls_psk_identity" {
  description = "Identidade da PSK (ZBX_TLSPSKIDENTITY) - precisa ser igual à identidade configurada na aba Encryption do objeto Proxy no Zabbix server"
  type        = string
}

variable "zabbix_proxy_tls_psk" {
  description = "Valor da PSK em hexadecimal (64 a 128 caracteres, ou seja 256 a 512 bits) - ex: gerado com \"openssl rand -hex 32\". Precisa ser igual ao valor configurado na aba Encryption do objeto Proxy no Zabbix server"
  type        = string
  sensitive   = true
}
