variable "core_region" {
  description = "Core region hosting the platform (must support Bedrock & OpenSearch Serverless if you plan to use them here)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  type    = string
  default = "iac-rag2"
}

variable "env" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

# Optional tags applied to all resources
variable "tags" {
  type = map(string)
  default = {
    Owner   = "platform-ai-devops"
    Project = "iac-rag2"
    Env     = "prod"
  }
}

