#!/usr/bin/env bash
# Automatiza a ordem correta de destruição do ambiente AWS: suspende as
# Kustomizations do Flux para o cluster não recriar nada durante a limpeza,
# apaga os manifests que elas sincronizam (em especial os 3 `Service`
# `type: LoadBalancer` de kube-aws/) enquanto o cluster EKS ainda existe, e só
# então roda `terraform destroy`.
#
# Motivo: cada Service LoadBalancer gera um Classic ELB (e a ENI associada)
# fora do state do Terraform. Se o EKS for destruído antes desses Services
# serem removidos, o ELB e a ENI ficam órfãos - e a ENI não pode ser apagada
# manualmente (pertence à conta de serviço amazon-elb), só desaparece quando
# o próprio ELB é excluído. Ver terra/README.md.
#
# Uso: terra/destroy.sh

set -euo pipefail
export AWS_PAGER=""

cd "$(dirname "$0")"
REPO_ROOT="$(git rev-parse --show-toplevel)"

log() { echo "[destroy] $*" >&2; }

missing=()
for cmd in aws terraform kubectl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} )); then
    echo "ERRO: binário(s) ausente(s): ${missing[*]}" >&2
    exit 1
fi

skip_k8s_cleanup=0

if ! terraform output -json eks_outputs >/dev/null 2>&1; then
    log "Sem state do Terraform (ou cluster nunca criado) - pulando limpeza via kubectl."
    skip_k8s_cleanup=1
else
    eks_cluster_name=$(terraform output -json eks_outputs | jq -r '.eks_cluster_name')
    vpc_id=$(terraform output -json vpc_outputs | jq -r '.vpc_id')
    aws_region=$(terraform output -raw configure_kubectl | sed -n 's/.*--region \([^ ]*\).*/\1/p')

    if ! aws eks update-kubeconfig --region "$aws_region" --name "$eks_cluster_name" >/dev/null 2>&1; then
        log "Cluster '$eks_cluster_name' inacessível (já destruído?) - pulando limpeza via kubectl."
        skip_k8s_cleanup=1
    elif ! kubectl --request-timeout=10s get ns >/dev/null 2>&1; then
        log "kubectl não conseguiu falar com a API do cluster - pulando limpeza via kubectl."
        skip_k8s_cleanup=1
    fi
fi

if [ "$skip_k8s_cleanup" -eq 0 ]; then
    log "1) Suspendendo as Kustomizations do Flux (solidarytech, observe)..."
    for kustomization in solidarytech observe; do
        if kubectl get kustomization "$kustomization" -n flux-system >/dev/null 2>&1; then
            kubectl patch kustomization "$kustomization" -n flux-system \
              --type=merge -p '{"spec":{"suspend":true}}'
        else
            log "   Kustomization '$kustomization' não encontrada, ignorando."
        fi
    done

    log "2) Removendo os recursos já sincronizados pelo Flux (kube-aws/, observe-aws/)..."
    kubectl delete -k "$REPO_ROOT/kube-aws" --ignore-not-found --wait=true --timeout=180s || \
        log "   AVISO: falha ao remover algum recurso de kube-aws/; seguindo mesmo assim."
    kubectl delete -k "$REPO_ROOT/observe-aws" --ignore-not-found --wait=true --timeout=180s || \
        log "   AVISO: falha ao remover algum recurso de observe-aws/; seguindo mesmo assim."

    log "3) Aguardando os Load Balancers órfãos desaparecerem da VPC $vpc_id..."
    timeout=300 interval=15 elapsed=0
    while (( elapsed < timeout )); do
        classic=$(aws elb describe-load-balancers \
          --query "length(LoadBalancerDescriptions[?VPCId=='$vpc_id'])" --output text 2>/dev/null || echo 0)
        v2=$(aws elbv2 describe-load-balancers \
          --query "length(LoadBalancers[?VpcId=='$vpc_id'])" --output text 2>/dev/null || echo 0)
        if [ "$classic" = "0" ] && [ "$v2" = "0" ]; then
            log "   Nenhum Load Balancer remanescente na VPC."
            break
        fi
        log "   Ainda restam $classic Classic ELB(s) e $v2 ALB/NLB na VPC; aguardando ${interval}s (${elapsed}s/${timeout}s)..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    if (( elapsed >= timeout )); then
        log "   AVISO: Load Balancer(s) ainda presentes após ${timeout}s. As ENIs associadas podem bloquear o"
        log "   'terraform destroy' a seguir. Se isso acontecer, apague o(s) ELB(s) manualmente"
        log "   (aws elb/elbv2 delete-load-balancer - nunca a ENI diretamente) e rode este script de novo."
    fi
fi

log "4) terraform destroy"
terraform destroy -auto-approve
