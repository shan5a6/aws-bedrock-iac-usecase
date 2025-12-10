provider "aws" {
  region = "us-east-1"
}

# ------------------------------
# Lambda Layer with dependencies
# ------------------------------
resource "null_resource" "build_layer" {
  triggers = {
    requirements_sha = filesha256("lambda/requirements.txt")
  }
  provisioner "local-exec" {
    command = <<EOT
mkdir -p build/layer/python
pip install -r lambda/requirements.txt -t build/layer/python
(cd build/layer && zip -r ../../build/retrieval-deps-layer.zip python)
EOT
  }
}

resource "aws_lambda_layer_version" "compose_deps" {
  filename           = "build/retrieval-deps-layer.zip"
  layer_name         = "${local.name_prefix}-deps"
  compatible_runtimes = ["python3.12"]
  #source_code_hash    = data.archive_file.layer_zip.output_base64sha256
  depends_on          = [null_resource.build_layer]
}

# ------------------------------
# Lambda function zip
# ------------------------------
resource "null_resource" "build_function" {
  # Triggers force rebuild when compose.py changes
  triggers = {
    compose_sha = filesha256("lambda/compose.py")
  }

  provisioner "local-exec" {
    command = <<EOT
mkdir -p build/function
cp lambda/compose.py build/function/
(cd build/function && zip -r9 --quiet  ../../build/lambda_compose.zip . -X)
EOT
  }
}

# ------------------------------
# IAM Role for Compose Lambda
# ------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "compose" {
  name               = "${local.name_prefix}-compose-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_policy" "compose" {
  name        = "${local.name_prefix}-compose-policy"
  description = "Compose Lambda permissions for S3, Bedrock, Lambda invoke, logs"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "S3RW"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "*"
        ]
      },
      {
        Sid    = "LambdaInvokeRetrieve"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = "*"
      },
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = ["bedrock:*","aws-marketplace:ViewSubscriptions","aws-marketplace:Subscribe"]
        Resource = "*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:*"]
        Resource = "*"
      },
      {
        Sid    = "VPCENIAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AttachNetworkInterface"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "kms:GenerateDataKey",
              "kms:Decrypt",
              "kms:Encrypt"
          ],
          "Resource": "*"
      }

    ]
  })
}

resource "aws_iam_role_policy_attachment" "compose_attach" {
  role       = aws_iam_role.compose.name
  policy_arn = aws_iam_policy.compose.arn
}

# ------------------------------
# Security Group
# ------------------------------

resource "aws_security_group" "compose_lambda" {
  name   = "${local.name_prefix}-compose-lambda-sg"
  vpc_id = local.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # adjust as per your VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# ------------------------------
# Compose Lambda Function
# ------------------------------
resource "aws_lambda_function" "compose" {
  function_name = "${local.name_prefix}-compose-v2"
  handler       = "compose.handler"
  runtime       = "python3.12"
  role          = aws_iam_role.compose.arn
  filename         = "build/lambda_compose.zip"
  #source_code_hash = filebase64sha256("build/lambda_compose.zip")
  timeout       = 300
  # lifecycle {
  #   ignore_changes = [source_code_hash]
  # }
  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.compose_lambda.id]
  }

  environment {
    variables = {
      ARTIFACTS_BUCKET = var.artifacts_bucket
      RETRIEVE_LAMBDA  = var.retrieve_lambda_name
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  layers = [aws_lambda_layer_version.compose_deps.arn]


  # reserved_concurrent_executions = 1 # Increase the values to enable concurrency based on your needs

  depends_on = [null_resource.build_function]
  tags       = var.tags
}

# ------------------------------
# Lambda Function URL
# ------------------------------
resource "aws_lambda_function_url" "compose_url" {
  function_name      = aws_lambda_function.compose.function_name
  authorization_type = "AWS_IAM"
}

# output "compose_lambda_arn" {
#   value = aws_lambda_function.compose.arn
# }

# output "compose_lambda_url" {
#   value = aws_lambda_function_url.compose.function_url
# }
# output "compose_lambda_role" {
#   value = aws_iam_role.compose.arn
# }
