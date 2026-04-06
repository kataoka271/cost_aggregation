# Claude Code — AWS Multi-OU Billing Aggregator プロジェクト指示書

## プロジェクト概要
複数のAWS Organization Unit (OU) から使用料金を取得し、Databricks Delta Live Tables (DLT) に集約するパイプラインを構築します。

---

## ディレクトリ構成

```
.
├── terraform/
│   ├── main.tf           # IAM Role / Policy リソース定義
│   └── terraform.tfvars  # 環境固有の変数（要編集）
└── databricks/
    └── billing_pipeline.py  # DLT Declarative Pipelines スクリプト
```

---

## STEP 1: 事前準備 — Terraform による IAM Role 作成

### 1-1. AWS SSO 認証

```bash
# マネジメントアカウントの SSO プロファイルでログイン
aws sso login --profile <your-management-profile>

# 認証確認
aws sts get-caller-identity --profile <your-management-profile>
```

### 1-2. terraform.tfvars を編集

| 変数 | 説明 |
|---|---|
| `databricks_account_id` | Databricks クラスターが稼働する AWS アカウント ID |
| `databricks_role_arn` | クラスターにアタッチされた Instance Profile の ARN |
| `ou_accounts` | OU 名 → Account ID リストのマップ |

### 1-3. Terraform 実行

```bash
cd terraform

# 初期化
terraform init

# 差分確認
terraform plan -var-file=terraform.tfvars

# 適用
terraform apply -var-file=terraform.tfvars

# Role ARN 一覧を確認（DLT設定に使用）
terraform output -json billing_role_arns
```

> **注意**: 本 Terraform は管理アカウント上でリソースを作成するデモ実装です。
> 実際のマルチアカウント展開では、各アカウントに provider alias を追加するか、
> **Terragrunt** または **AWS CloudFormation StackSets** を使用してください。

---

## STEP 2: Databricks DLT パイプライン設定

### 2-1. クラスター Instance Profile の確認

Databricks クラスターには以下の権限を持つ Instance Profile をアタッチしてください：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::*:role/DatabricksBillingRole-*"
    }
  ]
}
```

### 2-2. DLT パイプラインパラメータ設定

Databricks UI または `databricks.yml` で以下を設定します：

```yaml
# databricks.yml (例)
resources:
  pipelines:
    aws_billing_aggregator:
      name: "AWS Multi-OU Billing Aggregator"
      libraries:
        - notebook:
            path: /databricks/billing_pipeline.py
      configuration:
        pipelines.billing_role_arns: |
          {
            "production": {
              "111111111111": "arn:aws:iam::111111111111:role/DatabricksBillingRole-111111111111",
              "222222222222": "arn:aws:iam::222222222222:role/DatabricksBillingRole-222222222222"
            },
            "staging": {
              "333333333333": "arn:aws:iam::333333333333:role/DatabricksBillingRole-333333333333"
            }
          }
        pipelines.query_start: "2024-01-01"
        pipelines.query_end: "2024-12-31"
        pipelines.target_catalog: "billing"
        pipelines.target_schema: "aws_costs"
        pipelines.external_id: "databricks-billing-aggregator"
      channel: "CURRENT"
      continuous: false
```

### 2-3. 作成される DLT テーブル一覧

| テーブル名 | レイヤー | 説明 |
|---|---|---|
| `aws_billing_bronze` | Bronze | Cost Explorer からの生データ（日次・全OU） |
| `aws_billing_silver` | Silver | 重複排除・型変換・品質チェック済み |
| `aws_billing_daily_by_service` | Gold | OU/アカウント/サービス別日次集計 |
| `aws_billing_monthly_by_ou` | Gold | OU別月次ロールアップ |
| `aws_billing_top_services` | Gold | クエリ期間中のサービス別コストランキング |

---

## STEP 3: Claude Code での開発・拡張手順

Claude Code を使ってこのプロジェクトを拡張する際の推奨コマンド例：

```bash
# プロジェクトルートで Claude Code を起動
claude

# 以下のようなプロンプトを使って機能追加・修正が可能
```

### Claude Code プロンプト例

**新しい OU アカウントの追加:**
```
terraform.tfvars の ou_accounts に "compliance" OU として
アカウント ID 777777777777 と 888888888888 を追加して。
terraform plan も実行して差分を確認して。
```

**Gold テーブルの追加:**
```
billing_pipeline.py に、タグ(CostCenter)別の月次コスト集計テーブル
aws_billing_monthly_by_cost_center を DLT Gold テーブルとして追加して。
Cost Explorer の GroupBy に TAG: CostCenter を追加する必要がある。
```

**エラーハンドリングの強化:**
```
billing_pipeline.py の collect_all_billing_records 関数で、
AssumeRole 失敗時のエラーを DLT の quarantine テーブルに記録するように修正して。
```

**スケジュール設定:**
```
databricks.yml に毎日 JST 9:00 (UTC 0:00) にパイプラインを実行する
スケジュール設定を追加して。
```

---

## トラブルシューティング

### AssumeRole が失敗する場合
1. Databricks クラスターの Instance Profile ARN が `terraform.tfvars` の `databricks_role_arn` と一致しているか確認
2. `external_id` が Terraform の trust policy と DLT パラメータで一致しているか確認
3. IAM Role の `sts:AssumeRole` 権限スコープ（`Resource`）を確認

### Cost Explorer が空データを返す場合
- `query_start` / `query_end` の日付範囲を確認
- Cost Explorer はリクエスト日から最大 12 ヶ月前まで照会可能

### DLT パイプラインが失敗する場合
- パイプラインログで `[WARNING]` メッセージを確認（アカウント単位でスキップ）
- `billing_role_arns` パラメータが正しい JSON 形式か確認
