#!/usr/bin/env bash
# [repro] #237 behavioral harness. Reproduces Shizuku tearing down TCP on a
# background start even when the user only wants it torn down on an explicit
# settings toggle (lisonge).
#
# Precondition: TCP mode OFF + a configured ADB TCP port present. With TCP mode
# off, isWifiRequired() is true, so the worker only runs under an UNMETERED
# WorkManager constraint -> we MUST bring up the emulator's unmetered AndroidWifi
# first (probe-confirmed: WIFI + NOT_METERED + INTERNET + VALIDATED).
#
#   baseline (stock): AdbStartWorker calls AdbStarter.stopTcp on this start -> #237
#   fixed:            the worker no longer calls stopTcp -> no teardown on start
# Signals: REPRO237 "decision" (receiver ran) + REPRO188 worker log (worker ran) +
# REPRO237 "stopTcp invoked" (baseline only). Never merged into the fix PR.
set -uo pipefail

MGR=moe.shizuku.privileged.api
PORT=5555
LOG=logcat.txt
EXPECT="${EXPECT:-reproduce}"
VARIANT="${VARIANT:-unknown}"

wait_boot() {
  adb wait-for-device
  adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done' 2>/dev/null || true
}

wait_boot

echo "############ bring up unmetered AndroidWifi (needed: TCP-mode-off => isWifiRequired) ############"
adb shell svc wifi enable 2>/dev/null || true
adb shell cmd wifi connect-network AndroidWifi open 2>/dev/null || true
UNMETERED=0
for i in $(seq 1 20); do
  sleep 3
  CAPS=$(adb shell dumpsys connectivity 2>/dev/null | tr -d '\r' | grep -iE 'Transports: WIFI.*Capabilities:' | head -1)
  echo "  t=$((i*3))s caps=[$(echo "$CAPS" | grep -oE 'Capabilities:[^]]*' | head -1)]"
  echo "$CAPS" | grep -q 'NOT_METERED' && echo "$CAPS" | grep -q 'INTERNET' && { UNMETERED=1; echo "  -> unmetered WIFI is default"; break; }
done
[ "$UNMETERED" = "1" ] || echo "WARNING: no unmetered WIFI default network; worker may not run"

echo "############ seed a configured ADB TCP port (TCP mode will be set OFF by receiver) ############"
adb root >/dev/null 2>&1 || true; sleep 2; wait_boot
adb shell svc wifi enable 2>/dev/null || true
adb shell cmd wifi connect-network AndroidWifi open 2>/dev/null || true
sleep 5
adb shell setprop persist.adb.tcp.port $PORT
echo "getAdbTcpPort source: persist.adb.tcp.port=[$(adb shell getprop persist.adb.tcp.port | tr -d '\r')]"

echo "############ install manager + grant perms ############"
MGR_APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
echo "manager apk: $MGR_APK"
adb install -r -g "$MGR_APK"
adb shell pm grant $MGR android.permission.WRITE_SECURE_SETTINGS 2>/dev/null || true
adb shell pm grant $MGR android.permission.READ_LOGS 2>/dev/null || true
adb shell pm grant $MGR android.permission.POST_NOTIFICATIONS 2>/dev/null || true

echo "launch manager once to leave stopped-state + init prefs"
adb shell monkey -p $MGR -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 6
adb logcat -c || true

echo "############ trigger #237 start path via harness receiver ############"
adb shell am broadcast -a $MGR.REPRO237 \
  -n $MGR/moe.shizuku.manager.receiver.Repro237Receiver \
  -f 0x00000020 | tr -d '\r'

DECISION=""; STOPTCP=""; WORKER=""
for i in $(seq 1 30); do
  sleep 3
  BUF=$(adb logcat -d 2>/dev/null | tr -d '\r' | grep -E 'REPRO237|REPRO188')
  DECISION=$(echo "$BUF" | grep -oE 'REPRO237: \[repro\] decision:.*' | tail -n1)
  STOPTCP=$(echo "$BUF" | grep -oE 'AdbStarter\.stopTcp invoked.*' | tail -n1)
  WORKER=$(echo "$BUF" | grep -oE 'REPRO188: \[repro\] getAdbTcpPort\(\)=.*' | tail -n1)
  # once the worker has run, both baseline (stopTcp before) and fixed (no stopTcp)
  # have produced their verdict, so we can stop early.
  [ -n "$WORKER" ] && break
done

adb logcat -d 2>/dev/null | tr -d '\r' | grep -Ei 'REPRO237|REPRO188|AdbStart|AdbStarter|shizuku' | tail -n 250 > "$LOG" || true

echo "===== [repro] markers ====="
adb logcat -d 2>/dev/null | tr -d '\r' | grep -E 'REPRO237|REPRO188' | grep -E '\[repro\]|stopTcp invoked' || echo "(no [repro] logs!)"
echo "==========================="

WOULD=$(echo "$DECISION" | grep -oE 'wouldStopTcp=(true|false)' | cut -d= -f2)
echo "variant=$VARIANT expect=$EXPECT receiverRan=$([ -n "$DECISION" ] && echo yes || echo no) wouldStopTcp=${WOULD:-none} workerRan=$([ -n "$WORKER" ] && echo yes || echo no) stopTcpInvoked=$([ -n "$STOPTCP" ] && echo yes || echo no)"

# --- assertions ---
[ -n "$DECISION" ] || { echo "FAIL: no #237 decision log (receiver never ran)"; exit 1; }
[ "$WOULD" = "true" ] || { echo "FAIL: precondition not met (wouldStopTcp=$WOULD; need port>0 && tcpMode off)"; exit 1; }
[ -n "$WORKER" ] || { echo "FAIL: worker never ran (unmetered wifi constraint unsatisfied?) -- cannot judge stopTcp"; exit 1; }

if [ "$EXPECT" = "reproduce" ]; then
  [ -n "$STOPTCP" ] || { echo "FAIL(baseline): worker ran but stopTcp was NOT invoked"; exit 1; }
  echo "PASS(baseline): worker tore down TCP on a background start (#237 reproduced)"; exit 0
else
  [ -n "$STOPTCP" ] && { echo "FAIL(fixed): stopTcp still invoked from the start path"; exit 1; }
  echo "PASS(fixed): worker ran with TCP mode off and did NOT tear down TCP"; exit 0
fi
