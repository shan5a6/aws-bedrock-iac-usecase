terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source           = "./modules/vpc"
  version          = "1.0.0"
  myvpc_name       = "${var.project_name}-${var.environment}-vpc"
  myvpc_cidr       = var.vpc_cidr
  myigw_name       = "${var.project_name}-${var.environment}-igw"
  myroute_name     = "${var.project_name}-${var.environment}-route"
  mypubsubnet_name = "${var.project_name}-${var.environment}-pubsubnet"
  mypubsubnet_cidr = var.public_subnet_cidr
  mysecgroup_name  = "${var.project_name}-${var.environment}-secgroup"

  tags = {
    Owner   = var.owner
    Project = var.project_name
    Env     = var.environment
  }
}

module "ec2" {
  source        = "./modules/ec2"
  version       = "1.0.0"
  myserver_name = "${var.project_name}-${var.environment}-server"
  instance_type = var.instance_type
  keyname       = var.key_name
  vpcsgid       = module.vpc.mysgid
  subnetid      = module.vpc.mysubnetid

  tags = {
    Owner   = var.owner
    Project = var.project_name
    Env     = var.environment
  }
}