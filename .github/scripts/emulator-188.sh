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

wait_boot() {
  adb wait-for-device
  adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done' 2>/dev/null || true
}

wait_boot

echo "############ seed stale persisted port + reboot ############"
adb root >/dev/null 2>&1 || true; sleep 2; wait_boot
adb shell setprop persist.adb.tcp.port $DEAD_PORT
echo "seeded persist.adb.tcp.port=[$(adb shell getprop persist.adb.tcp.port | tr -d '\r')]"
adb reboot; sleep 5; wait_boot
adb root >/dev/null 2>&1 || true; sleep 2; wait_boot
echo "after reboot: persist=[$(adb shell getprop persist.adb.tcp.port | tr -d '\r')] service=[$(adb shell getprop service.adb.tcp.port | tr -d '\r')]"

echo "############ install manager + grant perms ############"
MGR_APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
echo "manager apk: $MGR_APK"
adb install -r -g "$MGR_APK"
adb shell pm grant $MGR android.permission.WRITE_SECURE_SETTINGS 2>/dev/null || true
adb shell pm grant $MGR android.permission.READ_LOGS 2>/dev/null || true
adb shell pm grant $MGR android.permission.POST_NOTIFICATIONS 2>/dev/null || true

adb logcat -c || true

echo "############ trigger real start path via harness receiver ############"
adb shell am broadcast -a $MGR.REPRO188 -n $MGR/.receiver.Repro188Receiver | tr -d '\r'

DECISION=""; RESOLVED=""
for i in $(seq 1 30); do
  sleep 3
  BUF=$(adb logcat -d -s REPRO188 2>/dev/null | tr -d '\r')
  DECISION=$(echo "$BUF" | grep -oE '\[repro\] decision:.*' | tail -n1)
  RESOLVED=$(echo "$BUF" | grep -oE '\[repro\] resolved start port=[0-9-]+.*' | tail -n1)
  if [ -n "$DECISION" ]; then
    if [ "$EXPECT" = "clean" ] || [ -n "$RESOLVED" ]; then break; fi
  fi
done

# Full artifact log: repro markers + worker/adb-client errors around them.
adb logcat -d 2>/dev/null | tr -d '\r' | grep -Ei 'REPRO188|AdbStart|AdbStarter|AdbClient|UnknownHost|Connection refused|shizuku' | tail -n 200 > "$LOG" || true

echo "===== [repro] markers ====="
adb logcat -d -s REPRO188 2>/dev/null | tr -d '\r' | grep -E '\[repro\]' || echo "(no [repro] logs!)"
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
