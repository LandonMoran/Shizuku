#!/usr/bin/env bash
# [repro] #188 on Android TV (legacy, SDK < 33 -> isTlsSupported()==false, so the
# non-TLS-TV configured-port fallback is active). Proves the fix is coherent on the
# TV path: a legacy TV skips mDNS discovery (can't do TLS), so it connects to a
# port DIRECTLY -- and it must be the CONFIGURED port, not the stale persisted one.
#
#   baseline (stock): resolves to the stale persist port 43217   -> #188 on TV
#   fixed:            resolves to the configured getTcpPort 5555  -> right port
# On TV isWifiRequired() is false, so the worker runs without any Wi-Fi. Reboot is
# kept (start-on-boot is the scenario); legacy TV recovers like an API-30 phone.
set -uo pipefail

MGR=moe.shizuku.privileged.api
DEAD_PORT=43217
TCP_PORT=5555
LOG=logcat.txt
EXPECT="${EXPECT:-reproduce}"
VARIANT="${VARIANT:-unknown}"

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
echo "leanback feature (TV): [$(timeout 15 adb shell pm list features 2>/dev/null | tr -d '\r' | grep -i leanback | head -1)]"

echo "############ seed stale persisted port + reboot ############"
timeout 30 adb root >/dev/null 2>&1 || true; sleep 2; wait_boot || true
timeout 15 adb shell setprop persist.adb.tcp.port $DEAD_PORT || true
echo "seeded persist.adb.tcp.port=[$(gp persist.adb.tcp.port)]"
echo "rebooting (best-effort)..."
timeout 30 adb reboot >/dev/null 2>&1 || echo "  adb reboot nonzero"
sleep 5
if wait_boot; then
  timeout 30 adb root >/dev/null 2>&1 || true; sleep 2; wait_boot || true
  echo "after reboot: persist=[$(gp persist.adb.tcp.port)] service=[$(gp service.adb.tcp.port)]"
else
  echo "WARN: no reboot recovery; reconnect + re-seed"
  timeout 30 adb reconnect >/dev/null 2>&1 || true; wait_boot || true
  timeout 30 adb root >/dev/null 2>&1 || true; sleep 2
  timeout 15 adb shell setprop persist.adb.tcp.port $DEAD_PORT 2>/dev/null || true
fi

echo "############ install manager + grant perms ############"
MGR_APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
echo "manager apk: $MGR_APK"
timeout 180 adb install -r -g "$MGR_APK" || echo "WARN: install nonzero"
timeout 15 adb shell pm grant $MGR android.permission.WRITE_SECURE_SETTINGS 2>/dev/null || true
timeout 15 adb shell pm grant $MGR android.permission.READ_LOGS 2>/dev/null || true
timeout 15 adb shell pm grant $MGR android.permission.POST_NOTIFICATIONS 2>/dev/null || true

echo "launch manager once (leave stopped-state + init prefs)"
timeout 45 adb shell monkey -p $MGR -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 6
timeout 15 adb logcat -c || true

echo "############ trigger start path via harness receiver ############"
timeout 30 adb shell am broadcast -a $MGR.REPRO188 \
  -n $MGR/moe.shizuku.manager.receiver.Repro188Receiver \
  -f 0x00000020 | tr -d '\r'

DECISION=""; RESOLVED=""
for i in $(seq 1 30); do
  sleep 3
  BUF=$(timeout 20 adb logcat -d 2>/dev/null | tr -d '\r' | grep 'REPRO188')
  DECISION=$(echo "$BUF" | grep -oE '\[repro\] decision:.*' | tail -n1)
  RESOLVED=$(echo "$BUF" | grep -oE '\[repro\] resolved start port=[0-9-]+.*' | tail -n1)
  [ -n "$RESOLVED" ] && break
done

timeout 25 adb logcat -d 2>/dev/null | tr -d '\r' | grep -Ei 'REPRO188|AdbStart|AdbStarter|AdbClient|shizuku' | tail -n 250 > "$LOG" || true
echo "===== [repro] markers ====="
timeout 20 adb logcat -d 2>/dev/null | tr -d '\r' | grep -E 'REPRO188.*\[repro\]' || echo "(no [repro] logs!)"
echo "==========================="

GOT_PORT=$(echo "$DECISION" | grep -oE 'getAdbTcpPort\(\)=[0-9-]+' | cut -d= -f2)
RESOLVED_PORT=$(echo "$RESOLVED" | grep -oE 'start port=[0-9-]+' | grep -oE '[0-9-]+$')
echo "variant=$VARIANT expect=$EXPECT getAdbTcpPort=${GOT_PORT:-none} resolvedPort=${RESOLVED_PORT:-none}"

# --- assertions (TV path uses a port DIRECTLY; the question is WHICH port) ---
[ -n "$DECISION" ] || { echo "FAIL: no decision log (receiver never ran)"; exit 1; }
[ -n "$RESOLVED_PORT" ] || { echo "FAIL: worker never resolved a port (did it run? is this really a TV?)"; exit 1; }

if [ "$EXPECT" = "reproduce" ]; then
  [ "$RESOLVED_PORT" = "$DEAD_PORT" ] || { echo "FAIL(baseline): expected TV to use stale $DEAD_PORT, got $RESOLVED_PORT"; exit 1; }
  echo "PASS(baseline): TV connected to the stale persisted port $DEAD_PORT (#188 on TV)"; exit 0
else
  [ "$RESOLVED_PORT" = "$DEAD_PORT" ] && { echo "FAIL(fixed): TV still used the stale port $DEAD_PORT"; exit 1; }
  [ "$RESOLVED_PORT" = "$TCP_PORT" ] || { echo "FAIL(fixed): expected TV to use configured $TCP_PORT, got $RESOLVED_PORT"; exit 1; }
  echo "PASS(fixed): TV used the configured live port $TCP_PORT, not the stale $DEAD_PORT"; exit 0
fi
