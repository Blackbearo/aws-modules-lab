terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

module "vpc" {
  source   = "../../modules/vpc"
  env_name = var.env_name
  vpc_cidr = var.vpc_cidr
}

module "web_tier" {
  source             = "../../modules/web-tier"
  env_name           = var.env_name
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  ami_id             = var.ami_id
  instance_type      = var.instance_type
  min_size           = var.min_size
  max_size           = var.max_size
  admin_cidrs        = var.admin_cidrs
  vpc_cidr           = var.vpc_cidr
}

module "db" {
  source                = "../../modules/database"
  env_name              = var.env_name
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnet_ids
  app_security_group_id = module.web_tier.app_sg_id
  instance_class        = var.db_instance_class
  db_password           = var.db_password
  vpc_cidr              = var.vpc_cidr
}
