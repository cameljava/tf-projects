# ===============================
# Strategy 1: Per-User Bucket
# ===============================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = local.region
  default_tags {
    tags = local.common_tags
  }
}


locals {
  common_tags = {
    ManagedBy   = "Terraform"
    Environment = "dev"
    Owner       = "team-k"
  }
  region = "ap-southeast-2"
  users  = ["alice", "bob"]

}

# Random suffix to ensure bucket name uniqueness
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Create a bucket for each user
resource "aws_s3_bucket" "user_buckets" {
  for_each = toset(local.users)
  bucket   = "corp-${random_id.bucket_suffix.hex}-${each.value}"
}

# IAM user for each person
resource "aws_iam_user" "users" {
  for_each = toset(local.users)
  name     = each.value
}

# IAM policy for per-user bucket access
resource "aws_iam_policy" "per_user_bucket_policy" {
  for_each = toset(local.users)

  name        = "per-user-bucket-${each.value}"
  description = "Access only to corp-${random_id.bucket_suffix.hex}-${each.value} bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.user_buckets[each.value].arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject*"
        ]
        Resource = "${aws_s3_bucket.user_buckets[each.value].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = aws_s3_bucket.user_buckets[each.value].arn
      }
    ]
  })
}

# Attach policy to user
resource "aws_iam_user_policy_attachment" "attach_per_user" {
  for_each   = toset(local.users)
  user       = aws_iam_user.users[each.value].name
  policy_arn = aws_iam_policy.per_user_bucket_policy[each.value].arn
}

# Outputs
output "bucket_names" {
  value = {
    for user, bucket in aws_s3_bucket.user_buckets : user => bucket.bucket
  }
}

output "user_names" {
  value = [for user in aws_iam_user.users : user.name]
}
