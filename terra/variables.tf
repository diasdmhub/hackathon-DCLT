variable "name_prefix" {
  description = "Prefixo do nome de todos os recursos AWS"
  type        = string
  default     = "solidarytech"
}

variable "aws_region" {
  description = "Região da AWS"
  type        = string
  default     = "us-east-1"
}

# Variáveis da VPC
#############################
variable "subnet_prefix" {
  description = "Os 2 primeiros octetos do CIDR da VPC"
  type        = string
  default     = "10.80"
}

variable "az_count" {
  description = "Quantidade de AZs (mínimo 2)"
  type        = number
  default     = 2
}

# Variáveis do EKS
#############################
variable "eks_kubernetes_version" {
  description = "Versão do Kubernetes do EKS (vazio usa a versão padrão atual da AWS)"
  type        = string
  default     = null
}

variable "eks_node_instance_types" {
  description = "Tipos de instância EC2 do node group. m7i-flex.large é elegível ao free tier baseado em créditos (contas criadas a partir de 15/07/2025, até US$200/6 meses); ajuste para t3.micro/t3.small em conta mais antiga (free tier de 750h/mês por 12 meses)."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "enable_prefix_delegation" {
  description = "Habilita IPv4 Prefix Delegation no vpc-cni (mais IPs/pods por node, sem custo adicional)"
  type        = bool
  default     = true
}

variable "eks_node_desired_size" {
  description = "Quantidade desejada de nodes do EKS"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Quantidade mínima de nodes do EKS"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Quantidade máxima de nodes do EKS"
  type        = number
  default     = 2
}

# Variáveis do RDS
#############################
variable "db_name" {
  description = "Nome do database inicial no RDS"
  type        = string
  default     = "sol_db"
}

variable "db_username" {
  description = "Usuário master do PostgreSQL"
  type        = string
  default     = "sol"
}

# DEFINA O VALOR REAL NO terraform.tfvars (não versionado)
variable "db_password" {
  description = "Senha do usuário master do RDS"
  type        = string
  sensitive   = true
}

variable "rds_instance_class" {
  description = "Classe da instância RDS"
  type        = string
  default     = "db.t3.micro"
}

# Variáveis do DynamoDB
#############################
variable "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB de voluntários"
  type        = string
  default     = "SolidaryTechVolunteers"
}

# Variáveis do SQS
#############################
variable "sqs_queue_name" {
  description = "Nome (sufixo) da fila SQS de eventos de doação"
  type        = string
  default     = "donation-events"
}

# Variáveis do IAM/IRSA
#############################
variable "k8s_namespace" {
  description = "Namespace Kubernetes onde os serviços rodam"
  type        = string
  default     = "solidarytech"
}

variable "donation_service_account" {
  description = "Nome da ServiceAccount do donation-service (a ser criada em kube/ com a anotação IRSA)"
  type        = string
  default     = "donation-service"
}

variable "volunteer_service_account" {
  description = "Nome da ServiceAccount do volunteer-service (a ser criada em kube/ com a anotação IRSA)"
  type        = string
  default     = "volunteer-service"
}

variable "lb_controller_namespace" {
  description = "Namespace Kubernetes onde o AWS Load Balancer Controller roda"
  type        = string
  default     = "kube-system"
}

variable "lb_controller_service_account" {
  description = "Nome da ServiceAccount do AWS Load Balancer Controller (criada pelo módulo terra/modules/lb, com a anotação IRSA)"
  type        = string
  default     = "aws-load-balancer-controller"
}

# Variáveis da NLB (observabilidade)
#############################
# DEFINA O VALOR REAL NO terraform.tfvars (não versionado) - sem default de
# propósito, para não abrir Loki/Tempo/Prometheus (sem autenticação própria)
# para 0.0.0.0/0 por engano.
variable "observe_allowed_cidrs" {
  description = "CIDRs, IPs ou nomes de domínio autorizados a alcançar Loki/Tempo/Prometheus (terra/modules/{loki,tempo,prometheus}) pela NLB - normalmente o IP público (fixo ou via um domínio DDNS) de onde o Grafana externo consulta. Domínios são resolvidos via DNS a cada terraform apply (ver terra/dns.tf)."
  type        = list(string)
}

# Variáveis do Zabbix (terra/modules/zabbix)
#############################
# DEFINA OS VALORES REAIS NO terraform.tfvars (não versionado) - identificam
# sua infraestrutura pessoal de Zabbix, por isso sem default.
variable "zabbix_hostname" {
  description = "Nome do objeto \"Proxy\" criado manualmente no seu Zabbix server (Data collection -> Proxies, modo Active) - vira zabbixProxy.ZBX_HOSTNAME no chart"
  type        = string
}

variable "zabbix_server_host" {
  description = "Hostname ou IP do seu Zabbix server externo, acessível na porta 10051 - vira zabbixProxy.ZBX_SERVER_HOST no chart"
  type        = string
}

variable "zabbix_version" {
  description = "Versão major.minor do Zabbix Proxy/Agent2 (ex: \"7.4\") - vira a tag de imagem \"ol-<versão>-latest\" (zabbixImageTag no chart, variante Oracle Linux). O chart zabbix-community/helm-zabbix só traz por padrão a versão LTS (7.0) via zabbixImageTag; para usar uma versão non-LTS é preciso sobrescrever essa tag manualmente, ver comentário do values.yaml do chart. Precisa bater com a versão do Zabbix server externo (var.zabbix_server_host) - um proxy mais novo que o server não se conecta."
  type        = string
  default     = "7.4"
}

variable "zabbix_proxy_tls_psk_identity" {
  description = "Identidade da PSK (Pre-Shared Key) usada na conexão TLS do Zabbix Proxy com o Zabbix server externo - precisa ser igual à identidade configurada na aba Encryption do objeto Proxy no Zabbix server"
  type        = string
}

variable "zabbix_proxy_tls_psk" {
  description = "Valor da PSK em hexadecimal (64 a 128 caracteres, ou seja 256 a 512 bits) - ex: gerado com \"openssl rand -hex 32\". Precisa ser igual ao valor configurado na aba Encryption do objeto Proxy no Zabbix server. DEFINA O VALOR REAL NO terraform.tfvars (não versionado)"
  type        = string
  sensitive   = true
}
