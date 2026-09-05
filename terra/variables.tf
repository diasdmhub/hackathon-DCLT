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

# Variáveis do FluxCD
#############################
variable "flux_chart_version" {
  description = "Versão do chart Helm flux2 (terra/modules/flux) - ver https://github.com/fluxcd-community/helm-charts/releases antes de atualizar"
  type        = string
  default     = "2.19.0"
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

# Grafana Cloud (remote_write de saída do Prometheus) - ver
# "Métricas de negócio via Prometheus" e "Disaster Recovery" em
# terra/README.md. Opcional: vazio desativa o remote_write. Sem default de
# propósito para url/username (evita um envio silencioso mal configurado);
# api_key tem default vazio só para não quebrar terra-dr/, que hoje não
# passa essas variáveis ao module.prometheus.
variable "grafana_cloud_remote_write_url" {
  description = "Endpoint remote_write do Grafana Cloud Prometheus (ex.: https://prometheus-prod-NN-prod-REGIAO.grafana.net/api/prom/push) - vazio desativa o envio"
  type        = string
  default     = ""
}

variable "grafana_cloud_username" {
  description = "Instance ID do stack Grafana Cloud (usuário no basic_auth do remote_write)"
  type        = string
  default     = ""
}

variable "grafana_cloud_api_key" {
  description = "API key do Grafana Cloud com permissão de escrita em métricas (senha no basic_auth do remote_write) - DEFINA NO terraform.tfvars, nunca versionado"
  type        = string
  sensitive   = true
  default     = ""
}

# Grafana Private Datasource Connect (PDC) - permite o Grafana Cloud
# consultar Loki/Tempo/Prometheus deste cluster sem expô-los publicamente
# via NLB (túnel de saída, não CIDR de entrada). Opcional: token vazio
# desativa o módulo por completo (nenhum pod sobe). Mesmo cuidado do
# db_password: o valor de grafana_pdc_token precisa ser IGUAL em
# terra-dr/terraform.tfvars, para o agente do ambiente passivo se conectar
# à mesma network e o datasource no Grafana Cloud não precisar ser
# reapontado numa ativação de DR (ver "Disaster Recovery" em
# terra/README.md).
variable "grafana_pdc_token" {
  description = "Token da network de Private Datasource Connect (PDC) do Grafana Cloud - DEFINA NO terraform.tfvars, nunca versionado. Vazio desativa o módulo (terra/modules/pdc)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_pdc_cluster" {
  description = "Nome do cluster PDC do stack Grafana Cloud (ex.: prod-sa-east-1)"
  type        = string
  default     = ""
}

# Variáveis de Disaster Recovery (ambiente ativo-passivo)
#############################
# Ver "Disaster Recovery" em terra/README.md para a estratégia completa e
# terra-dr/README.md para o runbook de ativação do ambiente passivo.

variable "dr_aws_region" {
  description = "Região AWS do ambiente passivo (terra-dr/) - usada aqui só para configurar o provider aws.dr (terraform.tf), que replica os backups automatizados do RDS para essa região. Precisa ser igual ao aws_region definido em terra-dr/terraform.tfvars."
  type        = string
  default     = "us-west-2"
}

variable "enable_dr" {
  description = "Habilita a proteção contínua de dados da estratégia de DR: replicação cross-region de backups automatizados do RDS (aws_db_instance_automated_backups_replication) + réplica da tabela DynamoDB via Global Tables (module.dynamo, replica_regions). Desligado por padrão para não alterar custo/comportamento do ambiente já em produção sem opt-in explícito."
  type        = bool
  default     = false
}

variable "rds_backup_retention_period" {
  description = "Dias de retenção de backup automatizado do RDS - precisa ser > 0 para var.enable_dr funcionar (pré-requisito de aws_db_instance_automated_backups_replication). Mantido configurável mesmo com enable_dr = false porque também é um bom padrão de resiliência por si só (permite restore point-in-time dentro da mesma região)."
  type        = number
  default     = 7
}

variable "manage_dns" {
  description = "Cria a hosted zone Route53 + health check + registro de failover PRIMARY apontando para a NLB do ambiente ativo - pré-requisito para o failover automático de DNS que terra-dr/ completa com o registro SECONDARY. Desligado por padrão: exige ter (ou registrar/delegar) o domínio em var.dns_zone_name."
  type        = bool
  default     = false
}

variable "dns_zone_name" {
  description = "Domínio da hosted zone Route53 criada quando var.manage_dns = true (ex.: \"solidarytech.diasdm.com.br\"). Se o domínio raiz já está registrado em outro provedor/DNS, delegue este subdomínio para os nameservers da zone criada aqui (registros NS) - ver terra/README.md."
  type        = string
  default     = ""
}

variable "dns_record_name" {
  description = "FQDN do registro de failover que aponta para a NLB ativa - normalmente igual a var.dns_zone_name ou um subdomínio dele (ex.: \"api.solidarytech.diasdm.com.br\"). Só usado quando var.manage_dns = true."
  type        = string
  default     = ""
}

