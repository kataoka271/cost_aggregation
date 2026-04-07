###############################################################################
# AWS Billing Role Setup for Multi-OU Cost Aggregation
#
# Design: no management/payer account required.
# Each target account gets its own provider alias that assumes a Terraform
# deployer role (terraform_role_arns variable) directly in that account.
#
# Prerequisites:
#   - A Terraform deployer role exists in each target account
#     (e.g. TerraformDeployerRole with IAM write permissions)
#   - aws sso login --profile <your-profile>  (or equivalent credentials)
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
  }
}

###############################################################################
# Variables
###############################################################################

variable "billing_role_name" {
  description = "Base name for the IAM role created in each target account"
  type        = string
  default     = "DatabricksBillingRole"
}

variable "databricks_account_id" {
  description = "AWS Account ID where the Databricks cluster runs"
  type        = string
}

variable "databricks_role_arn" {
  description = "IAM Role ARN of the Databricks cluster instance profile"
  type        = string
}

variable "terraform_role_arns" {
  description = <<-EOT
    Map of AWS Account ID -> Terraform deployer role ARN.
    Terraform assumes this role to create IAM resources in each account.
    Example:
      {
        "111111111111" = "arn:aws:iam::111111111111:role/TerraformDeployerRole"
        "222222222222" = "arn:aws:iam::222222222222:role/TerraformDeployerRole"
      }
  EOT
  type        = map(string)
}

###############################################################################
# Per-account provider aliases
#
# Each alias assumes the Terraform deployer role directly in that account.
# Add one provider block and one module call for every new account.
#
# Accounts (update when ou_accounts changes in terraform.tfvars):
#   production : 111111111111, 222222222222, 333333333333
#   staging    : 444444444444, 555555555555
#   sandbox    : 666666666666
###############################################################################

provider "aws" {
  alias  = "account_111111111111"
  region = "us-east-1"
  assume_role {
    role_arn = var.terraform_role_arns["111111111111"]
  }
}

provider "aws" {
  alias  = "account_222222222222"
  region = "us-east-1"
  assume_role {
    role_arn = var.terraform_role_arns["222222222222"]
  }
}

provider "aws" {
  alias  = "account_333333333333"
  region = "us-east-1"
  assume_role {
    role_arn = var.terraform_role_arns["333333333333"]
  }
}

provider "aws" {
  alias  = "account_444444444444"
  region = "us-east-1"
  assume_role {
    role_arn = var.terraform_role_arns["444444444444"]
  }
}

provider "aws" {
  alias  = "account_555555555555"
  region = "us-east-1"
  assume_role {
    role_arn = var.terraform_role_arns["555555555555"]
  }
}

provider "aws" {
  alias  = "account_666666666666"
  region = "us-east-1"
  assume_role {
    role_arn = var.terraform_role_arns["666666666666"]
  }
}

###############################################################################
# Module calls — one per account
# To add an account: add a provider alias above + a module block below.
###############################################################################

module "billing_111111111111" {
  source = "./modules/billing_role"
  providers = { aws = aws.account_111111111111 }

  ou                  = "production"
  account_id          = "111111111111"
  billing_role_name   = var.billing_role_name
  databricks_role_arn = var.databricks_role_arn
}

module "billing_222222222222" {
  source = "./modules/billing_role"
  providers = { aws = aws.account_222222222222 }

  ou                  = "production"
  account_id          = "222222222222"
  billing_role_name   = var.billing_role_name
  databricks_role_arn = var.databricks_role_arn
}

module "billing_333333333333" {
  source = "./modules/billing_role"
  providers = { aws = aws.account_333333333333 }

  ou                  = "production"
  account_id          = "333333333333"
  billing_role_name   = var.billing_role_name
  databricks_role_arn = var.databricks_role_arn
}

module "billing_444444444444" {
  source = "./modules/billing_role"
  providers = { aws = aws.account_444444444444 }

  ou                  = "staging"
  account_id          = "444444444444"
  billing_role_name   = var.billing_role_name
  databricks_role_arn = var.databricks_role_arn
}

module "billing_555555555555" {
  source = "./modules/billing_role"
  providers = { aws = aws.account_555555555555 }

  ou                  = "staging"
  account_id          = "555555555555"
  billing_role_name   = var.billing_role_name
  databricks_role_arn = var.databricks_role_arn
}

module "billing_666666666666" {
  source = "./modules/billing_role"
  providers = { aws = aws.account_666666666666 }

  ou                  = "sandbox"
  account_id          = "666666666666"
  billing_role_name   = var.billing_role_name
  databricks_role_arn = var.databricks_role_arn
}

###############################################################################
# Locals — flat and nested role ARN maps (consumed by databricks_pipeline.tf)
###############################################################################

locals {
  # Flat map: "ou/account_id" -> role_arn
  billing_role_arns_flat = {
    "production/111111111111" = module.billing_111111111111.role_arn
    "production/222222222222" = module.billing_222222222222.role_arn
    "production/333333333333" = module.billing_333333333333.role_arn
    "staging/444444444444"    = module.billing_444444444444.role_arn
    "staging/555555555555"    = module.billing_555555555555.role_arn
    "sandbox/666666666666"    = module.billing_666666666666.role_arn
  }

  # All accounts metadata (used by databricks_pipeline.tf to build nested map)
  all_accounts = {
    "production/111111111111" = { ou = "production", account_id = "111111111111" }
    "production/222222222222" = { ou = "production", account_id = "222222222222" }
    "production/333333333333" = { ou = "production", account_id = "333333333333" }
    "staging/444444444444"    = { ou = "staging",    account_id = "444444444444" }
    "staging/555555555555"    = { ou = "staging",    account_id = "555555555555" }
    "sandbox/666666666666"    = { ou = "sandbox",    account_id = "666666666666" }
  }

  ou_names = distinct([for v in values(local.all_accounts) : v.ou])

  # Nested map: ou -> account_id -> role_arn (for DLT pipeline configuration)
  billing_role_arns_nested = {
    for ou_name in local.ou_names :
    ou_name => {
      for key, info in local.all_accounts :
      info.account_id => local.billing_role_arns_flat[key]
      if info.ou == ou_name
    }
  }
}

###############################################################################
# Outputs
###############################################################################

output "billing_role_arns" {
  description = "Flat map of OU/AccountId -> Billing Role ARN"
  value       = local.billing_role_arns_flat
}

output "billing_role_arns_nested" {
  description = "Nested map of OU -> AccountId -> Billing Role ARN (for DLT config)"
  value       = local.billing_role_arns_nested
}
