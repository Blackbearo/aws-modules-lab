terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

module "vpc" {
  source     = "../../modules/vpc"
  env_name   = "eks"
  vpc_cidr   = "10.50.0.0/16"
  azs        = ["ap-northeast-1a", "ap-northeast-1c"] # EKS 至少要 2 個 AZ 的 subnet
  enable_nat = true
}
