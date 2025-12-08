# ------------------------
# OpenSearch Security Policies
# ------------------------

# Encryption policy (must use AWS-owned KMS key)
resource "aws_opensearchserverless_security_policy" "encryption" {
  name  = "${local.name_prefix}-enc"
  type  = "encryption"

  policy = jsonencode({
    Rules = [
      {
        Resource = ["collection/${local.name_prefix}-vec"],
        ResourceType = "collection"
      }
    ],
    AWSOwnedKey = true
  })
}

# ------------------------
# OpenSearch Network Policy
# ------------------------
# The collection must allow traffic from all Lambda VPC endpoints that need access.
# - aws_vpc_endpoint.interface: all interface endpoints (Bedrock, SecretsManager, etc.)
# - aws_opensearchserverless_vpc_endpoint.aoss: the AOSS VPCE itself
# Using concat() ensures a single list of IDs is provided to SourceVPCEs.

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name_prefix}-net"
  type = "network"

  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "collection"
          Resource     = ["collection/${local.name_prefix}-vec"]
        }
      ]
      # Allow public access
      AllowFromPublic = true
      # # Explicitly list VPCE IDs
      # SourceVPCEs = concat(
      #   [
      #     for _, v in aws_vpc_endpoint.interface : v.id
      #   ],
      #   [
      #     aws_opensearchserverless_vpc_endpoint.aoss.id
      #   ]
      # )
    }
  ])
}


# ------------------------
# OpenSearch Collection
# ------------------------
# Collection
# Collection (depends on both policies)
resource "aws_opensearchserverless_collection" "this" {
  name        = "${local.name_prefix}-vec"
  type        = "VECTORSEARCH"
  description = "Vector + keyword index for TF modules"
  tags        = var.tags

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}

# ------------------------
# Access Policy
# ------------------------
resource "aws_opensearchserverless_access_policy" "data" {
  name        = "${local.name_prefix}-access"
  type        = "data"
  description = "Data access policy"

  policy = jsonencode([{
    Description = "Allow specific IAM principals",
    Rules = [
      {
        ResourceType = "collection",
        Resource     = ["collection/${local.name_prefix}-vec"],
        Permission   = ["aoss:*"]
      },
      {
        ResourceType = "index",
        Resource     = ["index/${local.name_prefix}-vec/*"],
        Permission   = ["aoss:*"]
      }
    ],
    Principal = [
      aws_iam_role.ingestion.arn,
      aws_iam_role.service.arn,
      "arn:aws:iam::173148986443:user/bedrock-usecase-user"
    ]
  }])
}


