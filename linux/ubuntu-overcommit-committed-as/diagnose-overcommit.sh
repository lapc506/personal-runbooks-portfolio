#!/usr/bin/env bash
#
# diagnose-overcommit.sh — READ-ONLY diagnostic for Linux kernel memory overcommit,
# Committed_AS / CommitLimit, and vm.swappiness.
#
# It only reads sysctls and /proc/meminfo (plus swap and journal state). It changes
# nothing on the system and requires no elevated privileges: run it as the current
# user, no sudo needed.
#
# Ground rules honored here:
#   - stderr is never discarded (no redirection to the null device anywhere);
#   - the only 2>&1 is into a pipe sink, so journal stderr stays visible;
#   - every command's exit status is surfaced at the end.

set -u

echo "== 1. sysctl: overcommit policy + ratio + swappiness =="
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness
rc_sysctl=$?

echo
echo "== 2. /proc/meminfo: totals, availability, commit accounting =="
grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Committed_AS|CommitLimit):' /proc/meminfo
rc_meminfo=$?

echo
echo "== 3. swap devices =="
swapon --show
rc_swapon=$?

echo
echo "== 4. free -h (human-readable; headers follow your locale) =="
free -h
rc_free=$?

echo
echo "== 5. ratios (kB, from /proc/meminfo) =="
awk '
  /^MemTotal:/      { mt = $2 }
  /^Committed_AS:/  { ca = $2 }
  /^CommitLimit:/    { cl = $2 }
  END {
    if (mt > 0) {
      printf "Committed_AS / MemTotal   = %.2f x physical RAM\n", ca / mt;
      if (cl > 0) {
        printf "Committed_AS / CommitLimit = %.2f\n", ca / cl;
        printf "CommitLimit / MemTotal     = %.2f\n", cl / mt;
      } else {
        print "CommitLimit: (not readable in this context)";
      }
    } else {
      print "MemTotal: (not readable in this context)";
    }
  }
' /proc/meminfo
rc_awk=$?

echo
echo "== 6. recent kernel OOM events (current boot, if any) =="
journalctl -k -b --no-pager 2>&1 | grep -i 'out of memory\|oom-kill' || echo "(none found)"
rc_oom=$?

echo
echo "== exit codes (0 = success) =="
printf 'sysctl=%d meminfo=%d swapon=%d free=%d awk=%d oom=%d\n' \
  "$rc_sysctl" "$rc_meminfo" "$rc_swapon" "$rc_free" "$rc_awk" "$rc_oom"
