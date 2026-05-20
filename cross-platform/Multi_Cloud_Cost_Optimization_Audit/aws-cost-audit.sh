#!/usr/bin/env bash
set -euo pipefail

echo "=== AWS Cost Optimization Audit ==="
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")

# ── 1. Well-Architected Tool ──────────────────────────────────────────────
echo ">>> AWS Well-Architected Tool — Cost Pillar"
echo ""

WORKLOADS=$(aws wellarchitected list-workloads --query "WorkloadSummaries[].WorkloadId" --output text 2>&1 || true)
if [[ -z "$WORKLOADS" || "$WORKLOADS" == "null" ]]; then
    echo "(No WA Tool workloads found. Create one via the console first.)"
else
    for WL in $WORKLOADS; do
        echo "Workload: $WL"
        aws wellarchitected list-answers --workload-id "$WL" --lens-alias wellarchitected --pillar-id costOptimization \
            --query "AnswerSummaries[].{Question:QuestionTitle, Risk:Risk, Choices:ChoiceTitles}" --output table 2>&1 || true
        echo ""
    done
fi
echo ""

# ── 2. Trusted Advisor — cost checks (requires Business/Enterprise support) ─
echo ">>> Trusted Advisor — Cost Checks"
TA_COST=$(aws support describe-trusted-advisor-checks --language en --query "checks[?category=='cost_optimizing']" 2>&1 || true)
if echo "$TA_COST" | grep -q "SubscriptionNotFound\|AccessDenied"; then
    echo "(Trusted Advisor cost checks require Business or Enterprise support plan)"
else
    echo "$TA_COST" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for c in data:
    print(f\"  • {c['name']} (id: {c['id']})\")
" 2>/dev/null || echo "(no cost checks available)"
fi
echo ""

# ── 3. Cost Explorer ──────────────────────────────────────────────────────
echo ">>> Cost Explorer — Last 30 days (daily)"
CURRENT=$(date +%Y-%m-%d)
START=$(date -d "30 days ago" +%Y-%m-%d)
aws ce get-cost-and-usage \
    --time-period Start="$START",End="$CURRENT" \
    --granularity DAILY \
    --metrics "UnblendedCost" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query "ResultsByTime[].Groups[].{Service:Keys[0],Cost:Amounts[0].Amount}" \
    --output table 2>&1 || echo "(Cost Explorer not available — enable it or check permissions)"
echo ""

# ── 4. Idle / stopped EC2 instances ───────────────────────────────────────
echo ">>> Stopped EC2 Instances"
aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped \
    --query "Reservations[].Instances[].{InstanceId:InstanceId,Type:InstanceType,Name:Tags[?Key=='Name'].Value | [0],LaunchTime:LaunchTime}" \
    --output table 2>&1 || true
echo ""

# ── 5. Unattached EBS volumes ─────────────────────────────────────────────
echo ">>> Unattached EBS Volumes"
aws ec2 describe-volumes --filters Name=status,Values=available \
    --query "Volumes[].{VolumeId:VolumeId,Size:Size,Type:VolumeType,State:State}" \
    --output table 2>&1 || true
echo ""

# ── 6. Unassociated Elastic IPs ───────────────────────────────────────────
echo ">>> Unassociated Elastic IPs"
aws ec2 describe-addresses --query "Addresses[?AssociationId==null].[PublicIp]" --output text 2>&1 || true
echo ""

echo "=== AWS audit complete ==="
