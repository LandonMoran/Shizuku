#!/usr/bin/env bash
# [repro] #221 behavioral harness. Proves AutoDisableUsbDebuggingReceiver reconciles
# on a real boot: with "auto-disable USB debugging" on and start-on-boot off, after a
# reboot the receiver fires and decides to disable USB debugging (the thing that never
# happened before, because the disable only ran on an explicit STOPPING stop).
#
# To avoid actually setting ADB_ENABLED=0 (which would kill adb mid-test), the
# precondition also sets repro_no_disable=true, so the receiver LOGS its decision
# instead of disabling. We assert the boot-time decision shouldDisable=true.
# API 30 (its emulator survives an in-script reboot; API 36's does not). Harness-only.
set -uo pipefail

MGR=moe.shizuku.privileged.api
LOG=logcat.txt

wait_boot() {
  timeout 60 adb wait-for-device 2>/dev/null || true
  local t=0
  while [ "$(timeout 15 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
    sleep 3; t=$((t+3))
    if [ "$t" -ge 240 ]; then echo "  wait_boot: TIMEOUT after ${t}s"; return 1; fi
  done
  echo "  boot_completed (${t}s)"; return 0
}

wait_boot || echo "WARN: initial wait_boot timed out"

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

echo "############ set #221 precondition (auto-disable on, repro log-only) ############"
timeout 30 adb shell am broadcast -a $MGR.REPRO221 \
  -n $MGR/moe.shizuku.manager.receiver.Repro221Receiver \
  -f 0x00000020 | tr -d '\r'
sleep 3
echo "precondition log:"; timeout 15 adb shell run-as $MGR true 2>/dev/null; adb logcat -d 2>/dev/null | tr -d '\r' | grep 'REPRO221' | grep 'precondition' | tail -2 || echo "(none yet)"

echo "############ reboot -- the actual scenario ############"
timeout 15 adb logcat -c || true
timeout 30 adb reboot >/dev/null 2>&1 || echo "  reboot nonzero"
sleep 5
if ! wait_boot; then echo "WARN: no reboot recovery"; timeout 30 adb reconnect >/dev/null 2>&1 || true; wait_boot || true; fi
timeout 30 adb root >/dev/null 2>&1 || true; sleep 2; wait_boot || true

echo "############ observe the boot reconcile decision ############"
RECON=""
for i in $(seq 1 25); do
  sleep 3
  RECON=$(timeout 20 adb logcat -d 2>/dev/null | tr -d '\r' | grep 'REPRO221' | grep 'boot reconcile' | tail -n1)
  [ -n "$RECON" ] && break
done
timeout 25 adb logcat -d 2>/dev/null | tr -d '\r' | grep 'REPRO221' | tail -n 40 > "$LOG" || true

echo "===== REPRO221 markers ====="
timeout 20 adb logcat -d 2>/dev/null | tr -d '\r' | grep 'REPRO221' || echo "(no REPRO221 logs!)"
echo "============================"

SHOULD=$(echo "$RECON" | grep -oE 'shouldDisable=(true|false)' | cut -d= -f2)
AUTO=$(echo "$RECON" | grep -oE 'autoDisable=(true|false)' | cut -d= -f2)
SOB=$(echo "$RECON" | grep -oE 'startOnBoot=(true|false)' | cut -d= -f2)
echo "boot reconcile: autoDisable=${AUTO:-none} startOnBoot=${SOB:-none} shouldDisable=${SHOULD:-none}"

# --- assertions ---
[ -n "$RECON" ] || { echo "FAIL: AutoDisableUsbDebuggingReceiver did NOT fire on boot"; exit 1; }
[ "$AUTO" = "true" ] || { echo "FAIL: auto-disable precondition not set (autoDisable=$AUTO)"; exit 1; }
[ "$SHOULD" = "true" ] || { echo "FAIL: boot receiver did not decide to disable (shouldDisable=$SHOULD)"; exit 1; }
echo "PASS: after a real reboot the receiver reconciled and decided to disable USB debugging (#221 fixed)"
exit 0
