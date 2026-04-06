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
