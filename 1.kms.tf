resource "aws_kms_key" "s3" {
  description         = "KMS for S3 buckets (IAC RAG)"
  enable_key_rotation = true
  tags                = var.tags
}
resource "aws_kms_key" "ddb" {
  description         = "KMS for DynamoDB (IAC RAG)"
  enable_key_rotation = true
  tags                = var.tags
}
resource "aws_kms_key" "os" {
  description         = "KMS for OpenSearch Serverless (IAC RAG)"
  enable_key_rotation = true
  tags                = var.tags
}

