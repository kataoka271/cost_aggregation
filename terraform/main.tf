###############################################################################
# AWS Billing Role Setup for Multi-OU Cost Aggregation
# Prerequisites: aws sso login --profile <your-profile>
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

variable "ou_accounts" {
  description = "Map of OU name to list of AWS Account IDs"
  type        = map(list(string))
  default = {
    "production" = ["111111111111", "222222222222"]
    "staging"    = ["333333333333", "444444444444"]
    "sandbox"    = ["555555555555"]
  }
}

variable "billing_role_name" {
  description = "IAM Role name to create in each target account"
  type        = string
  default     = "DatabricksBillingRole"
}

variable "databricks_account_id" {
  description = "AWS Account ID where Databricks cluster runs (the AssumeRole caller)"
  type        = string
}

variable "databricks_role_arn" {
  description = "IAM Role ARN of the Databricks cluster instance profile"
  type        = string
}

variable "cost_explorer_start_date" {
  description = "Default start date for Cost Explorer queries (YYYY-MM-DD)"
  type        = string
  default     = "2024-01-01"
}

###############################################################################
# Local: flatten OU accounts into a single map for for_each
###############################################################################

locals {
  # Flatten: { "production/111111111111" = { ou = "production", account_id = "111111111111" } }
  all_accounts = merge([
    for ou_name, account_ids in var.ou_accounts : {
      for account_id in account_ids :
      "${ou_name}/${account_id}" => {
        ou         = ou_name
        account_id = account_id
      }
    }
  ]...)
}

###############################################################################
# Provider aliases per account (using AWS SSO assumed roles)
###############################################################################

# Default provider — management / payer account
provider "aws" {
  alias  = "management"
  region = "us-east-1"

  # Credentials come from: aws sso login
  # Profile should be set via AWS_PROFILE env var or --var flag
}

###############################################################################
# IAM Policy Document — minimal Cost Explorer read permissions
###############################################################################

data "aws_iam_policy_document" "billing_policy" {
  statement {
    sid    = "CostExplorerReadOnly"
    effect = "Allow"
    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
      "ce:GetDimensionValues",
      "ce:GetReservationCoverage",
      "ce:GetReservationPurchaseRecommendation",
      "ce:GetReservationUtilization",
      "ce:GetSavingsPlansCoverage",
      "ce:GetSavingsPlansUtilization",
      "ce:GetTags",
      "ce:ListCostAllocationTags",
      "cur:DescribeReportDefinitions",
      "organizations:DescribeAccount",
      "organizations:ListAccounts",
    ]
    resources = ["*"]
  }
}

###############################################################################
# Trust Policy — allow Databricks cluster role to AssumeRole
###############################################################################

data "aws_iam_policy_document" "billing_trust" {
  statement {
    sid     = "AllowDatabricksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.databricks_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["databricks-billing-aggregator"]
    }
  }
}

###############################################################################
# NOTE: In a real multi-account setup each account needs its own provider alias.
# Below we create the resources using the management account provider as a
# demonstration.  For actual cross-account deployment, use a tool such as
# Terragrunt or AWS CloudFormation StackSets.
#
# Pattern per account:
#   provider "aws" {
#     alias = "account_<id>"
#     assume_role { role_arn = "arn:aws:iam::<id>:role/OrganizationAccountAccessRole" }
#   }
###############################################################################

resource "aws_iam_policy" "billing_policy" {
  provider = aws.management
  for_each = local.all_accounts

  name        = "${var.billing_role_name}-Policy-${each.value.account_id}"
  description = "Allows Cost Explorer read access for Databricks billing aggregation (OU: ${each.value.ou})"
  policy      = data.aws_iam_policy_document.billing_policy.json

  tags = {
    ManagedBy = "Terraform"
    OU        = each.value.ou
    AccountId = each.value.account_id
    Purpose   = "DatabricksBillingAggregation"
  }
}

resource "aws_iam_role" "billing_role" {
  provider = aws.management
  for_each = local.all_accounts

  name               = "${var.billing_role_name}-${each.value.account_id}"
  assume_role_policy = data.aws_iam_policy_document.billing_trust.json
  description        = "Billing read role for Databricks (OU: ${each.value.ou}, Account: ${each.value.account_id})"

  tags = {
    ManagedBy = "Terraform"
    OU        = each.value.ou
    AccountId = each.value.account_id
    Purpose   = "DatabricksBillingAggregation"
  }
}

resource "aws_iam_role_policy_attachment" "billing_attach" {
  provider = aws.management
  for_each = local.all_accounts

  role       = aws_iam_role.billing_role["${each.value.ou}/${each.value.account_id}"].name
  policy_arn = aws_iam_policy.billing_policy["${each.value.ou}/${each.value.account_id}"].arn
}

###############################################################################
# Outputs — Role ARNs to use in Databricks DLT pipeline configuration
###############################################################################

output "billing_role_arns" {
  description = "Map of OU/AccountId -> Billing Role ARN (use in DLT pipeline config)"
  value = {
    for key, role in aws_iam_role.billing_role :
    key => role.arn
  }
}

output "ou_account_map" {
  description = "Flattened OU -> Account mapping"
  value       = local.all_accounts
}
