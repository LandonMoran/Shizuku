#!/usr/bin/env bash
# [repro] Focused reboot probe. Isolates ONE question with full diagnostics:
# after an in-script `adb reboot`, does the emulator recover, how long does it
# take, and what does boot-detection report meanwhile? Run on API 30 (known-good)
# and API 36 (the hang) to see the difference. No app build; pure recon.
set -uo pipefail

API="${API:-unknown}"
say() { echo "[probe api=$API] $*"; }

say "=== initial boot ==="
timeout 120 adb wait-for-device 2>/dev/null || say "wait-for-device timed out"
timeout 15 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | sed "s/^/  boot_completed=/"

say "=== adb root + seed persist.adb.tcp.port=43217 ==="
timeout 30 adb root 2>&1 | tr -d '\r' | sed 's/^/  root: /' || say "adb root nonzero"
timeout 60 adb wait-for-device 2>/dev/null || say "post-root wait-for-device timed out"
say "state after root: [$(timeout 15 adb get-state 2>&1 | tr -d '\r')]"
timeout 15 adb shell setprop persist.adb.tcp.port 43217 2>&1 | tr -d '\r' | sed 's/^/  setprop: /' || true
say "persist=[$(timeout 15 adb shell getprop persist.adb.tcp.port 2>/dev/null | tr -d '\r')]"

say "=== adb reboot -- watch recovery (verbose, up to 300s) ==="
timeout 30 adb reboot 2>&1 | tr -d '\r' | sed 's/^/  reboot: /' || say "adb reboot returned nonzero"
t=0
RECOVERED=0
while [ "$t" -lt 300 ]; do
  sleep 10; t=$((t+10))
  STATE=$(timeout 12 adb get-state 2>&1 | tr -d '\r')
  BC=$(timeout 12 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  say "t=${t}s state=[$STATE] boot_completed=[$BC]"
  if [ "$BC" = "1" ]; then RECOVERED=1; say "RECOVERED after ${t}s"; break; fi
done
[ "$RECOVERED" = "1" ] || say "NEVER recovered within 300s"

say "=== post-reboot property survival ==="
say "persist=[$(timeout 15 adb shell getprop persist.adb.tcp.port 2>/dev/null | tr -d '\r')] service=[$(timeout 15 adb shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')]"
say "=== PROBE COMPLETE ==="
exit 0
