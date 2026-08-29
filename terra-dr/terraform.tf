terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.6"
    }
  }

  # Mesmo bucket/tabela de lock do ambiente ativo (terra/terraform.tf) - já
  # bootstrapados por terra/init.sh, não precisam ser recriados aqui. Só a
  # "key" muda, para um state independente do ambiente ativo (nunca aplicado
  # por padrão - "ativar" o ambiente passivo é rodar `terraform apply`
  # aqui pela primeira vez, ou de novo após um `terraform destroy` de um
  # simulado anterior). Ver terra-dr/README.md.
  backend "s3" {
    bucket         = "fiap-solidarytech-terraform-state"
    key            = "dr/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "fiap-solidarytech-terraform-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "DR"
      ManagedBy   = "Terraform"
      CostCenter  = "NGO-Core"
    }
  }
}

provider "dns" {}

provider "kubernetes" {
  host                   = module.eks.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.eks_cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.eks_cluster_name, "--region", var.aws_region]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.eks_cluster_ca)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.eks_cluster_name, "--region", var.aws_region]
      command     = "aws"
    }
  }
}

provider "kubectl" {
  host                   = module.eks.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.eks_cluster_ca)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.eks_cluster_name, "--region", var.aws_region]
    command     = "aws"
  }
}
