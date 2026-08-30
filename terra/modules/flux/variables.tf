variable "chart_version" {
  description = "Versão do chart Helm flux2 (fluxcd-community/helm-charts) - ver https://github.com/fluxcd-community/helm-charts/releases antes de atualizar (o app_version correspondente é a versão do Flux em si, ex.: chart 2.19.0 = Flux v2.9.1)"
  type        = string
  default     = "2.19.0"
}

variable "git_repository_yaml" {
  description = "Conteúdo YAML do GitRepository flux-system - lido via file() a partir do gotk-sync.yaml já versionado em clusters/eks-aws{,-dr}/flux-system/ (fonte única de verdade, não duplicada aqui)"
  type        = string
}

variable "kustomization_yaml" {
  description = "Conteúdo YAML da Kustomization solidarytech - lido via file() a partir do solidarytech-kustomization.yaml já versionado em clusters/eks-aws{,-dr}/, mesma lógica de git_repository_yaml"
  type        = string
}

variable "donation_service_role_arn" {
  description = "ARN da role IRSA do donation-service (output donation_service_role_arn do módulo iam) - vira DONATION_SERVICE_ROLE_ARN no Secret irsa-role-arns"
  type        = string
}

variable "volunteer_service_role_arn" {
  description = "ARN da role IRSA do volunteer-service (output volunteer_service_role_arn do módulo iam) - vira VOLUNTEER_SERVICE_ROLE_ARN no Secret irsa-role-arns"
  type        = string
}
