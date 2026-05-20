# Multi-Cloud Cost Optimization Audit — CLI-only

_Applies to: Azure CLI 2.x, AWS CLI 2.x, gcloud 5xx, Linux. All three CLIs must be installed and authenticated before running._

> **⚠ Reader's summary:** a unified CLI-only cost optimization assessment across Azure, AWS, and GCP. Each cloud provider exposes native commands — Azure Advisor (`az advisor`), AWS Well-Architected Tool (`aws wellarchitected`) / Trusted Advisor / Cost Explorer (`aws ce`), and GCP Recommender (`gcloud recommender`). The orquestrator script `run-cost-audit.sh` executes all three sequentially and merges the output into a single Markdown report with sections by cloud. The per-cloud scripts can also run standalone. No GUI, no third-party tools.

## Context

The Well-Architected Framework Cost Optimization pillar asks: _are you getting the best value from your cloud investment?_ Each provider has a native assessment tool:

- **Azure** — `az advisor recommendation list --category Cost` + Resource Graph queries
- **AWS** — `aws wellarchitected` (WA Tool) + `aws ce get-cost-and-usage` + Trusted Advisor
- **GCP** — `gcloud recommender recommendations list` (cost recommender + machine-type recommender)

This runbook codifies the cheapest possible assessment: zero third-party spend, only CLI commands that run against the cloud control planes.

## Prerequisites

Install the CLIs if not present:

```bash
# Azure
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login

# AWS
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
aws configure

# GCP
sudo apt-get install -y apt-transport-https ca-certificates gnupg
echo "deb https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo apt-get update && sudo apt-get install -y google-cloud-cli
gcloud auth login
gcloud config set project PROJECT_ID
```

Check all three:

```bash
az version --output tsv && aws --version && gcloud --version
```

Run the audit:

```bash
bash ./run-cost-audit.sh
```

Output: `cost-audit-report-<YYYY-MM-DD>.md`.

## Scripts

| File | Purpose |
|------|---------|
| `run-cost-audit.sh` | Orquestrator — runs all three cloud scripts, merges output |
| `azure-cost-audit.sh` | Azure Advisor Cost recommendations + Resource Graph + Consumption |
| `aws-cost-audit.sh` | AWS Well-Architected Tool list + Cost Explorer + EC2/EBS idle resources |
| `gcp-cost-audit.sh` | GCP Recommender cost recommendations + Asset Inventory |

## Verification

After `run-cost-audit.sh` finishes:

```bash
ls -lh cost-audit-report-*.md
```

If a cloud errored (e.g. `ERROR: Please run 'az login'`), re-authenticate and run that cloud's script standalone:

```bash
az login && bash ./azure-cost-audit.sh
```

## Rollback

These scripts only _read_ data. No resources are created, modified, or deleted. Rollback is limited to logging out:

```bash
az logout
aws configure set profile default
gcloud auth revoke --all
```

## Known Constraints

- Azure Resource Graph requires the `resource-graph` extension: `az extension add --name resource-graph --allow-preview`
- AWS Trusted Advisor cost checks require a **Business** or **Enterprise** support plan. Without it, `aws support describe-trusted-advisor-checks` returns only security checks.
- AWS Cost Explorer (`aws ce`) is available after 24h of billing data. New accounts will return empty results.
- GCP Recommender requires the `recommender` API enabled: `gcloud services enable recommender.googleapis.com`
- GCP some recommendations need the `container` API for GKE cost insights.
- All three CLIs need at least **read-only** permissions (Azure `Reader`, AWS `ReadOnlyAccess`, GCP `roles/viewer`). Cost-specific permissions may require additional roles (`Cost Management Reader`, `AWSAccountUsageAccess`, `roles/recommender.viewer`).

## References

- [Azure Advisor cost recommendations](https://learn.microsoft.com/en-us/azure/advisor/advisor-cost-recommendations)
- [Azure Resource Graph](https://learn.microsoft.com/en-us/azure/governance/resource-graph/)
- [AWS Well-Architected Tool CLI reference](https://docs.aws.amazon.com/cli/latest/reference/wellarchitected/)
- [AWS Cost Explorer](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html)
- [GCP Recommender](https://cloud.google.com/recommender/docs)
- [GCP Cloud Asset Inventory](https://cloud.google.com/asset-inventory/docs)

## Debugging lessons

1. **`az graph query` fails with "extension not installed"** — Azure Resource Graph is a CLI extension, not part of the core `az` module. Always run `az extension add --name resource-graph` first. The error message "Unknown command" is misleading because it looks like a typo in the query.
2. **`aws support describe-trusted-advisor-checks` returns only 4 checks** — This is the free tier. Full cost checks need Business/Enterprise support. The script falls back to Cost Explorer when Trusted Advisor is limited.
3. **GCP recommender returns empty for a brand-new project** — Recommendations take 24-48h to generate after resources are created. Run `gcloud recommender recommendations list` on a project that has been running for at least a week for meaningful output.
4. **Billing access is the most common blocker across all three clouds** — Azure needs `Cost Management Reader` (not just `Reader`), AWS requires `ce:*` permissions, GCP needs `roles/billing.viewer` at the billing-account level. These are separate from the standard read-only roles. Check billing first when a cost command returns empty or "access denied".
5. **Output formats differ between clouds** — Azure defaults to JSON, AWS defaults to JSON, GCP defaults to YAML. The scripts normalize all output to JSON before merging into the Markdown report.
