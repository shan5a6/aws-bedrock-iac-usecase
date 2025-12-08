# Ingestion role (reads S3, writes AOSS & DDB)
resource "aws_iam_role" "ingestion" {
    name               = "${local.name_prefix}-ingestion"
    assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
    tags               = var.tags
}

resource "aws_iam_role" "service" {
    name               = "${local.name_prefix}-service"
    assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
    tags               = var.tags
}

data "aws_iam_policy_document" "lambda_assume" {
    statement {
        actions = ["sts:AssumeRole"]
        principals {
            type        = "Service"
            identifiers = ["lambda.amazonaws.com"]
        }
    }
}

resource "aws_iam_policy" "ingestion" {
    name        = "${local.name_prefix}-ingestion-policy"
    description = "Ingestion permissions"
    policy = jsonencode({
        Version   = "2012-10-17",
        Statement = [
            {
                Sid    = "S3Read",
                Effect = "Allow",
                Action = ["s3:GetObject", "s3:ListBucket"],
                Resource = [
                    aws_s3_bucket.modules.arn,
                    "${aws_s3_bucket.modules.arn}/*"
                ]
            },
            {
                Sid    = "DDBWrite",
                Effect = "Allow",
                Action = ["dynamodb:PutItem", "dynamodb:BatchWriteItem", "dynamodb:UpdateItem"],
                Resource = aws_dynamodb_table.catalog.arn
            },
            {
                Sid    = "AOSSWrite",
                Effect = "Allow",
                Action = ["aoss:APIAccessAll"],
                Resource = "*"
            },
            {
                Sid    = "KMS",
                Effect = "Allow",
                Action = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"],
                Resource = [
                    aws_kms_key.s3.arn,
                    aws_kms_key.ddb.arn,
                    aws_kms_key.os.arn
                ]
            },
            {
                Sid    = "Logs",
                Effect = "Allow",
                Action = ["logs:*"],
                Resource = "*"
            }
        ]
    })
}

resource "aws_iam_policy" "service" {
    name        = "${local.name_prefix}-service-policy"
    description = "Retrieval/compose permissions"
    policy = jsonencode({
        Version   = "2012-10-17",
        Statement = [
            {
                Sid    = "S3RW",
                Effect = "Allow",
                Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
                Resource = [
                    aws_s3_bucket.artifacts.arn,
                    "${aws_s3_bucket.artifacts.arn}/*"
                ]
            },
            {
                Sid    = "DDBRead",
                Effect = "Allow",
                Action = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan"],
                Resource = aws_dynamodb_table.catalog.arn
            },
            {
                Sid    = "AOSSRead",
                Effect = "Allow",
                Action = ["aoss:APIAccessAll"],
                Resource = "*"
            },
            {
                Sid    = "BedrockInvoke",
                Effect = "Allow",
                Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
                Resource = "*"
            },
            {
                Sid    = "KMS",
                Effect = "Allow",
                Action = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"],
                Resource = [
                    aws_kms_key.s3.arn,
                    aws_kms_key.ddb.arn,
                    aws_kms_key.os.arn
                ]
            },
            {
                Sid    = "Logs",
                Effect = "Allow",
                Action = ["logs:*"],
                Resource = "*"
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "ingestion_attach" {
    role       = aws_iam_role.ingestion.name
    policy_arn = aws_iam_policy.ingestion.arn
}

resource "aws_iam_role_policy_attachment" "service_attach" {
    role       = aws_iam_role.service.name
    policy_arn = aws_iam_policy.service.arn
}

/*lambda*/

resource "aws_iam_role_policy" "lambda_vpc_permissions" {
    name = "${local.name_prefix}-lambda-vpc-policy"
    role = aws_iam_role.service.name

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Action = [
                    "ec2:CreateNetworkInterface",
                    "ec2:DescribeNetworkInterfaces",
                    "ec2:DeleteNetworkInterface"
                ]
                Resource = "*"
            },
            {
                Effect = "Allow"
                Action = [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                ]
                Resource = "arn:aws:logs:*:*:*"
            }
        ]
    })
}

