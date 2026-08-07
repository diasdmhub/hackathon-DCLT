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
