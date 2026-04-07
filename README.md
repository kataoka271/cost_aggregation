# AWS Multi-OU Billing Aggregator

A pipeline that collects billing data from multiple AWS accounts across Organization Units (OUs) using the Cost Explorer API, then aggregates it in Databricks Delta Live Tables (DLT) using a medallion architecture.

## Architecture

```
GitHub Actions (on merge to main)
  └─ Terraform
       ├─ AWS IAM: DatabricksBillingRole-{account_id}  (one per account)
       │    └─ Trust: Databricks instance profile + ExternalId check
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
│   └── deploy.yml               # CI/CD: plan on PR, apply on merge
├── terraform/
│   ├── main.tf                  # AWS IAM roles and policies
│   ├── databricks_pipeline.tf   # Databricks DLT pipeline resource
│   └── terraform.tfvars         # Environment config — edit this to add accounts
└── databricks/
    └── billing_pipeline.py      # DLT pipeline (Bronze / Silver / Gold)
```

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.5 | IAM role provisioning + pipeline deployment |
| AWS CLI | any | SSO authentication for local runs |
| Databricks workspace | — | Unity Catalog enabled, DLT support |
| Databricks cluster | — | Instance profile with `sts:AssumeRole` attached |

The Databricks cluster's instance profile must allow assuming billing roles:

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
| `AWS_ROLE_ARN` | Secret | IAM role ARN for GitHub OIDC (management account) |
| `DATABRICKS_HOST` | Secret | `https://adb-xxxx.azuredatabricks.net` |
| `DATABRICKS_TOKEN` | Secret | Databricks PAT or service principal token |
| `AWS_REGION` | Variable | `us-east-1` |

**2. Set up AWS OIDC trust** (one-time) so GitHub Actions can assume the management account role without static credentials:

```bash
# Create the OIDC provider in your management account
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Create an IAM role that trusts the OIDC provider scoped to your repo
# Attach AdministratorAccess or a scoped policy covering iam:*, sts:*
# Store the role ARN as secret AWS_ROLE_ARN
```

**3. Add accounts and deploy:**

```bash
# 1. Edit terraform/terraform.tfvars — add new account IDs
# 2. Open a pull request — GitHub Actions posts the Terraform plan as a comment
# 3. Merge to main — apply runs automatically
```

To trigger a manual apply (e.g. a targeted apply for a single resource):

```
GitHub → Actions → Deploy Billing Infrastructure → Run workflow
```

---

### Option B — Local deployment

**1. Authenticate**

```bash
aws sso login --profile <management-account-profile>
export DATABRICKS_TOKEN="dapi..."
```

**2. Edit `terraform/terraform.tfvars`**

```hcl
databricks_account_id = "000000000000"
databricks_role_arn   = "arn:aws:iam::000000000000:role/DatabricksInstanceProfileRole"
databricks_host       = "https://adb-xxxx.azuredatabricks.net"

ou_accounts = {
  "production" = ["111111111111", "222222222222"]
  "staging"    = ["444444444444"]
}

query_start = "2024-01-01"
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

# Billing role ARNs in the format expected by the pipeline
terraform output billing_role_arns_json
```

## Adding Accounts

1. Edit `terraform/terraform.tfvars` — append account IDs to an existing OU or add a new OU:

   ```hcl
   ou_accounts = {
     "production"  = ["111111111111", "222222222222", "999999999999"]  # added
     "staging"     = ["444444444444"]
     "compliance"  = ["777777777777", "888888888888"]                  # new OU
   }
   ```

2. Open a pull request — the workflow posts a plan showing new `aws_iam_role` resources and the updated `billing_role_arns` pipeline configuration.

3. Merge — the new roles are created and the pipeline configuration is updated automatically.

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

**AssumeRole failures**
1. Verify `databricks_role_arn` in `terraform.tfvars` matches the cluster's actual instance profile ARN
2. Confirm `external_id` is identical in both the Terraform trust policy and the pipeline parameter
3. Check the cluster instance profile has `sts:AssumeRole` on `arn:aws:iam::*:role/DatabricksBillingRole-*`

**Empty Cost Explorer results**
- Cost Explorer reports the previous day's costs with a 24–48 hour delay
- The query window must fall within the last 12 months

**Rows dropped in Silver layer**
- Check the auto-generated quarantine table: `SELECT * FROM billing.aws_costs.aws_billing_silver_quarantine`
- Common cause: services with zero usage that day produce null amounts — adjust or remove the `@dlt.expect_or_drop` gate in `billing_pipeline.py`

**Multi-account deployment note**

The Terraform in this repo creates all IAM resources using the management account provider as a single-account demonstration. For production cross-account deployments, use one of:
- **Terragrunt** — per-account `assume_role` blocks with DRY config
- **AWS CloudFormation StackSets** — native cross-account stack deployment
- **Provider aliases** — one `provider "aws"` block per account (see `terraform/main.tf` lines 131–140)
