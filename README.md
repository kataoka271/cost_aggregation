# AWS Multi-OU Billing Aggregator

A pipeline that collects billing data from multiple AWS accounts across Organization Units (OUs) using the Cost Explorer API, then aggregates it in Databricks Delta Live Tables (DLT) using a medallion architecture.

## Architecture

```
GitHub Actions (on merge to main)
  └─ Terraform
       ├─ AWS IAM (per account via provider alias)
       │    └─ DatabricksBillingRole-{account_id}  ← created directly in each account
       │         └─ Trust: Databricks instance profile + ExternalId check
       └─ Databricks: DLT Pipeline (billing_pipeline.py)
            └─ Bronze → Silver → Gold tables in Unity Catalog
```

### Data Flow

```
Databricks Cluster (instance profile)
  └─ STS AssumeRole ──► DatabricksBillingRole-{account_id}
                              └─ AWS Cost Explorer API
                                      └─ DLT pipeline
                                            ├─ Bronze  raw records
                                            ├─ Silver  deduped + typed
                                            └─ Gold    aggregations
```

### DLT Table Lineage

| Table | Layer | Description |
|---|---|---|
| `aws_billing_bronze` | Bronze | Raw Cost Explorer records, append-only, partitioned by OU/account |
| `aws_billing_silver` | Silver | Type conversion, deduplication, quality gates |
| `aws_billing_daily_by_service` | Gold | Daily cost by OU, account, and service |
| `aws_billing_monthly_by_ou` | Gold | Monthly rollup at OU level |
| `aws_billing_top_services` | Gold | Top services by spend across all OUs |

## Repository Structure

```
.
├── .github/workflows/
│   └── deploy.yml                      # CI/CD: plan on PR, apply on merge
├── terraform/
│   ├── main.tf                         # Per-account provider aliases + module calls
│   ├── databricks_pipeline.tf          # Databricks DLT pipeline resource
│   ├── terraform.tfvars                # Environment config — edit when adding accounts
│   └── modules/
│       └── billing_role/               # IAM role/policy module (called once per account)
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
└── databricks/
    └── billing_pipeline.py             # DLT pipeline (Bronze / Silver / Gold)
```

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.5 | IAM role provisioning + pipeline deployment |
| AWS CLI | any | SSO authentication for local runs |
| Databricks workspace | — | Unity Catalog enabled, DLT support |
| Databricks cluster | — | Instance profile with `sts:AssumeRole` attached |

**No AWS management/payer account is required.** Terraform deploys directly into each target account by assuming a Terraform deployer role (`TerraformDeployerRole`) that must exist in each account beforehand.

The Terraform deployer role needs the following IAM permissions in each target account:

```json
{
  "Effect": "Allow",
  "Action": [
    "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
    "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
    "iam:AttachRolePolicy", "iam:DetachRolePolicy",
    "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
    "iam:GetPolicyVersion", "iam:ListPolicyVersions",
    "iam:CreatePolicyVersion", "iam:DeletePolicyVersion"
  ],
  "Resource": "*"
}
```

The Databricks cluster's instance profile must allow assuming billing roles in all target accounts:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "arn:aws:iam::*:role/DatabricksBillingRole-*"
  }]
}
```

## Deployment

### Option A — GitHub Actions (recommended)

Push to `main` automatically plans and applies all Terraform changes.

**1. Configure repository secrets and variables** (Settings → Secrets and variables):

| Name | Type | Value |
|---|---|---|
| `AWS_ROLE_ARN` | Secret | OIDC role ARN in your CI/CD account (must be able to assume each `TerraformDeployerRole`) |
| `DATABRICKS_HOST` | Secret | `https://adb-xxxx.azuredatabricks.net` |
| `DATABRICKS_TOKEN` | Secret | Databricks PAT or service principal token |
| `AWS_REGION` | Variable | `us-east-1` |

**2. Set up AWS OIDC trust** (one-time) in the account where `AWS_ROLE_ARN` lives:

```bash
# Create the OIDC provider
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Create an IAM role that trusts the OIDC provider scoped to your repo.
# The role's permission policy must allow sts:AssumeRole on each TerraformDeployerRole:
#   "arn:aws:iam::*:role/TerraformDeployerRole"
# Store the role ARN as secret AWS_ROLE_ARN.
```

**3. Add accounts and deploy:**

```bash
# 1. Edit terraform/main.tf and terraform/terraform.tfvars — see "Adding Accounts" below
# 2. Open a pull request — GitHub Actions posts the Terraform plan as a comment
# 3. Merge to main — apply runs automatically
```

