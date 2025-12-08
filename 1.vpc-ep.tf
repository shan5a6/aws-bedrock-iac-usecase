# Security Group for VPC Interface Endpoints (only VPC internal)
resource "aws_security_group" "vpce" {
  name        = "${local.name_prefix}-vpce-sg"
  description = "Interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# Helper local to pick correct service names
locals {
  vpce_services = {
    s3              = "com.amazonaws.${var.core_region}.s3"
    dynamodb        = "com.amazonaws.${var.core_region}.dynamodb"
    bedrock_runtime = "com.amazonaws.${var.core_region}.bedrock-runtime"
    bedrock_agent   = "com.amazonaws.${var.core_region}.bedrock-agent-runtime"
    secretsmanager  = "com.amazonaws.${var.core_region}.secretsmanager"
    logs            = "com.amazonaws.${var.core_region}.logs"
    aoss            = "com.amazonaws.${var.core_region}.aoss" # OpenSearch Serverless
  }
}

# Interface VPC Endpoints
resource "aws_vpc_endpoint" "interface" {
  for_each            = { for k, v in local.vpce_services : k => v if k != "s3" && k != "dynamodb" && k != "aoss"}
  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  subnet_ids          = [for s in aws_subnet.private : s.id]
  tags                = merge(var.tags, { Name = "${local.name_prefix}-vpce-${each.key}" })
}

# Gateway endpoints for S3 and DynamoDB
resource "aws_vpc_endpoint" "gw_s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = local.vpce_services.s3
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], [for rt in aws_route_table.private : rt.id])
  tags              = merge(var.tags, { Name = "${local.name_prefix}-vpce-s3" })
}

resource "aws_vpc_endpoint" "gw_ddb" {
  vpc_id            = aws_vpc.this.id
  service_name      = local.vpce_services.dynamodb
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], [for rt in aws_route_table.private : rt.id])
  tags              = merge(var.tags, { Name = "${local.name_prefix}-vpce-dynamodb" })
}

# Interface endpoint for OpenSearch Serverless (AOSS)
resource "aws_opensearchserverless_vpc_endpoint" "aoss" {
  name         = "${local.name_prefix}-aoss-vpce"
  vpc_id       = aws_vpc.this.id
  subnet_ids   = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.vpce.id]
  # tags attribute removed as it is not supported
}

