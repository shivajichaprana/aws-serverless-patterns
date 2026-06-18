terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

# Region, credentials, and profile are taken from the standard AWS provider
# environment (AWS_REGION / AWS_PROFILE / shared config) so the module stays
# portable across accounts. Default tags are applied to every taggable resource.
provider "aws" {
  default_tags {
    tags = local.tags
  }
}
