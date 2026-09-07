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

# 5 Obtenção automática das variáveis derivadas do state de terra/ (ver
# "Ativação (runbook)" em terra-dr/README.md): rds_dr_vpc_id/
# rds_dr_vpc_cidr/rds_dr_connection_url (VPC peering até o read replica
# sempre-vivo, module.rds_dr_replica) e route53_zone_id (registro SECONDARY
# de failover DNS, só relevante se terra/ tiver manage_dns = true). Lidas
# direto do state remoto de terra/ (mesmo bucket S3 do backend deste root,
# key "terraform.tfstate" - ver terraform.tf) via `aws s3 cp` + `jq` no
# nível do script - os dois roots continuam sem terraform_remote_state
# (nenhum acoplamento no grafo de recursos), e a confirmação interativa dos
# `terraform apply` abaixo já serve como ponto de checagem antes de
# qualquer mudança real.
#
# Passadas via `-var` (maior precedência do Terraform, sempre vence
# terraform.tfvars) em vez de `export TF_VAR_*`: variável de ambiente é a
# MENOR precedência, então um `terraform.tfvars` com o placeholder
# "CHANGE_ME" (mantido como fallback) sempre venceria o valor obtido aqui
# se fosse só exportado - é exatamente esse bug que fazia os valores
# chegarem como "CHANGE_ME" no Terraform mesmo com o fetch funcionando.
#
# rds_dr_connection_url só reflete o endpoint promovido depois de terra/
# ser reaplicado com promote_dr_db = true. Se o fetch de uma variável vier
# vazio (terra/ com enable_dr/manage_dns = false, ou ainda não promovido),
# cai para o valor em terraform.tfvars.
remote_output() {
    local name="$1"
    aws s3 cp --region us-east-1 \
      "s3://fiap-solidarytech-terraform-state/terraform.tfstate" - 2>/dev/null \
        | jq -r --arg n "$name" '.outputs[$n].value // empty' 2>/dev/null || true
}

tfvar() {
    local key="$1" val
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" terraform.tfvars | tail -n1 \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?[[:space:]]*(#.*)?\$/\1/" \
        | sed -E 's/[[:space:]]+$//')
    printf '%s' "$val"
}

# terraform_var:terra_output:required|optional - route53_zone_id é opcional
# porque "" é o default documentado (failover de DNS desligado), não um
# placeholder esquecido; os outros 3 são sempre obrigatórios.
auto_var_map=(
    "rds_dr_vpc_id:dr_standby_vpc_id:required"
    "rds_dr_vpc_cidr:dr_standby_vpc_cidr:required"
    "rds_dr_connection_url:dr_replica_connection_url:required"
    "route53_zone_id:route53_zone_id:optional"
)

auto_vars=()
missing_vars=()
for entry in "${auto_var_map[@]}"; do
    IFS=':' read -r key output_name mode <<< "$entry"
    fetched=$(remote_output "$output_name")
    if [ -n "$fetched" ]; then
        auto_vars+=("-var=${key}=${fetched}")
        continue
    fi
    val=$(tfvar "$key")
    if [ "$val" = "CHANGE_ME" ] || { [ -z "$val" ] && [ "$mode" = "required" ]; }; then
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
terraform plan -target=module.eks "${auto_vars[@]}"
terraform apply -target=module.eks "${auto_vars[@]}"

# 7 Plan/apply do restante (ativação do ambiente passivo: VPC peering até o
# replica já promovido, EKS/NLB/Flux/observabilidade).
terraform plan "${auto_vars[@]}"
terraform apply "${auto_vars[@]}"
