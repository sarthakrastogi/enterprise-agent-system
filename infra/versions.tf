terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state by default so `make deploy` works out of the box.
  # For a team, switch to S3 (with use_lockfile = true) before the first apply:
  # backend "s3" {
  #   bucket       = "my-tf-state"
  #   key          = "enterprise-agent-platform/terraform.tfstate"
  #   region       = "us-west-2"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      managed-by = "terraform"
    }
  }
}
