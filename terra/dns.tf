# Resolução de host/domínio para CIDR em observe_allowed_cidrs, para quem
# consulta o Grafana externo a partir de um IP dinâmico associado a um nome
# DDNS (ex.: diasdm.com.br) em vez de um IP fixo - ver terra/README.md.
#
# Cada entrada de var.observe_allowed_cidrs pode ser:
# - um CIDR (ex.: "203.0.113.10/32") - usado como está;
# - um IP solto (ex.: "203.0.113.10") - vira "/32" automaticamente;
# - um nome de domínio (ex.: "diasdm.com.br") - resolvido via DNS a cada
#   terraform plan/apply, e o primeiro endereço retornado vira "/32".
#
# A resolução só acontece no momento do apply: se o IP por trás do domínio
# mudar depois, a regra de Security Group só acompanha no próximo apply.

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
