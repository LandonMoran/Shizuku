#!/usr/bin/env bash
# Headless #201 stress test, run inside android-emulator-runner's `script`.
# Starts Shizuku via its native launcher, fires the REPRO_201 broadcast (which
# drives a bind/unbind loop against a throwaway UserService with a widened
# spawn->attach window), captures logcat, and asserts the FIX absorbed the race.
set -uo pipefail

PKG=moe.shizuku.privileged.api
RECEIVER="$PKG/moe.shizuku.manager.repro.Repro201Receiver"
LOG=logcat.txt
COUNT=30
INTERVAL=50

echo "::group::wait for device"
adb wait-for-device
adb root || true
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
echo "::endgroup::"

echo "::group::install manager"
APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
echo "installing $APK"
adb install -r -g "$APK"
echo "::endgroup::"

echo "::group::start shizuku server via libshizuku.so"
adb logcat -c || true
APK_DIR=$(dirname "$(adb shell pm path $PKG | sed 's/package://' | tr -d '\r' | head -n1)")
ABI=$(adb shell ls "$APK_DIR/lib/" | tr -d '\r' | head -n1)
echo "starter: $APK_DIR/lib/$ABI/libshizuku.so"
timeout 60 adb shell "$APK_DIR/lib/$ABI/libshizuku.so" || true
UP=0
for i in $(seq 1 60); do
  if adb shell pgrep -f shizuku_server >/dev/null 2>&1; then UP=1; break; fi
  sleep 2
done
if [ "$UP" != "1" ]; then
  echo "ERROR: shizuku_server never started"
  adb logcat -d > "$LOG"; tail -n 120 "$LOG"; exit 1
fi
echo "shizuku_server is up"
echo "::endgroup::"

# let the server push its binder to the manager process before we trigger
sleep 8

echo "::group::capture logcat + fire REPRO_201"
adb logcat -v time > "$LOG" &
LOGPID=$!
adb shell am broadcast -a ${PKG}.REPRO_201 -n "$RECEIVER" --ei count $COUNT --el interval $INTERVAL
echo "::endgroup::"

echo "::group::wait for repro to run/drain"
DEADLINE=$((SECONDS+300))
while [ $SECONDS -lt $DEADLINE ]; do
  if grep -Eq 'REPRODUCED #201|unable to find token|System.exit called, status: 1' "$LOG"; then
    echo "hard-failure signature seen"; sleep 3; break
  fi
  if grep -q 'stress loop finished' "$LOG" && grep -q '\[repro\] attach OK' "$LOG"; then
    echo "stress loop finished and attaches observed"; sleep 5; break
  fi
  sleep 3
done
kill $LOGPID 2>/dev/null || true
echo "::endgroup::"

echo "===== relevant logcat ====="
grep -E 'Repro201|\[repro\]|unable to find token|System.exit called, status|provider is null|destroying the attaching binder|retry works|starting server' "$LOG" || true
echo "==========================="

FAIL=0
if ! grep -q '\[repro\] delaying user-service spawn' "$LOG"; then
  echo "MISSING: repro spawn-delay never logged (server repro instrumentation did not run)"; FAIL=1
fi
if ! grep -Eq 'Repro201.*(broadcast received|starting stress loop)' "$LOG"; then
  echo "MISSING: REPRO_201 broadcast was not received by the manager"; FAIL=1
fi
if grep -Eq 'REPRODUCED #201|unable to find token|System.exit called, status: 1' "$LOG"; then
  echo "HARD FAILURE: issue #201 reproduced - the fix did NOT hold"; FAIL=1
fi
if ! grep -q '\[repro\] attach OK' "$LOG"; then
  echo "FAIL: no successful UserService attach was observed"; FAIL=1
fi

if [ "$FAIL" != "0" ]; then
  echo "RESULT: FAIL"; exit 1
fi
echo "RESULT: PASS - race window was active, attaches completed, and #201 did not reproduce"
