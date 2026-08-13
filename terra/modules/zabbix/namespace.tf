resource "kubernetes_namespace_v1" "zabbix" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "solidarytech"
      "Project"                   = "SolidaryTech"
      "Environment"               = "primary"
    }
  }
}
