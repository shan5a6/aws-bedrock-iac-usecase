output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnets" {
  value = [for s in aws_subnet.private : s.id]
}

output "public_subnets" {
  value = [for s in aws_subnet.public : s.id]
}

output "s3_modules" {
  value = aws_s3_bucket.modules.bucket
}

output "s3_artifacts" {
  value = aws_s3_bucket.artifacts.bucket
}

output "ddb_catalog" {
  value = aws_dynamodb_table.catalog.name
}

