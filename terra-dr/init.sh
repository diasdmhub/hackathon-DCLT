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
for cmd in aws terraform; do
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

# 5 Plan do Terraform
#terraform plan

# 6 Apply do Terraform (ativação do ambiente passivo - ver terra-dr/README.md
# para as variáveis que precisam ser passadas, como rds_restore_source_arn)
#terraform apply
