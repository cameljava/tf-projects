# ===============================
# Strategy 2: Shared Bucket
# With Pre-created User Folders
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

# Shared bucket
resource "aws_s3_bucket" "shared" {
  bucket = "corp-shared-${random_id.bucket_suffix.hex}"
}

# Random suffix to ensure bucket name uniqueness
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Create empty "folders" for each user
# no folder in s3, just object with prefix key which looks like a folder.
# optional,  otherwise when you upload a file with proper folder path, it will create "folder" as well.
resource "aws_s3_object" "user_folders" {
  for_each = toset(local.users)

  bucket = aws_s3_bucket.shared.bucket
  key    = "${each.value}/" # <-- trailing slash creates "folder" in console

  content = "" # zero-byte object
}

# IAM users
resource "aws_iam_user" "users" {
  for_each = toset(local.users)
  name     = each.value
}

# IAM policy per user (shared bucket)
resource "aws_iam_policy" "shared_policy" {
  for_each = toset(local.users)

  name        = "shared-bucket-${each.value}"
  description = "Access only to ${each.value}/* inside corp-shared"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.shared.arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "",
              "${each.value}/*"
            ]
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject*"
        ]
        Resource = "${aws_s3_bucket.shared.arn}/${each.value}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = aws_s3_bucket.shared.arn
      }
    ]
  })
}

# Attach policy to each user
resource "aws_iam_user_policy_attachment" "attach_shared" {
  for_each   = toset(local.users)
  user       = aws_iam_user.users[each.value].name
  policy_arn = aws_iam_policy.shared_policy[each.value].arn
}

output "bucket_name" {
  value = aws_s3_bucket.shared.bucket
}

output "user_names" {
  value = [for user in aws_iam_user.users : user.name]
}