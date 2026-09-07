#!/usr/bin/env bash
set -e
# Desabilita o pager globalmente para evitar pausa nos comandos aws
export AWS_PAGER=""

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

# Região do backend remoto (bucket S3 + tabela DynamoDB de lock) - igual em
# terraform.tf (backend "s3"). Fica em us-west-2 (a região de DR), não em
# us-east-1 (a região ativa), para o backend continuar acessível mesmo se a
# região ativa estiver indisponível - ver o comentário em terraform.tf.
BACKEND_REGION="us-west-2"

# 2. Criação do S3 bucket com idempotencia - ignora se já existir

# 2.1 Cria S3 bucket - LocationConstraint é obrigatório para qualquer região
# além de us-east-1 (que é tratada como caso especial pela API do S3)
aws s3api create-bucket \
  --bucket fiap-solidarytech-terraform-state \
  --region "$BACKEND_REGION" \
  --create-bucket-configuration LocationConstraint="$BACKEND_REGION" \
  || true

# 2.2 Habilita o versionamento do bucket
aws s3api put-bucket-versioning \
  --bucket fiap-solidarytech-terraform-state \
  --region "$BACKEND_REGION" \
  --versioning-configuration Status=Enabled \
  || true

# 2.3 Habilita a criptografia do bucket
aws s3api put-bucket-encryption \
  --bucket fiap-solidarytech-terraform-state \
  --region "$BACKEND_REGION" \
  --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
  || true

# 3 Cria a tabela DynamoDB com idempotencia - ignora se já existir

# 3.1 Cria a tabela DynamoDB
aws dynamodb create-table \
  --table-name fiap-solidarytech-terraform-lock \
  --region "$BACKEND_REGION" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  || true


# 4 Inicialização do Terraform
terraform init -reconfigure -upgrade

# 5 Plan do Terraform
#terraform plan

# 6 Apply do Terraform
#terraform apply
