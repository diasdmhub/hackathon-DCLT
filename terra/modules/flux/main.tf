# Instala os controladores do FluxCD via o chart Helm oficial da comunidade
# (fluxcd-community/flux2), em vez do `flux install` (CLI) manual usado
# antes - unifica a instalação inicial e futuras atualizações de versão
# (bump de chart_version) num único `terraform apply`, no mesmo padrão já
# usado para o AWS Load Balancer Controller (terra/modules/lb). Só os 4
# controladores padrão do `flux install` sem `--components-extra` ficam
# habilitados: image-reflector-controller/image-automation-controller ficam
# de fora porque o loop de Image Automation já roda no cluster
# kubeadm-local e não deve rodar duas vezes (ver CLAUDE.md).
#
# Isso NÃO muda a decisão de não usar `flux bootstrap` aqui (ver o
# GitRepository em git_repository_yaml/clusters/eks-aws*/flux-system/
# gotk-sync.yaml): o Flux instalado por este módulo continua só lendo do
# GitRepository/Kustomization abaixo, nunca escrevendo de volta no
# repositório - só a forma como os controladores chegam no cluster mudou,
# de `flux install` (CLI) para `helm_release` (Terraform).
resource "kubernetes_namespace_v1" "flux_system" {
  metadata {
    name = "flux-system"
    labels = {
      "app.kubernetes.io/part-of"       = "solidarytech"
      "Project"                         = "SolidaryTech"
      "Environment"                     = "primary"
      "pod-security.kubernetes.io/warn" = "restricted"
    }
  }
}

resource "helm_release" "flux2" {
  name       = "flux2"
  namespace  = kubernetes_namespace_v1.flux_system.metadata[0].name
  repository = "https://fluxcd-community.github.io/helm-charts"
  chart      = "flux2"
  version    = var.chart_version

  values = [
    yamlencode({
      sourceController          = { create = true }
      kustomizeController       = { create = true }
      helmController            = { create = true }
      notificationController    = { create = true }
      imageReflectionController = { create = false }
      imageAutomationController = { create = false }
    })
  ]
}

# GitRepository e Kustomization "solidarytech" - o mesmo YAML já versionado
# em clusters/eks-aws{,-dr}/ (repassado via variável, única fonte de
# verdade), aplicado agora pelo Terraform em vez de `kubectl apply -f`
# manual - ver terra/README.md.
resource "kubectl_manifest" "git_repository" {
  yaml_body = var.git_repository_yaml

  depends_on = [helm_release.flux2]
}

resource "kubectl_manifest" "solidarytech_kustomization" {
  yaml_body = var.kustomization_yaml

  depends_on = [kubectl_manifest.git_repository]
}

# Secret irsa-role-arns, consumido via postBuild.substituteFrom pela
# Kustomization acima para preencher kube-aws/005-serviceaccounts.yaml.
# Antes era aplicado à mão a partir de um *.example.yaml copiado localmente
# (removido), colando os ARNs impressos por `terraform output -json
# iam_outputs`; o Terraform já tem esses ARNs diretamente (module.iam), sem
# esse passo manual.
resource "kubernetes_secret_v1" "irsa_role_arns" {
  metadata {
    name      = "irsa-role-arns"
    namespace = kubernetes_namespace_v1.flux_system.metadata[0].name
  }

  data = {
    DONATION_SERVICE_ROLE_ARN  = var.donation_service_role_arn
    VOLUNTEER_SERVICE_ROLE_ARN = var.volunteer_service_role_arn
  }

  depends_on = [kubernetes_namespace_v1.flux_system]
}
