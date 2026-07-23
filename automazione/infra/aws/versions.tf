terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0, < 7.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Supply the bucket, key, region and DynamoDB/S3 lock settings at init time.
  # State storage is deliberately not bootstrapped by this stack.
  backend "s3" {}
}
