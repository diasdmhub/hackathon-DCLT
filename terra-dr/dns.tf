# Idêntico a terra/dns.tf - mesmo mecanismo de resolução de
# CIDR/IP/domínio para var.observe_allowed_cidrs, reaplicado aqui porque
# terra-dr/ é um root Terraform independente (não pode importar locals de
# outro diretório). Ver terra/dns.tf para o comentário completo.

locals {
  observe_cidr_regex = "^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$"
  observe_ip_regex   = "^([0-9]{1,3}\\.){3}[0-9]{1,3}$"

  observe_allowed_hostnames = toset([
    for entry in var.observe_allowed_cidrs : entry
    if !can(regex(local.observe_cidr_regex, entry)) && !can(regex(local.observe_ip_regex, entry))
  ])
}

data "dns_a_record_set" "observe_allowed" {
  for_each = local.observe_allowed_hostnames
  host     = each.value
}

locals {
  observe_allowed_cidrs_resolved = [
    for entry in var.observe_allowed_cidrs : (
      can(regex(local.observe_cidr_regex, entry)) ? entry :
      can(regex(local.observe_ip_regex, entry)) ? "${entry}/32" :
      "${data.dns_a_record_set.observe_allowed[entry].addrs[0]}/32"
    )
  ]
}
