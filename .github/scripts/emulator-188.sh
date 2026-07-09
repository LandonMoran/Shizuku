#!/usr/bin/env bash
# [repro] #188 behavioral harness. Seeds a stale/dead persisted ADB TCP port,
# reboots (probe-confirmed to survive), then drives the REAL AdbStartWorker via
# the harness receiver and observes the port decision + connection attempt.
#
#   BASELINE (stock): getAdbTcpPort()=<dead> -> useStaleDirect=true -> the worker
#     resolves the dead port and connects to 127.0.0.1:<dead> -> fails. #188.
#   FIXED: the dead persisted port is not trusted -> useStaleDirect=false ->
#     routed to discovery; never resolves/connects to the dead port.
#
# The decision is logged by Repro188Receiver at trigger time (fires for both
# variants); the "resolved start port" line is logged only when the worker runs
# (baseline; the fixed worker is gated by an UNMETERED constraint the CI emulator
# can't satisfy -- see the probe). Never merged into the fix PR.
set -uo pipefail

MGR=moe.shizuku.privileged.api
DEAD_PORT=43217
LOG=logcat.txt
EXPECT="${EXPECT:-reproduce}"
VARIANT="${VARIANT:-unknown}"

# Bounded boot wait: never spins forever (the API-36 hang was an unbounded loop
# after an in-script reboot). Returns non-zero on timeout so callers can proceed.
wait_boot() {
  timeout 60 adb wait-for-device 2>/dev/null || true
  local t=0
  while [ "$(timeout 15 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
    sleep 3; t=$((t+3))
    if [ "$t" -ge 240 ]; then echo "  wait_boot: TIMEOUT after ${t}s"; return 1; fi
  done
  echo "  boot_completed (${t}s)"; return 0
}
gp() { timeout 15 adb shell getprop "$1" 2>/dev/null | tr -d '\r'; }

wait_boot || echo "WARN: initial wait_boot timed out"

echo "############ seed stale persisted port + reboot ############"
timeout 30 adb root >/dev/null 2>&1 || true; sleep 2; wait_boot || true
timeout 15 adb shell setprop persist.adb.tcp.port $DEAD_PORT || true
echo "seeded persist.adb.tcp.port=[$(gp persist.adb.tcp.port)]"
echo "rebooting (best-effort; harness continues even if recovery is slow)..."
timeout 30 adb reboot >/dev/null 2>&1 || echo "  adb reboot returned nonzero"
sleep 5
if wait_boot; then
  timeout 30 adb root >/dev/null 2>&1 || true; sleep 2; wait_boot || true
  echo "after reboot: persist=[$(gp persist.adb.tcp.port)] service=[$(gp service.adb.tcp.port)]"
else
  echo "WARN: no recovery from reboot within timeout; reconnecting + re-seeding on current device"
  timeout 30 adb reconnect >/dev/null 2>&1 || true
  timeout 30 adb reconnect offline >/dev/null 2>&1 || true
  wait_boot || true
  timeout 30 adb root >/dev/null 2>&1 || true; sleep 2
  timeout 15 adb shell setprop persist.adb.tcp.port $DEAD_PORT 2>/dev/null || true
  echo "post-timeout: persist=[$(gp persist.adb.tcp.port)] service=[$(gp service.adb.tcp.port)]"
fi

echo "############ install manager + grant perms ############"
MGR_APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
echo "manager apk: $MGR_APK"
timeout 180 adb install -r -g "$MGR_APK" || echo "WARN: install returned nonzero"
adb shell pm grant $MGR android.permission.WRITE_SECURE_SETTINGS 2>/dev/null || true
adb shell pm grant $MGR android.permission.READ_LOGS 2>/dev/null || true
adb shell pm grant $MGR android.permission.POST_NOTIFICATIONS 2>/dev/null || true

# Launch the manager once: a freshly-installed app is in the "stopped" state and
# receives no broadcasts until first launched. This also runs ShizukuApplication
# init (ShizukuSettings.initialize).
echo "launch manager once to leave stopped-state + init prefs"
timeout 45 adb shell monkey -p $MGR -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 6

timeout 15 adb logcat -c || true

echo "############ trigger real start path via harness receiver ############"
# Full class name: the manifest's ".receiver.X" resolves the CLASS against the
# manifest namespace (moe.shizuku.manager), not the applicationId. -f 0x20 =
# FLAG_INCLUDE_STOPPED_PACKAGES as belt-and-suspenders.
timeout 30 adb shell am broadcast -a $MGR.REPRO188 \
  -n $MGR/moe.shizuku.manager.receiver.Repro188Receiver \
  -f 0x00000020 | tr -d '\r'

DECISION=""; RESOLVED=""
for i in $(seq 1 30); do
  sleep 3
  BUF=$(adb logcat -d 2>/dev/null | tr -d '\r' | grep 'REPRO188')
  DECISION=$(echo "$BUF" | grep -oE '\[repro\] decision:.*' | tail -n1)
  RESOLVED=$(echo "$BUF" | grep -oE '\[repro\] resolved start port=[0-9-]+.*' | tail -n1)
  if [ -n "$DECISION" ]; then
    if [ "$EXPECT" = "clean" ] || [ -n "$RESOLVED" ]; then break; fi
  fi
done

# Full artifact log: repro markers + worker/adb-client errors + any crash.
adb logcat -d 2>/dev/null | tr -d '\r' | grep -Ei 'REPRO188|AdbStart|AdbStarter|AdbClient|AndroidRuntime|UnknownHost|Connection refused|shizuku' | tail -n 250 > "$LOG" || true

echo "===== [repro] markers ====="
adb logcat -d 2>/dev/null | tr -d '\r' | grep -E 'REPRO188.*\[repro\]' || echo "(no [repro] logs!)"
echo "==========================="

USE_STALE=$(echo "$DECISION" | grep -oE 'useStaleDirect=(true|false)' | cut -d= -f2)
GOT_PORT=$(echo "$DECISION" | grep -oE 'getAdbTcpPort\(\)=[0-9-]+' | cut -d= -f2)
RESOLVED_PORT=$(echo "$RESOLVED" | grep -oE 'port=[0-9-]+' | head -n1 | cut -d= -f2)
echo "variant=$VARIANT expect=$EXPECT getAdbTcpPort=${GOT_PORT:-none} useStaleDirect=${USE_STALE:-none} resolvedPort=${RESOLVED_PORT:-none}"

# --- assertions ---
[ -n "$DECISION" ] || { echo "FAIL: no decision log (receiver/worker never ran)"; exit 1; }
[ "$GOT_PORT" = "$DEAD_PORT" ] || { echo "FAIL: getAdbTcpPort did not return the seeded dead port ($GOT_PORT != $DEAD_PORT)"; exit 1; }

if [ "$EXPECT" = "reproduce" ]; then
  [ "$USE_STALE" = "true" ] || { echo "FAIL(baseline): expected useStaleDirect=true, got $USE_STALE"; exit 1; }
  [ "$RESOLVED_PORT" = "$DEAD_PORT" ] || { echo "FAIL(baseline): worker did not resolve to the dead port (resolved=${RESOLVED_PORT:-none})"; exit 1; }
  echo "PASS(baseline): stale dead port $DEAD_PORT used directly, discovery skipped (#188 reproduced)"; exit 0
else
  [ "$USE_STALE" = "false" ] || { echo "FAIL(fixed): stale dead port still trusted (useStaleDirect=$USE_STALE)"; exit 1; }
  [ "$RESOLVED_PORT" = "$DEAD_PORT" ] && { echo "FAIL(fixed): worker resolved to the dead port despite the fix"; exit 1; }
  echo "PASS(fixed): stale dead port $DEAD_PORT rejected, routed to discovery (decision changed)"; exit 0
fi
