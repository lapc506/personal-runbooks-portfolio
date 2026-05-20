#!/usr/bin/env bash
set -euo pipefail

echo "=== GCP Cost Optimization Audit ==="
echo ""

PROJECT=$(gcloud config get-value project 2>/dev/null || echo "(no project set)")
echo "Project: $PROJECT"
echo ""

# ── 1. Recommender — Cost recommendations ─────────────────────────────────
echo ">>> Recommender — Cost Optimization"
gcloud recommender recommendations list \
    --recommender=google.cloudcost.Recommender \
    --project="$PROJECT" \
    --format="table(name, description, primaryImpact.severity, stateInfo.state)" 2>&1 || echo "(Recommender API not enabled or no recommendations)"
echo ""

# ── 2. Recommender — Idle VM recommendations ──────────────────────────────
echo ">>> Recommender — Idle / Underutilized VMs"
gcloud recommender recommendations list \
    --recommender=google.compute.instance.MachineTypeRecommender \
    --project="$PROJECT" \
    --format="table(name, description, primaryImpact.severity, stateInfo.state)" 2>&1 || echo "(no VM machine-type recommendations)"
echo ""

# ── 3. Recommender — Commit (CUD) recommendations ─────────────────────────
echo ">>> Recommender — Committed Use Discount (CUD)"
gcloud recommender recommendations list \
    --recommender=google.compute.commitment.UsageCommitmentRecommender \
    --project="$PROJECT" \
    --format="table(name, description, primaryImpact.severity, stateInfo.state)" 2>&1 || echo "(no CUD recommendations)"
echo ""

# ── 4. Cloud Asset Inventory — Stopped VM instances ───────────────────────
echo ">>> Stopped VM Instances"
gcloud compute instances list --filter="status:terminated OR status:stopped" \
    --format="table(name, zone, status, machineType)" 2>&1 || true
echo ""

# ── 5. Unattached persistent disks ────────────────────────────────────────
echo ">>> Unattached Persistent Disks"
gcloud compute disks list --filter="-users:*" \
    --format="table(name, zone, sizeGb, type)" 2>&1 || true
echo ""

# ── 6. Unused static external IPs ─────────────────────────────────────────
echo ">>> Unused Static External IPs"
gcloud compute addresses list --filter="status:RESERVED" \
    --format="table(name, region, address, status)" 2>&1 || true
echo ""

# ── 7. Billing (last 6 months summary, if billing account accessible) ─────
echo ">>> Billing Account"
BILLING_ACCT=$(gcloud billing accounts list --format="value(name)" --limit=1 2>&1 || true)
if [[ -n "$BILLING_ACCT" && "$BILLING_ACCT" != *"Permission"* ]]; then
    echo "Billing account: $BILLING_ACCT"
    gcloud billing accounts describe "$BILLING_ACCT" --format="table(displayName, open, masterBillingAccount)" 2>&1 || true
else
    echo "(No billing account accessible with current credentials)"
fi
echo ""

echo "=== GCP audit complete ==="
