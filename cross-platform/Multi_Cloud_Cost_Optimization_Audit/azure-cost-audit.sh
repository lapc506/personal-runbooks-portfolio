#!/usr/bin/env bash
set -euo pipefail

echo "=== Azure Cost Optimization Audit ==="
echo ""

# ── 1. Ensure resource-graph extension ────────────────────────────────────
if ! az extension show --name resource-graph &>/dev/null 2>&1; then
    echo "[SETUP] Installing resource-graph extension..."
    az extension add --name resource-graph --allow-preview --only-show-errors
fi

# ── 2. Advisor Cost recommendations ────────────────────────────────────────
echo ">>> Advisor Cost Recommendations"
echo ""
az advisor recommendation list --category Cost --query "[].{Name:name, Resource:resourceName, Impact:impact, Description:shortDescription.value}" -o table 2>&1 || echo "(no Advisor recommendations or not authenticated)"
echo ""

# ── 3. Unattached managed disks ───────────────────────────────────────────
echo ">>> Unattached Managed Disks"
az graph query -q "Resources | where type =~ 'Microsoft.Compute/disks' and properties.diskState == 'Unattached' | project name, resourceGroup, sku.name, properties.diskSizeGB, location" -o table 2>&1 || echo "(Resource Graph unavailable)"
echo ""

# ── 4. Unassigned public IPs ──────────────────────────────────────────────
echo ">>> Unassigned Public IPs"
az graph query -q "Resources | where type =~ 'Microsoft.Network/publicIPAddresses' and properties.ipAddress == '' | project name, resourceGroup, sku.name, properties.publicIPAddressVersion" -o table 2>&1
echo ""

# ── 5. Stopped (deallocated) VMs ──────────────────────────────────────────
echo ">>> Stopped / Deallocated VMs"
az graph query -q "Resources | where type =~ 'Microsoft.Compute/virtualMachines' and properties.extended.instanceView.powerState in~ ('PowerState/deallocated', 'PowerState/stopped') | project name, resourceGroup, location, properties.hardwareProfile.vmSize" -o table 2>&1
echo ""

# ── 6. VMs with older SKUs (candidates for migration to new series) ───────
echo ">>> VMs on Older SKUs (Dv2, Av1 series — migration candidates)"
az graph query -q "Resources | where type =~ 'Microsoft.Compute/virtualMachines' | extend sku = properties.hardwareProfile.vmSize | where sku contains '_DS_V2' or sku contains '_A0' or sku contains '_A1' or sku contains '_A2' or sku contains '_A3' or sku contains '_A4' | project name, sku, resourceGroup, location" -o table 2>&1
echo ""

# ── 7. Consumption (last 30 days) ─────────────────────────────────────────
echo ">>> Cost (last 30 days, top 20)"
az consumption usage list --top 20 --query "[].{Date:usageStart, Service:meterDetails.meterCategory, Cost:pretaxCost}" -o table 2>&1 || echo "(Consumption API not available or not authorized)"
echo ""

echo "=== Azure audit complete ==="
