/* Packing the lambda with dependencies in a single zip */

locals {
    lambda_name    = "${local.name_prefix}-retrieve-v2"
}

/* iam policy */
resource "aws_iam_policy" "lambda_retrieve_policy" {
  name        = "${local.lambda_name}-policy"
  description = "IAM policy for Lambda to access AOSS, S3, DynamoDB, and Bedrock"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AOSSAccess"
        Effect = "Allow"
        Action = ["aoss:APIAccessAll"]
        Resource = [
          aws_opensearchserverless_collection.this.arn
        ]
      },
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.modules.arn,
          "${aws_s3_bucket.modules.arn}/*",
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = ["dynamodb:GetItem","dynamodb:BatchGetItem","dynamodb:Query","dynamodb:Scan"]
        Resource = aws_dynamodb_table.catalog.arn
      },
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:*"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_retrieve_attach" {
  role       = aws_iam_role.service.name
  policy_arn = aws_iam_policy.lambda_retrieve_policy.arn
}


resource "aws_lambda_layer_version" "deps" {
  filename            = "${path.module}/retrieval-deps-layer.zip"
  layer_name          = "${local.lambda_name}-deps"
  compatible_runtimes = ["python3.12"]
  description         = "Dependencies layer"
}

# Lambda function for retrieval
resource "aws_lambda_function" "retrieve_v2" {
  function_name = local.lambda_name
  role          = aws_iam_role.service.arn
  handler       = "retrieve.handler"
  runtime       = "python3.12"
  filename      = "${path.module}/lambda_retrieve.zip"
  memory_size   = 1024
  timeout       = 15
  layers        = [aws_lambda_layer_version.deps.arn]

  vpc_config {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.lambda_vpc_retrieve.id]
  }

  environment {
    variables = {
      CORE_REGION           = var.core_region
      BEDROCK_REGION        = var.core_region
      AOSS_HOST             = replace(aws_opensearchserverless_collection.this.collection_endpoint, "https://", "")
      AOSS_INDEX            = aws_opensearchserverless_collection.this.name
      AOSS_KNN_DIM          = "1024"
      KNN_K                 = "100"
      BM25_SIZE             = "100"
      RRF_K                 = "60"
      TOP_K                 = "20"
      EMBED_MAX_CHARS       = "8000"
      BEDROCK_EMBED_MODEL   = "amazon.titan-embed-text-v2:0"
      LOG_LEVEL             = "INFO"
      DDB_TABLE             = aws_dynamodb_table.catalog.name
      MODULES_BUCKET        = aws_s3_bucket.modules.bucket
      ARTIFACTS_BUCKET      = aws_s3_bucket.artifacts.bucket
      POLICY_PARAM_NAME     = "/${local.name_prefix}/org-policy"
      VPC_ENDPOINT_AOSS     = aws_opensearchserverless_vpc_endpoint.aoss.id
      VPC_ENDPOINT_BEDROCK  = aws_vpc_endpoint.interface["bedrock_runtime"].id
      VPC_ENDPOINT_DDB      = aws_vpc_endpoint.gw_ddb.id
      VPC_ENDPOINT_S3       = aws_vpc_endpoint.gw_s3.id
    }
  }

  publish   = true
  depends_on = [
    aws_opensearchserverless_collection.this,
    aws_opensearchserverless_access_policy.data,
    aws_iam_role.service
  ]

  tags = var.tags
}

# Security group for Lambda in VPC
resource "aws_security_group" "lambda_vpc_retrieve" {
  name        = "${local.lambda_name}-sg"
  vpc_id      = aws_vpc.this.id
  description = "Lambda SG for retrieval service"

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

# Publish a version + alias
resource "aws_lambda_alias" "live_v2" {
  function_name    = aws_lambda_function.retrieve_v2.function_name
  function_version = aws_lambda_function.retrieve_v2.version
  name             = "live"
}

variable "enable_provisioned_concurrency" {
  type    = bool
  default = false
}

resource "aws_lambda_provisioned_concurrency_config" "pc_v2" {
  count                             = var.enable_provisioned_concurrency ? 1 : 0
  function_name                     = aws_lambda_function.retrieve_v2.function_name
  qualifier                         = aws_lambda_alias.live_v2.name
  provisioned_concurrent_executions = 1
}

# Function URL
resource "aws_lambda_function_url" "url_v2" {
  function_name      = aws_lambda_function.retrieve_v2.function_name
  authorization_type = "AWS_IAM"
}

output "retrieve_v2_function_url" {
  value = aws_lambda_function_url.url_v2.function_url
}

output "vpc_endpoint_ids" {
  value = {
    AOSS     = aws_opensearchserverless_vpc_endpoint.aoss.id
    BEDROCK  = aws_vpc_endpoint.interface["bedrock_runtime"].id
    DDB      = aws_vpc_endpoint.gw_ddb.id
    S3       = aws_vpc_endpoint.gw_s3.id
  }
}


