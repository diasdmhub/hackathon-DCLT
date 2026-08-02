variable "name_prefix" {
  description = "Prefixo do nome dos recursos"
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs das subnets privadas onde o control plane e os nodes serão criados"
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes do EKS (vazio usa a versão padrão atual da AWS)"
  type        = string
  default     = null
}

variable "node_instance_types" {
  description = "Tipos de instância EC2 do node group. Contas AWS criadas a partir de 15/07/2025 têm free tier baseado em créditos (até US$200/6 meses) que inclui, além de t3/t4g.micro/.small, os tipos c7i-flex.large e m7i-flex.large - com 2 vCPU/8GiB, m7i-flex.large tem folga real para os pods de app + Alloy sem esbarrar em memória (diferente de t3.micro/t3.small). Ajuste para t3.micro/t3.small se a conta for anterior a essa data e só tiver o free tier antigo (750h/mês de t2.micro/t3.micro por 12 meses)."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "enable_prefix_delegation" {
  description = "Habilita IPv4 Prefix Delegation no addon vpc-cni: cada slot de ENI passa a alocar um prefixo /28 (16 IPs) em vez de 1 IP, elevando bastante o teto de pods por node. Sem custo adicional - m7i-flex.large já tem ENIs/IPs suficientes para esta carga sem isso, mas manter habilitado dá folga caso a instância seja trocada por uma menor (t3.micro/.small)."
  type        = bool
  default     = true
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Quantidade mínima de nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Quantidade máxima de nodes"
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Tamanho (GiB) do disco EBS de cada node"
  type        = number
  default     = 20
}
