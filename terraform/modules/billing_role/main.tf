###############################################################################
# billing_role module — creates IAM policy + role + attachment in one account
# Called once per target account via provider alias in the root module.
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

###############################################################################
# IAM Policy — minimal Cost Explorer read permissions
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
# Trust Policy — allow Databricks cluster role to AssumeRole with ExternalId
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
# IAM Resources
###############################################################################

resource "aws_iam_policy" "billing_policy" {
  name        = "${var.billing_role_name}-Policy-${var.account_id}"
  description = "Allows Cost Explorer read access for Databricks billing aggregation (OU: ${var.ou})"
  policy      = data.aws_iam_policy_document.billing_policy.json

  tags = {
    ManagedBy = "Terraform"
    OU        = var.ou
    AccountId = var.account_id
    Purpose   = "DatabricksBillingAggregation"
  }
}

resource "aws_iam_role" "billing_role" {
  name               = "${var.billing_role_name}-${var.account_id}"
  assume_role_policy = data.aws_iam_policy_document.billing_trust.json
  description        = "Billing read role for Databricks (OU: ${var.ou}, Account: ${var.account_id})"

  tags = {
    ManagedBy = "Terraform"
    OU        = var.ou
    AccountId = var.account_id
    Purpose   = "DatabricksBillingAggregation"
  }
}

resource "aws_iam_role_policy_attachment" "billing_attach" {
  role       = aws_iam_role.billing_role.name
  policy_arn = aws_iam_policy.billing_policy.arn
}
