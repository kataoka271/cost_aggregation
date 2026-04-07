###############################################################################
# terraform.tfvars — customize for your environment
###############################################################################

# AWS Account ID where your Databricks cluster lives
databricks_account_id = "000000000000"

# Instance profile role ARN attached to the Databricks cluster
databricks_role_arn = "arn:aws:iam::000000000000:role/DatabricksInstanceProfileRole"

billing_role_name = "DatabricksBillingRole"

# Terraform deployer role in each target account.
# Terraform assumes this role to create the billing IAM role/policy.
# The role needs: iam:CreateRole, iam:CreatePolicy, iam:AttachRolePolicy,
#                 iam:GetRole, iam:GetPolicy, iam:ListRolePolicies, iam:DeleteRole, etc.
terraform_role_arns = {
  "111111111111" = "arn:aws:iam::111111111111:role/TerraformDeployerRole"
  "222222222222" = "arn:aws:iam::222222222222:role/TerraformDeployerRole"
  "333333333333" = "arn:aws:iam::333333333333:role/TerraformDeployerRole"
  "444444444444" = "arn:aws:iam::444444444444:role/TerraformDeployerRole"
  "555555555555" = "arn:aws:iam::555555555555:role/TerraformDeployerRole"
  "666666666666" = "arn:aws:iam::666666666666:role/TerraformDeployerRole"
}

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
