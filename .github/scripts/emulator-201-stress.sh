#!/usr/bin/env bash
# Headless #201 stress test, invoked by android-emulator-runner as `bash <this>`.
# Parameterized by env: EXPECT (clean|reproduce), VARIANT, PROFILE.
set -uo pipefail

PKG=moe.shizuku.privileged.api
RECEIVER="$PKG/moe.shizuku.manager.repro.Repro201Receiver"
LOG=logcat.txt
COUNT=30
INTERVAL=50
EXPECT="${EXPECT:-clean}"
VARIANT="${VARIANT:-unknown}"
PROFILE="${PROFILE:-unknown}"

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'

APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
echo "installing $APK"
adb install -r -g "$APK"

adb logcat -c || true
adb logcat -G 16M || true
APK_DIR=$(dirname "$(adb shell pm path $PKG | sed 's/package://' | tr -d '\r' | head -n1)")
ABI=$(adb shell ls "$APK_DIR/lib/" | tr -d '\r' | head -n1)
echo "starter: $APK_DIR/lib/$ABI/libshizuku.so"
timeout 60 adb shell "$APK_DIR/lib/$ABI/libshizuku.so" || true

UP=0
for i in $(seq 1 60); do
  adb shell pgrep -f shizuku_server >/dev/null 2>&1 && { UP=1; break; }
  sleep 2
done
if [ "$UP" != "1" ]; then echo "ERROR: shizuku_server never started"; adb logcat -d > "$LOG"; tail -n 100 "$LOG"; exit 1; fi
echo "shizuku_server is up"

# let the server push its binder to the manager process before triggering
sleep 15

echo "firing REPRO_201 (count=$COUNT interval=$INTERVAL)"
adb shell am broadcast -a ${PKG}.REPRO_201 -n "$RECEIVER" --ei count $COUNT --el interval $INTERVAL

DEADLINE=$((SECONDS+240))
while [ $SECONDS -lt $DEADLINE ]; do
  adb logcat -d > "$LOG" 2>/dev/null || true
  grep -Eq 'REPRODUCED #201|unable to find token|System.exit called, status: 1' "$LOG" && break
  if grep -q 'stress loop finished' "$LOG" && grep -Eq '\[repro\] attach OK|destroying the attaching binder' "$LOG"; then sleep 5; break; fi
  sleep 5
done
adb logcat -d > "$LOG" 2>/dev/null || true

echo "===== relevant logcat ====="
grep -E 'Repro201|\[repro\]|unable to find token|System.exit called, status|provider is null|destroying the attaching binder|retry works|send binder to user app' "$LOG" || true
echo "==========================="

REPRODUCED=0; grep -Eq 'REPRODUCED #201|unable to find token|System.exit called, status: 1' "$LOG" && REPRODUCED=1
DROVE=0; grep -Eq 'Repro201.*(broadcast received|starting stress loop)' "$LOG" && DROVE=1
DELAYED=0; grep -q '\[repro\] delaying user-service spawn' "$LOG" && DELAYED=1
echo "variant=$VARIANT expect=$EXPECT profile=$PROFILE reproduced=$REPRODUCED drove=$DROVE delayed=$DELAYED"

[ "$DROVE" = "1" ] || { echo "FAIL: stress driver never ran (broadcast not received / manager had no binder)"; exit 1; }
[ "$DELAYED" = "1" ] || { echo "FAIL: repro spawn-delay never logged"; exit 1; }

if [ "$EXPECT" = "reproduce" ]; then
  [ "$REPRODUCED" = "1" ] && { echo "PASS(baseline): #201 reproduced as expected"; exit 0; }
  echo "FAIL(baseline): expected #201 to reproduce but it did not"; exit 1
else
  [ "$REPRODUCED" = "1" ] && { echo "FAIL(fixed): #201 reproduced - fix did not hold"; exit 1; }
  grep -q '\[repro\] attach OK' "$LOG" || { echo "FAIL(fixed): no successful attach observed"; exit 1; }
  echo "PASS(fixed): no #201, attaches completed"; exit 0
fi
