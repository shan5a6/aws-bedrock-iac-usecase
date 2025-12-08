provider "aws" {
  region = "us-east-1"
}

# ----------------- Secret -----------------
resource "aws_secretsmanager_secret" "terraform_composer" {
  name        = "terraform-composer-credential"
  description = "Credentials for Terraform Composer UI"
  recovery_window_in_days = 7
  tags = {
    Environment = "prod"
    Application = "TerraformComposer"
  }
}

# ----------------- Secret Value -----------------
resource "aws_secretsmanager_secret_version" "terraform_composer_value" {
  secret_id     = aws_secretsmanager_secret.terraform_composer.id
  secret_string = jsonencode({
    username = "admin"    # Change this to your secure username
    password = "Admin@1234" # Change this to a secure password
  })
}

# ----------------- Optional: IAM Policy to allow Lambda or EC2 access -----------------
data "aws_iam_policy_document" "allow_secrets_access" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.terraform_composer.arn]
  }
}

resource "aws_iam_policy" "terraform_composer_secrets_policy" {
  name        = "TerraformComposerSecretsAccess"
  description = "Allows access to Terraform Composer secret"
  policy      = data.aws_iam_policy_document.allow_secrets_access.json
}

# You can attach this policy to your Lambda role or EC2 instance profile

