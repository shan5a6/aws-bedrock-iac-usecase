output "vpc_name" {
  value = module.vpc.myvpcname
}

output "public_subnet_id" {
  value = module.vpc.mysubnetid
}

output "security_group_id" {
  value = module.vpc.mysgid
}

output "ec2_instance_name" {
  value = module.ec2.myservername
}

output "ec2_public_ip" {
  value = module.ec2.publicip
}