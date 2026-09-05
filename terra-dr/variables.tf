# Espelha terra/variables.tf: mesmos nomes/tipos/defaults na maioria dos
# casos, para que os módulos compartilhados (terra/modules/*) recebam
# exatamente a mesma configuração do ambiente ativo - ver "Disaster
# Recovery" em terra/README.md. Onde este root diverge, o comentário explica
# o porquê.

variable "name_prefix" {
  description = "Prefixo do nome de todos os recursos AWS - mantido IGUAL ao do ambiente ativo (terra/), não \"solidarytech-dr\": recursos regionais (NLB, target groups, RDS, SQS, DynamoDB) não colidem entre regiões diferentes da mesma conta, e kube-aws/*.yaml referencia os target groups pelo nome determinístico (ex.: \"solidarytech-ngo-tg\") - um name_prefix diferente quebraria esse binding sem alterar kube-aws/. Só as IAM roles (namespace global) recebem um sufixo à parte - ver role_name_suffix em terra-dr/main.tf."
  type        = string
  default     = "solidarytech"
}

variable "aws_region" {
  description = "Região da AWS do ambiente passivo - precisa ser igual a dr_aws_region em terra/terraform.tfvars"
  type        = string
  default     = "us-west-2"
}

# Variáveis da VPC
#############################
variable "subnet_prefix" {
  description = "Os 2 primeiros octetos do CIDR da VPC - use um bloco distinto do ambiente ativo (10.80.0.0/16) para permitir VPC peering entre as duas regiões, se algum dia for necessário"
  type        = string
  default     = "10.90"
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
  description = "Tipos de instância EC2 do node group - ver terra/variables.tf para o racional de m7i-flex.large vs t3.micro/t3.small"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "enable_prefix_delegation" {
  description = "Habilita IPv4 Prefix Delegation no vpc-cni"
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
  description = "Nome do database - ignorado quando rds_restore_source_arn está definido (um restore herda o database do backup de origem)"
  type        = string
  default     = "sol_db"
}

variable "db_username" {
  description = "Usuário master do PostgreSQL - ignorado quando rds_restore_source_arn está definido"
  type        = string
  default     = "sol"
}

variable "db_password" {
  description = "Senha do usuário master. Quando rds_restore_source_arn está definido, esta variável NÃO define a senha real (um restore herda a senha do backup de origem) - precisa ser exatamente igual à senha real do ambiente ativo, só para compor a rds_connection_url usada pelos Secrets ngo-env/donation-env. Ver terra-dr/README.md."
  type        = string
  sensitive   = true
}

variable "rds_instance_class" {
  description = "Classe da instância RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_backup_retention_period" {
  description = "Dias de retenção de backup automatizado desta instância (independente da retenção do ambiente ativo)"
  type        = number
  default     = 7
}

variable "rds_restore_source_arn" {
  description = "ARN do backup automatizado replicado nesta região (aws_db_instance_automated_backups_replication, criado no state do ambiente ativo - ver terra/main.tf) a partir do qual restaurar. null (padrão) cria uma instância NOVA E VAZIA - errado para uma ativação real de DR, use só para testar a malha de rede/módulos isoladamente. Ver terra-dr/README.md para como descobrir esse ARN na hora da ativação."
  type        = string
  default     = null
}

# Variáveis do DynamoDB
#############################
variable "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB - precisa ser IGUAL ao do ambiente ativo: a tabela já existe nesta região como réplica da Global Table (module.dynamo, replica_regions, em terra/main.tf), não é criada por este root"
  type        = string
  default     = "SolidaryTechVolunteers"
}

# Variáveis do SQS
#############################
variable "sqs_queue_name" {
  description = "Nome (sufixo) da fila SQS - independente do ambiente ativo, criada do zero na ativação (eventos em trânsito na fila do ambiente ativo não são replicados, ver terra-dr/README.md)"
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
  description = "Nome da ServiceAccount do donation-service"
  type        = string
  default     = "donation-service"
}

variable "volunteer_service_account" {
  description = "Nome da ServiceAccount do volunteer-service"
  type        = string
  default     = "volunteer-service"
}

variable "lb_controller_namespace" {
  description = "Namespace Kubernetes onde o AWS Load Balancer Controller roda"
  type        = string
  default     = "kube-system"
}

variable "lb_controller_service_account" {
  description = "Nome da ServiceAccount do AWS Load Balancer Controller"
  type        = string
  default     = "aws-load-balancer-controller"
}

# Variáveis do FluxCD
#############################
variable "flux_chart_version" {
  description = "Versão do chart Helm flux2 (../terra/modules/flux) - ver https://github.com/fluxcd-community/helm-charts/releases antes de atualizar"
  type        = string
  default     = "2.19.0"
}

# Variáveis da NLB (observabilidade) - mesmo mecanismo de terra/dns.tf
#############################
variable "observe_allowed_cidrs" {
  description = "CIDRs, IPs ou nomes de domínio autorizados a alcançar Loki/Tempo/Prometheus pela NLB do ambiente passivo"
  type        = list(string)
}

# Grafana Private Datasource Connect (PDC) - grafana_pdc_token precisa ser
# IGUAL ao valor real de terra/terraform.tfvars (mesma network), para o
# agente deste ambiente assumir o túnel sem o datasource no Grafana Cloud
# precisar ser reapontado na ativação do DR. Ver terra/modules/pdc e
# "Disaster Recovery" em terra/README.md.
variable "grafana_pdc_token" {
  description = "Token da network de Private Datasource Connect (PDC) do Grafana Cloud - IGUAL ao usado em terra/terraform.tfvars. Vazio desativa o módulo."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_pdc_cluster" {
  description = "Nome do cluster PDC do stack Grafana Cloud (ex.: prod-sa-east-1) - IGUAL ao usado em terra/terraform.tfvars"
  type        = string
  default     = ""
}

# Variáveis de failover DNS (Route53) - ver "Disaster Recovery" em
# terra/README.md
#############################
variable "route53_zone_id" {
  description = "Zone ID da hosted zone Route53 criada pelo ambiente ativo (output route53_zone_id de terra/, só existe quando manage_dns = true por lá). \"\" (padrão) = não cria o registro SECONDARY nem o health check aqui."
  type        = string
  default     = ""
}

variable "dns_record_name" {
  description = "FQDN do registro de failover SECONDARY - precisa ser IGUAL ao dns_record_name usado em terra/terraform.tfvars (mesmo nome, dois registros com set_identifier diferente)"
  type        = string
  default     = ""
}
