# Instala o AWS Load Balancer Controller, que reconcilia o CRD
# TargetGroupBinding usado em kube-aws/ (Flux) e em terra/modules/{loki,tempo,
# prometheus} (Terraform) para registrar pods nos target groups da NLB
# provisionada por terra/modules/nlb. Antes vivia em lb-controller/ (Flux) -
# movido para o Terraform pelo mesmo motivo do resto da observabilidade (ver
# terra/README.md): reconciliações no Flux exigiam intervenção manual, e o
# Flux se autodestruía ocasionalmente.
#
# A role IRSA continua em terra/modules/lb-iam (módulo de IAM puro,
# inalterado por esta migração) - este módulo só cuida do lado Kubernetes.
resource "kubernetes_service_account_v1" "aws_load_balancer_controller" {
  metadata {
    name      = var.service_account
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = var.role_arn
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = var.namespace
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"

  # wait (default true) espera o Deployment ficar Ready antes do apply
  # marcar este recurso como concluído - o CRD TargetGroupBinding, instalado
  # bem antes disso no ciclo do `helm install`, já está registrado na API do
  # cluster quando os módulos loki/tempo/prometheus (que dependem deste via
  # depends_on em terra/main.tf) começam a criar seus TargetGroupBinding.
  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.aws_region
      serviceAccount = {
        create = false
        name   = kubernetes_service_account_v1.aws_load_balancer_controller.metadata[0].name
      }
    })
  ]

  depends_on = [kubernetes_service_account_v1.aws_load_balancer_controller]
}
