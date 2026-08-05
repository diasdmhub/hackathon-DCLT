#!/usr/bin/env bash
# Wrapper fino sobre `terraform destroy`.
#
# Até a introdução da NLB única via TargetGroupBinding (terra/modules/nlb,
# lb-controller/), este script tinha uma etapa extra: os 3 `Service`
# `type: LoadBalancer` de kube-aws/ faziam o EKS criar uma Classic ELB (e a
# ENI associada) fora do state do Terraform, e era preciso suspender o Flux e
# apagar esses `Service`s manualmente antes do `terraform destroy` para não
# deixar ELB/ENI órfãos bloqueando a exclusão da VPC. Hoje kube-aws/ não tem
# mais nenhum `Service` `LoadBalancer` (todos viraram `ClusterIP` +
# `TargetGroupBinding`) - a NLB é o recurso `aws_lb` de terra/modules/nlb,
# dentro do state do Terraform, então `terraform destroy` já lida com ela
# (e com a regra de Security Group) na ordem certa, sem passo manual. Ver
# terra/README.md.
#
# Uso: terra/destroy.sh

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v terraform >/dev/null 2>&1; then
    echo "ERRO: binário ausente: terraform" >&2
    exit 1
fi

terraform destroy -auto-approve
