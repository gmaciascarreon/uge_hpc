terraform {
  required_version = ">= 1.5.0"

  cloud {
    organization = "HPC"

    workspaces {
      name = "uge_hpc"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are read automatically from the
# environment variables configured on the Terraform Cloud workspace.
provider "aws" {
  region = var.aws_region
}
