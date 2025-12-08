core_region            = "us-east-1"
project                = "iac-rag2"
env                    = "prod"
tags = {
    Owner   = "platform-ai-devops"
    Project = "iac-rag2"
    Env     = "prod"
}

artifacts_bucket       = "iac-rag2-prod-artifacts" # Make sure you are copying name from s3 bucket from infra code
retrieve_lambda_name   = "iac-rag2-prod-retrieve-v2" # Make sure you are copying name from lambda from infra code
bedrock_model_id       = "anthropic.claude-3-5-sonnet-20240620-v1:0"