To trigger a manual apply:

```
GitHub → Actions → Deploy Billing Infrastructure → Run workflow
```

---

### Option B — Local deployment

**1. Authenticate**

```bash
# Log in with a profile that can assume TerraformDeployerRole in each target account
aws sso login --profile <your-profile>
export DATABRICKS_TOKEN="dapi..."
```

**2. Edit `terraform/terraform.tfvars`**

```hcl
databricks_account_id = "000000000000"
databricks_role_arn   = "arn:aws:iam::000000000000:role/DatabricksInstanceProfileRole"
databricks_host       = "https://adb-xxxx.azuredatabricks.net"

terraform_role_arns = {
  "111111111111" = "arn:aws:iam::111111111111:role/TerraformDeployerRole"
  "222222222222" = "arn:aws:iam::222222222222:role/TerraformDeployerRole"
}

query_start    = "2024-01-01"
target_catalog = "billing"
target_schema  = "aws_costs"
```

**3. Apply**

```bash
cd terraform
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

**4. Verify outputs**

```bash
# Pipeline URL in Databricks workspace
terraform output pipeline_url

# Billing role ARNs in nested OU → account → ARN format
terraform output billing_role_arns_nested
```

## Adding Accounts

Adding an account requires 4 edits, all in `terraform/`:

**1. `main.tf` — add a provider alias**

```hcl
provider "aws" {
  alias  = "account_999999999999"
  region = "us-east-1"
  assume_role {
    role_arn = var.terraform_role_arns["999999999999"]
  }
}
```

**2. `main.tf` — add a module call**

```hcl
module "billing_999999999999" {
  source    = "./modules/billing_role"
  providers = { aws = aws.account_999999999999 }

  ou                  = "new-ou"          # OU this account belongs to
  account_id          = "999999999999"
  billing_role_name   = var.billing_role_name
  databricks_role_arn = var.databricks_role_arn
}
```

**3. `main.tf` — add entries to both locals maps**

```hcl
billing_role_arns_flat = {
  ...
  "new-ou/999999999999" = module.billing_999999999999.role_arn
}

all_accounts = {
  ...
  "new-ou/999999999999" = { ou = "new-ou", account_id = "999999999999" }
}
```

**4. `terraform.tfvars` — add the Terraform deployer role ARN**

```hcl
terraform_role_arns = {
  ...
  "999999999999" = "arn:aws:iam::999999999999:role/TerraformDeployerRole"
}
```

Then open a PR — the plan will show the new IAM role and updated pipeline config. Merge to apply.

## Pipeline Configuration Reference

All pipeline parameters are set via Terraform and passed as `spark.conf` entries:

| Parameter | Description | Default |
|---|---|---|
| `pipelines.billing_role_arns` | JSON map of `{ou: {account_id: role_arn}}` — auto-generated by Terraform | — |
| `pipelines.query_start` | Cost Explorer start date (YYYY-MM-DD, max 12 months back) | `2024-01-01` |
| `pipelines.query_end` | Cost Explorer end date (YYYY-MM-DD) | today |
| `pipelines.external_id` | Must match IAM trust policy condition | `databricks-billing-aggregator` |
| `pipelines.target_catalog` | Unity Catalog catalog for billing tables | `billing` |
| `pipelines.target_schema` | Unity Catalog schema for billing tables | `aws_costs` |

## Troubleshooting

**AssumeRole failures (Terraform)**
1. Verify each `TerraformDeployerRole` has the required IAM permissions listed in Prerequisites
2. Confirm the caller identity (OIDC role or SSO profile) can assume `TerraformDeployerRole` in each target account
3. Check that `terraform_role_arns` in `terraform.tfvars` contains an entry for every account defined in `main.tf`

**AssumeRole failures (Databricks pipeline)**
1. Verify `databricks_role_arn` in `terraform.tfvars` matches the cluster's actual instance profile ARN
2. Confirm `external_id` is identical in both the Terraform trust policy and the pipeline parameter
3. Check the cluster instance profile has `sts:AssumeRole` on `arn:aws:iam::*:role/DatabricksBillingRole-*`

**Empty Cost Explorer results**
- Cost Explorer reports the previous day's costs with a 24–48 hour delay
- The query window must fall within the last 12 months

**Rows dropped in Silver layer**
- Check the auto-generated quarantine table: `SELECT * FROM billing.aws_costs.aws_billing_silver_quarantine`
- Common cause: services with zero usage that day produce null amounts — adjust or remove the `@dlt.expect_or_drop` gate in `billing_pipeline.py`
