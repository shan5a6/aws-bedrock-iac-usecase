core_region            = "us-east-1"
project                = "iac-rag11"
env                    = "prod"
tags = {
    Owner   = "platform-ai-devops"
    Project = "iac-rag11"
    Env     = "prod"
}

artifacts_bucket       = "iac-rag11-prod-artifacts" # Make sure you are copying name from s3 bucket from infra code
retrieve_lambda_name   = "iac-rag11-prod-retrieve-v2" # Make sure you are copying name from lambda from infra code
bedrock_model_id       = "anthropic.claude-3-5-sonnet-20240620-v1:0"
