variable "ou" {
  description = "OU name this account belongs to"
  type        = string
}

variable "account_id" {
  description = "AWS Account ID where the billing role is created"
  type        = string
}

variable "billing_role_name" {
  description = "Base name for the IAM role and policy"
  type        = string
}

variable "databricks_role_arn" {
  description = "IAM Role ARN of the Databricks cluster instance profile (trusted principal)"
  type        = string
}
