###############################################################################
# terraform.tfvars — customize for your environment
###############################################################################

# AWS Account ID where your Databricks cluster lives
databricks_account_id = "000000000000"

# Instance profile role ARN attached to the Databricks cluster
databricks_role_arn = "arn:aws:iam::000000000000:role/DatabricksInstanceProfileRole"

# OU name → list of AWS Account IDs to grant billing access
ou_accounts = {
  "production" = ["111111111111", "222222222222", "333333333333"]
  "staging"    = ["444444444444", "555555555555"]
  "sandbox"    = ["666666666666"]
}

billing_role_name = "DatabricksBillingRole"

###############################################################################
# Databricks Pipeline Configuration
###############################################################################

# Databricks workspace URL
databricks_host = "https://adb-xxxx.azuredatabricks.net"

# Personal access token — prefer setting DATABRICKS_TOKEN env var instead:
#   export DATABRICKS_TOKEN="dapixxxx"
# databricks_token = "dapixxxx"

# Unity Catalog destination for billing tables
target_catalog = "billing"
target_schema  = "aws_costs"

# Cost Explorer query window
query_start = "2024-01-01"
# query_end = "2024-12-31"   # defaults to today if omitted

# Set to true during initial testing; false for scheduled production runs
pipeline_development_mode = false
