output "role_arn" {
  description = "ARN of the created billing IAM role"
  value       = aws_iam_role.billing_role.arn
}

output "role_name" {
  description = "Name of the created billing IAM role"
  value       = aws_iam_role.billing_role.name
}

output "policy_arn" {
  description = "ARN of the created billing IAM policy"
  value       = aws_iam_policy.billing_policy.arn
}
