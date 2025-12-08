locals {
  name_prefix   = "${var.project}-${var.env}"
  org_policy_json = jsonencode({
    naming_convention       = "project-env-module"
    required_tags           = ["Owner", "Project", "Env"]
    allowed_regions         = ["us-east-1","eu-central-1","me-central-1"]
    allowed_services        = ["aws_vpc","aws_s3","aws_ec2"]
    allowed_modules         = ["vpc","s3","ec2"]
    default_module_versions = {
      vpc = "1.0.0"
      s3  = "1.0.0"
      ec2 = "1.0.0"
    }
    deny_list               = ["public_s3_acl","open_security_group_all"]
  })
}

resource "aws_kms_key" "ssm" {
  description         = "KMS key for SSM Org Policy encryption"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_ssm_parameter" "org_policy" {
  name        = "/${local.name_prefix}/org-policy"
  description = "Organization policy for Terraform module composition"
  type        = "String"
  value       = local.org_policy_json
  key_id      = aws_kms_key.ssm.arn
  tags        = var.tags
}
