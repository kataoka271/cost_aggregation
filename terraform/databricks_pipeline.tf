###############################################################################
# Databricks DLT Pipeline — AWS Billing Aggregator
# Deploys the billing_pipeline.py notebook and creates the DLT pipeline with
# all required configuration parameters.
#
# Prerequisites:
#   - AWS IAM roles already applied (terraform apply on main.tf)
#   - Databricks workspace with Unity Catalog enabled
#   - Databricks cluster with instance profile matching databricks_role_arn
###############################################################################

###############################################################################
# Variables
###############################################################################

variable "databricks_host" {
  description = "Databricks workspace URL (e.g. https://adb-xxxx.azuredatabricks.net)"
  type        = string
}

variable "databricks_token" {
  description = "Databricks personal access token or service principal secret. Prefer setting via DATABRICKS_TOKEN env var instead of tfvars."
  type        = string
  sensitive   = true
  default     = ""
}

variable "target_catalog" {
  description = "Unity Catalog catalog name where billing tables will be created"
  type        = string
  default     = "billing"
}

variable "target_schema" {
  description = "Unity Catalog schema name where billing tables will be created"
  type        = string
  default     = "aws_costs"
}

variable "query_start" {
  description = "Start date for Cost Explorer queries (YYYY-MM-DD, max 12 months back)"
  type        = string
  default     = "2024-01-01"
}

variable "query_end" {
  description = "End date for Cost Explorer queries (YYYY-MM-DD). Leave empty to use today's date."
  type        = string
  default     = ""
}

variable "pipeline_development_mode" {
  description = "Run DLT pipeline in development mode (useful for testing; disables auto-retry)"
  type        = bool
  default     = false
}

variable "pipeline_channel" {
  description = "DLT release channel: CURRENT or PREVIEW"
  type        = string
  default     = "CURRENT"
  validation {
    condition     = contains(["CURRENT", "PREVIEW"], var.pipeline_channel)
    error_message = "pipeline_channel must be CURRENT or PREVIEW."
  }
}

variable "notebook_workspace_path" {
  description = "Destination path in the Databricks workspace for the pipeline notebook"
  type        = string
  default     = "/Shared/aws_billing_aggregator/billing_pipeline.py"
}

###############################################################################
# Provider
###############################################################################

provider "databricks" {
  host  = var.databricks_host
  token = var.databricks_token != "" ? var.databricks_token : null
  # If token is empty, the provider falls back to DATABRICKS_TOKEN env var
}

###############################################################################
# Local
###############################################################################

locals {
  # Use today's date when query_end is not specified
  effective_query_end = var.query_end != "" ? var.query_end : formatdate("YYYY-MM-DD", timestamp())
}

# Note: local.billing_role_arns_nested is defined in main.tf

###############################################################################
# Upload pipeline notebook to Databricks workspace
###############################################################################

resource "databricks_workspace_file" "billing_pipeline" {
  source = "${path.module}/../databricks/billing_pipeline.py"
  path   = var.notebook_workspace_path
}

###############################################################################
# DLT Pipeline
###############################################################################

resource "databricks_pipeline" "aws_billing_aggregator" {
  name        = "aws-billing-aggregator"
  channel     = var.pipeline_channel
  development = var.pipeline_development_mode

  catalog = var.target_catalog
  target  = var.target_schema

  library {
    notebook {
      path = databricks_workspace_file.billing_pipeline.path
    }
  }

  configuration = {
    "pipelines.billing_role_arns" = jsonencode(local.billing_role_arns_nested)
    "pipelines.query_start"       = var.query_start
    "pipelines.query_end"         = local.effective_query_end
    "pipelines.external_id"       = "databricks-billing-aggregator"
    "pipelines.target_catalog"    = var.target_catalog
    "pipelines.target_schema"     = var.target_schema
  }
}

###############################################################################
# Outputs
###############################################################################

output "pipeline_id" {
  description = "Databricks DLT pipeline ID"
  value       = databricks_pipeline.aws_billing_aggregator.id
}

output "pipeline_url" {
  description = "Direct URL to the DLT pipeline in Databricks workspace"
  value       = "${var.databricks_host}/#joblist/pipelines/${databricks_pipeline.aws_billing_aggregator.id}"
}

output "billing_role_arns_json" {
  description = "Billing role ARNs in nested OU -> account_id -> ARN format (for manual pipeline config)"
  value       = jsonencode(local.billing_role_arns_nested)
  sensitive   = false
}
