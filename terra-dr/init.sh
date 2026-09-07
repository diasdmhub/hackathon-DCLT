#!/usr/bin/env bash
set -e
# Desabilita o pager globalmente para evitar pausa nos comandos aws
export AWS_PAGER=""

# Idêntico a terra/init.sh: o bucket S3 e a tabela DynamoDB de lock já
# existem (bootstrapados na primeira vez em terra/, ver terra/README.md) -
# os comandos abaixo são idempotentes e só garantem que existem antes do
# `terraform init` deste diretório, que aponta para a mesma tabela/bucket
# com uma "key" (dr/terraform.tfstate) diferente - ver terraform.tf.

# 1. Validação de requisitos
missing=()
for cmd in aws terraform jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done

if (( ${#missing[@]} )); then
    printf 'ERRO: os requisitos abaixo não foram encontrados. Por favor, verifique a instalação deles.\n' >&2
    for m in "${missing[@]}"; do
        printf ' Binário - %s\n' "$m" >&2
    done
    exit 1
fi

# 1.1 Verifica se o arquivo de variáveis do Terraform existe

[ -e ./terraform.tfvars ] || { printf ' Arquivo "terraform.tfvars" indisponível. Defina ele primeiro.\n'; exit 1; }

# 2. Criação do S3 bucket com idempotencia - ignora se já existir

aws s3api create-bucket \
  --bucket fiap-solidarytech-terraform-state \
  || true

aws s3api put-bucket-versioning \
  --bucket fiap-solidarytech-terraform-state \
  --versioning-configuration Status=Enabled \
  || true

aws s3api put-bucket-encryption \
  --bucket fiap-solidarytech-terraform-state \
  --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
  || true

# 3 Cria a tabela DynamoDB com idempotencia - ignora se já existir

aws dynamodb create-table \
  --table-name fiap-solidarytech-terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  || true

# 4 Inicialização do Terraform
terraform init -reconfigure -upgrade

# 5 Obtenção automática das variáveis do read replica do RDS (ver "Ativação
# (runbook)" em terra-dr/README.md) - o Postgres em si não é criado/
# restaurado por este root, só conectado (via VPC peering) ao read replica
# sempre-vivo que terra/main.tf mantém (module.rds_dr_replica).
# rds_dr_vpc_id/rds_dr_vpc_cidr/rds_dr_connection_url são lidos direto do
# state remoto de terra/ (mesmo bucket S3 do backend deste root, key
# "terraform.tfstate" - ver terraform.tf) em vez de exigir cópia manual dos
# outputs para terraform.tfvars: os dois roots continuam sem
# terraform_remote_state (nenhum acoplamento no grafo de recursos), essa
# leitura é só um `aws s3 cp` + `jq` no nível do script, e a confirmação
# interativa dos `terraform apply` abaixo já serve como ponto de checagem
# antes de qualquer mudança real. rds_dr_connection_url só reflete o
# endpoint promovido depois de terra/ ser reaplicado com
# promote_dr_db = true - se ainda não promovido, ou se terra/ estiver com
# enable_dr = false, o fetch fica vazio e cai para o valor em
# terraform.tfvars (se preenchido).
remote_output() {
    local name="$1"
    aws s3 cp --region us-east-1 \
      "s3://fiap-solidarytech-terraform-state/terraform.tfstate" - 2>/dev/null \
        | jq -r --arg n "$name" '.outputs[$n].value // empty' 2>/dev/null || true
}

fetched_rds_dr_vpc_id=$(remote_output dr_standby_vpc_id)
fetched_rds_dr_vpc_cidr=$(remote_output dr_standby_vpc_cidr)
fetched_rds_dr_connection_url=$(remote_output dr_replica_connection_url)

[ -n "$fetched_rds_dr_vpc_id" ] && export TF_VAR_rds_dr_vpc_id="$fetched_rds_dr_vpc_id"
[ -n "$fetched_rds_dr_vpc_cidr" ] && export TF_VAR_rds_dr_vpc_cidr="$fetched_rds_dr_vpc_cidr"
[ -n "$fetched_rds_dr_connection_url" ] && export TF_VAR_rds_dr_connection_url="$fetched_rds_dr_connection_url"

tfvar() {
    local key="$1" val
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" terraform.tfvars | tail -n1 \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?[[:space:]]*(#.*)?\$/\1/" \
        | sed -E 's/[[:space:]]+$//')
    printf '%s' "$val"
}

missing_vars=()
for key in rds_dr_vpc_id rds_dr_vpc_cidr rds_dr_connection_url; do
    env_var="TF_VAR_${key}"
    if [ -n "${!env_var:-}" ]; then
        continue
    fi
    val=$(tfvar "$key")
    if [ -z "$val" ] || [ "$val" = "CHANGE_ME" ]; then
        missing_vars+=("$key")
    fi
done

if (( ${#missing_vars[@]} )); then
    printf 'ERRO: as variáveis abaixo não foram obtidas automaticamente do state de terra/ (confira enable_dr = true e, para rds_dr_connection_url, promote_dr_db = true) nem estão preenchidas em terraform.tfvars:\n' >&2
    for v in "${missing_vars[@]}"; do
        printf ' - %s\n' "$v" >&2
    done
    exit 1
fi

# 6 Apply do module.eks isolado - mesma limitação de Terraform+EKS de
# terra/ (os providers kubernetes/helm/kubectl não conseguem se conectar
# antes do cluster existir no state) - ver "Uso" em terra/README.md.
terraform plan -target=module.eks
terraform apply -target=module.eks

# 7 Plan/apply do restante (ativação do ambiente passivo: VPC peering até o
# replica já promovido, EKS/NLB/Flux/observabilidade).
terraform plan
terraform apply
