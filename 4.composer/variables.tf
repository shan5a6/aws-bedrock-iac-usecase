##########################
# Org Policy JSON in SSM #
##########################

variable "core_region" {
    description = "AWS region for the platform"
    type        = string
    default     = "us-east-1"
}

variable "project" {
    description = "Project name"
    type        = string
    default     = "iac-rag2"
}

variable "env" {
    description = "Environment name"
    type        = string
    default     = "prod"
}

variable "tags" {
    description = "Tags applied to all resources"
    type        = map(string)
    default = {
        Owner   = "platform-ai-devops"
        Project = "iac-rag2"
        Env     = "prod"
    }
}

variable "artifacts_bucket" {
    type = string
}

variable "retrieve_lambda_name" {
    type = string
}

variable "bedrock_model_id" {
    type    = string
    default = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}


# Fetch VPC ID based on name
data "aws_vpc" "selected" {
    filter {
        name   = "tag:Name"
        values = ["${local.name_prefix}-vpc"]
    }
}

# Fetch private subnets based on VPC ID and tags
data "aws_subnets" "private" {
    filter {
        name   = "vpc-id"
        values = [data.aws_vpc.selected.id]
    }

    filter {
        name   = "tag:Tier"
        values = ["private"]
    }
}

# Assign VPC ID and private subnets to locals
locals {
    vpc_id          = data.aws_vpc.selected.id
    private_subnets = data.aws_subnets.private.ids

}
