#!/usr/bin/env bash
# Enforce Chrome "Memory Saver: Maximum" (+ preloading off) across ALL Google
# Chrome profiles by installing a system-wide managed policy. See README.
#
# Why: Memory Saver (chrome://settings/performance) is a PER-PROFILE preference,
# so it does not cover other profiles nor future ones. A managed policy in
# /etc/opt/chrome/policies/managed applies to every profile at once and enforces it.
#
# Needs sudo (writes under /etc). Idempotent. Does NOT restart Chrome — quit and
# reopen Chrome yourself afterward, then check chrome://policy. Reversible: see end.
set -euo pipefail

POLICY_DIR="/etc/opt/chrome/policies/managed"
POLICY_FILE="${POLICY_DIR}/memory-saver.json"

read -r -d '' POLICY_JSON <<'JSON' || true
{
  "HighEfficiencyModeEnabled": true,
  "MemorySaverModeSavings": 2,
  "NetworkPredictionOptions": 2
}
JSON

echo "== Chrome Memory Saver managed policy =="
echo "Target: ${POLICY_FILE}"

# Validate the JSON before touching anything privileged.
printf '%s\n' "${POLICY_JSON}" | python3 -m json.tool >/dev/null
echo "JSON valid."

if [ -f "${POLICY_FILE}" ] \
   && diff -q <(printf '%s\n' "${POLICY_JSON}") "${POLICY_FILE}" >/dev/null 2>&1; then
  echo "Already up to date. Nothing to do."
else
  echo "Writing policy (sudo required)…"
  sudo mkdir -p "${POLICY_DIR}"
  printf '%s\n' "${POLICY_JSON}" | sudo tee "${POLICY_FILE}" >/dev/null
  sudo chmod 644 "${POLICY_FILE}"
  echo "Installed."
fi

echo
echo "Next:"
echo "  1) Quit Chrome COMPLETELY — all windows + every chrome-*.desktop app"
echo "     instance (pkill -i chrome if unsure)."
echo "  2) Reopen Chrome."
echo "  3) chrome://policy → Reload policies → expect HighEfficiencyModeEnabled,"
echo "     MemorySaverModeSavings, NetworkPredictionOptions all 'OK'."
echo "  4) chrome://settings/performance → 'Maximum', shown as managed."
echo
echo "Rollback: sudo rm '${POLICY_FILE}'  then restart Chrome"
