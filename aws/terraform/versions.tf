terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # State lives in S3 with a DynamoDB lock table, both created by bootstrap.sh
  # BEFORE the first init. Values are supplied with -backend-config rather than
  # hardcoded, because the bucket name differs per account and a checked-in
  # bucket name is the easiest way to point staging at production's state:
  #
  #   tofu init \
  #     -backend-config=bucket=mojo-tfstate-<account> \
  #     -backend-config=key=<project>/<env>.tfstate \
  #     -backend-config=region=<region> \
  #     -backend-config=dynamodb_table=mojo-tfstate-lock
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Env       = var.env
      ManagedBy = "opentofu"
    }
  }
}
