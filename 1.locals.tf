locals {
  name_prefix = "${var.project}-${var.env}"
  azs         = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {}

