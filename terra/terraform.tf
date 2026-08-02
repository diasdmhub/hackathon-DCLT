terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.34"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }
  }

  # Backend remoto no S3, com lock via DynamoDB. O bucket e a tabela precisam
  # existir ANTES do primeiro `terraform init` - ver instruções de bootstrap
  # no README.md deste diretório. Blocos de backend não aceitam variáveis,
  # então o nome do bucket é literal aqui; ajuste se já estiver em uso por
  # outra conta (nomes de bucket S3 são globalmente únicos).
  backend "s3" {
    bucket         = "fiap-solidarytech-terraform-state"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "fiap-solidarytech-terraform-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = module.eks.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.eks_cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.eks_cluster_name, "--region", var.aws_region]
    command     = "aws"
  }
}
