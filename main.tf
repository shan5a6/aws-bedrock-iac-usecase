provider "aws" {
  region = var.region
}

module "vpc" {
  source           = "./modules/vpc"
  version          = "1.0.0"
  myvpc_name       = "${var.project}-${var.env}-vpc"
  myvpc_cidr       = var.vpc_cidr
  myigw_name       = "${var.project}-${var.env}-igw"
  myroute_name     = "${var.project}-${var.env}-route"
  mypubsubnet_name = "${var.project}-${var.env}-public-subnet"
  mypubsubnet_cidr = var.public_subnet_cidr
  mysecgroup_name  = "${var.project}-${var.env}-sg"
  
  tags = {
    Project = var.project
    Owner   = var.owner
    Env     = var.env
  }
}

module "ec2" {
  source        = "./modules/ec2"
  version       = "1.0.0"
  myserver_name = "${var.project}-${var.env}-server"
  instance_type = var.instance_type
  keyname       = var.key_name
  vpcsgid       = module.vpc.mysgid
  subnetid      = module.vpc.mysubnetid
  
  tags = {
    Project = var.project
    Owner   = var.owner
    Env     = var.env
  }
}