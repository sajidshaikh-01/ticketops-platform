terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source = "../../modules/vpc"

  project_name         = var.project_name
  environment          = "dev"
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}


module "ecr" {
  source = "../../modules/ecr"

  project_name     = var.project_name
  environment      = "dev"
  repository_names = ["events-api", "admin-api", "bookings-worker", "dashboard"]
}


module "iam" {
  source = "../../modules/iam"

  project_name = var.project_name
  environment  = "dev"
}

module "rds" {
  source = "../../modules/rds"

  project_name       = var.project_name
  environment        = "dev"
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  db_username        = var.db_username
  db_password        = var.db_password
  multi_az           = false
}

module "redis" {
  source = "../../modules/redis"

  project_name       = var.project_name
  environment        = "dev"
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
}

module "eks" {
  source = "../../modules/eks"

  project_name          = var.project_name
  environment           = "dev"
  eks_cluster_role_arn  = module.iam.eks_cluster_role_arn
  eks_node_role_arn     = module.iam.eks_node_role_arn
  public_subnet_ids     = module.vpc.public_subnet_ids
  private_subnet_ids    = module.vpc.private_subnet_ids
  instance_type         = "t3.medium"
  desired_size          = 2
}