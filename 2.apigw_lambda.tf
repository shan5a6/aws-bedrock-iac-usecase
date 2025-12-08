data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "index.py"
  output_path = "lambda_stub.zip"
}

resource "aws_security_group" "lambda_vpc" {
    name   = "${local.name_prefix}-lambda-sg"
    vpc_id = aws_vpc.this.id

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

resource "aws_lambda_function" "retrieve" {
    function_name = "${local.name_prefix}-retrieve"
    role          = aws_iam_role.service.arn
    handler       = "index.handler"
    runtime       = "python3.12"
    filename      = data.archive_file.lambda_zip.output_path # create a tiny zip with handler returning 200 OK
    timeout       = 30

    vpc_config {
        subnet_ids         = [for s in aws_subnet.private : s.id]
        security_group_ids = [aws_security_group.lambda_vpc.id]
    }

    environment {
        variables = {
            AOSS_COLLECTION = aws_opensearchserverless_collection.this.name
            ROLE_NAME       = aws_iam_role.service.name
        }
    }

    depends_on = [aws_opensearchserverless_access_policy.data]
    tags       = var.tags
}

resource "aws_lambda_function" "compose" {
    function_name = "${local.name_prefix}-compose"
    role          = aws_iam_role.service.arn
    handler       = "index.handler"
    runtime       = "python3.12"
    filename      = data.archive_file.lambda_zip.output_path
    timeout       = 60

    vpc_config {
        subnet_ids         = [for s in aws_subnet.private : s.id]
        security_group_ids = [aws_security_group.lambda_vpc.id]
    }

    environment {
        variables = {
            ARTIFACTS_BUCKET = aws_s3_bucket.artifacts.bucket
            ROLE_NAME       = aws_iam_role.service.name
        }
    }

    tags = var.tags
}

resource "aws_apigatewayv2_api" "private" {
    name          = "${local.name_prefix}-api"
    protocol_type = "HTTP"
    tags          = var.tags
}

resource "aws_apigatewayv2_integration" "retrieve" {
    api_id                 = aws_apigatewayv2_api.private.id
    integration_type       = "AWS_PROXY"
    integration_uri        = aws_lambda_function.retrieve.arn
    payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "compose" {
    api_id                 = aws_apigatewayv2_api.private.id
    integration_type       = "AWS_PROXY"
    integration_uri        = aws_lambda_function.compose.arn
    payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_retrieve" {
    api_id    = aws_apigatewayv2_api.private.id
    route_key = "POST /retrieve-and-compose"
    target    = "integrations/${aws_apigatewayv2_integration.retrieve.id}"
}

resource "aws_apigatewayv2_route" "post_generate" {
    api_id    = aws_apigatewayv2_api.private.id
    route_key = "POST /generate-iac"
    target    = "integrations/${aws_apigatewayv2_integration.compose.id}"
}

resource "aws_lambda_permission" "apigw_retrieve" {
    statement_id  = "AllowAPIGatewayInvokeRetrieve"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.retrieve.arn
    principal     = "apigateway.amazonaws.com"
    source_arn    = "${aws_apigatewayv2_api.private.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_compose" {
    statement_id  = "AllowAPIGatewayInvokeCompose"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.compose.arn
    principal     = "apigateway.amazonaws.com"
    source_arn    = "${aws_apigatewayv2_api.private.execution_arn}/*/*"
}

