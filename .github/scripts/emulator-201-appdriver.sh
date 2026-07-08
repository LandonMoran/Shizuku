#!/usr/bin/env bash
# Headless #201 stress test driven by the EXTERNAL stress-tester app
# (com.landonmoran.repro201tester, v2.0). Invoked by android-emulator-runner as
# `bash <this>`. Parameterized by env: EXPECT (clean|reproduce), VARIANT.
#
# The app is a real Shizuku client: it receives the binder through the normal
# provider path and its pass/fail oracle is a DIRECT verifiedBind connection
# (CountDownLatch on onServiceConnected), not a logcat grep. So this leg avoids
# both the in-manager broadcast fragility and the READ_LOGS false-pass risk.
set -uo pipefail

MGR=moe.shizuku.privileged.api
APP=com.landonmoran.repro201tester
SVC="$APP/.StressTestService"
LOG=logcat.txt
RESULTS=stress_results.log
EXPECT="${EXPECT:-clean}"
VARIANT="${VARIANT:-unknown}"

pull_results() {
  adb shell run-as "$APP" cat files/stress_results.log 2>/dev/null | tr -d '\r' > "$RESULTS" || true
}

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
adb logcat -G 16M || true
adb logcat -c || true

# Keep the device awake, unlocked, and out of Doze for the whole run. A visible,
# non-frozen client is essential: if Android freezes/throttles the driver process
# (cached-app freezer, Doze, App Standby) the stress loop stalls in a way that
# could either look like the bug or mask it. We want the driver to be the top,
# resumed app the entire time.
adb shell svc power stayon true || true
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard 2>/dev/null || true
adb shell settings put global stay_on_while_plugged_in 3 2>/dev/null || true
adb shell dumpsys deviceidle disable >/dev/null 2>&1 || true

MGR_APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
APP_APK=$(ls stress-app/app/build/outputs/apk/debug/*.apk | head -n1)
echo "manager apk: $MGR_APK"
echo "app apk:     $APP_APK"
adb install -r -g "$MGR_APK"
adb install -r -g "$APP_APK"

# Pre-authorize the stress-tester as a Shizuku client. The server enforces
# permission per-uid; seeding the grant before the server starts authorizes the
# uid server-side. READ_LOGS only enables the app's SECONDARY logcat scan - the
# primary oracle is the direct binder connection.
adb shell pm grant "$APP" moe.shizuku.manager.permission.API_V23 2>/dev/null || true
adb shell pm grant "$APP" android.permission.READ_LOGS 2>/dev/null || true
adb shell pm grant "$APP" android.permission.POST_NOTIFICATIONS 2>/dev/null || true

# Exempt the driver from Doze / background restrictions so its process is never
# frozen mid-run.
adb shell dumpsys deviceidle whitelist +"$APP" >/dev/null 2>&1 || true
adb shell cmd appops set "$APP" RUN_ANY_IN_BACKGROUND allow 2>/dev/null || true

# Fresh installs are in the stopped state; provider/binder delivery won't reach a
# stopped package. Launch the manager to clear FLAG_STOPPED and publish its
# provider (it relays the binder to authorized clients).
adb shell monkey -p "$MGR" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 3

# Start the Shizuku server (the code under test) from the manager's native lib.
APK_DIR=$(dirname "$(adb shell pm path $MGR | sed 's/package://' | tr -d '\r' | head -n1)")
ABI=$(adb shell ls "$APK_DIR/lib/" | tr -d '\r' | head -n1)
echo "starter: $APK_DIR/lib/$ABI/libshizuku.so"
timeout 60 adb shell "$APK_DIR/lib/$ABI/libshizuku.so" || true

UP=0
for i in $(seq 1 60); do
  adb shell pgrep -f shizuku_server >/dev/null 2>&1 && { UP=1; break; }
  sleep 2
done
[ "$UP" = "1" ] || { echo "ERROR: shizuku_server never started"; adb logcat -d > "$LOG"; tail -n 120 "$LOG"; exit 1; }
echo "shizuku_server is up"
sleep 12   # let the server hand the binder to the manager

# Bring up the client process so its ShizukuProvider requests + receives the
# binder (relayed by the running manager), then start the stress loop headlessly.
# Retry the whole bring-up if the loop halts at startup for a not-yet-ready binder.
STARTED=0
for attempt in $(seq 1 4); do
  echo "=== bring-up attempt $attempt ==="
  # Open the Activity to the FOREGROUND (not just a background service). READ_LOGS
  # is already granted, so MainActivity won't try to self-close via its grant
  # flow - it settles on "Ready" and stays visible. A resumed, visible Activity
  # keeps the whole process out of the cached/frozen state.
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell am start -n "$APP/.MainActivity" >/dev/null 2>&1 || true
  sleep 15   # binder delivery to the client
  FG=$(adb shell dumpsys activity activities 2>/dev/null | grep -Eo "$APP/[^ }]*MainActivity" | head -n1)
  echo "foreground activity: ${FG:-<none detected>}"
  adb shell am start-foreground-service -n "$SVC" >/dev/null 2>&1 || true
  for j in $(seq 1 8); do
    sleep 3
    pull_results
    if grep -q 'Stress test started' "$RESULTS" 2>/dev/null; then
      if grep -Eq 'HALTED:' "$RESULTS" 2>/dev/null && ! grep -q 'churn=' "$RESULTS" 2>/dev/null; then
        echo "loop halted at startup (binder not ready yet); retrying bring-up"
        adb shell am startservice -n "$SVC" -a "$APP.STOP" >/dev/null 2>&1 || true
        break
      fi
      STARTED=1; break
    fi
  done
  [ "$STARTED" = "1" ] && { echo "stress loop is running"; break; }
done

if [ "$STARTED" != "1" ]; then
  echo "ERROR: stress loop never started (client never got the Shizuku binder)"
  pull_results
  echo "----- stress_results.log -----"; cat "$RESULTS" 2>/dev/null || echo "(empty)"
  adb logcat -d > "$LOG"
  echo "----- shizuku / binder logcat -----"
  grep -E "Shizuku|shizuku|$APP|send binder|REQUEST_BINDER|\[repro\]" "$LOG" | tail -n 150 || true
  exit 1
fi

# Let the app spam bind/unbind. Baseline should self-terminate with a HARD
# FAILURE once the forced race wedges the server; fixed should keep climbing.
DEADLINE=$((SECONDS+240))
TICK=0
while [ $SECONDS -lt $DEADLINE ]; do
  sleep 8
  # Keep the driver visible/awake so it's never frozen mid-run (cheap insurance).
  TICK=$((TICK+1))
  if [ $((TICK % 5)) -eq 0 ]; then
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb shell am start -n "$APP/.MainActivity" >/dev/null 2>&1 || true
  fi
  pull_results
  grep -q 'HARD FAILURE' "$RESULTS" 2>/dev/null && { echo "HARD FAILURE observed"; break; }
  grep -Eq '=== (Stopped|Halted)' "$RESULTS" 2>/dev/null && { echo "loop ended on its own"; break; }
  LAST_CHURN=$(grep -oE 'churn=[0-9]+' "$RESULTS" 2>/dev/null | tail -n1 | cut -d= -f2)
  [ -n "${LAST_CHURN:-}" ] && [ "$LAST_CHURN" -ge 400 ] && { echo "reached churn=$LAST_CHURN"; break; }
done

# Stop cleanly and collect.
adb shell am startservice -n "$SVC" -a "$APP.STOP" >/dev/null 2>&1 || true
sleep 3
pull_results
adb logcat -d > "$LOG" 2>/dev/null || true

echo "===== stress_results.log ====="
cat "$RESULTS" 2>/dev/null || echo "(empty)"
echo "===== relevant logcat ====="
grep -E "\[repro\]|unable to find token|System.exit called, status|provider is null|destroying the attaching binder|send binder to user app|$APP" "$LOG" | tail -n 200 || true
echo "=========================="

HARD=0;     grep -q 'HARD FAILURE' "$RESULTS" 2>/dev/null && HARD=1
RECOVERED=0; grep -qE '\([1-9][0-9]* needed retry' "$RESULTS" 2>/dev/null && RECOVERED=1
STARTED_OK=0; grep -q 'Stress test started' "$RESULTS" 2>/dev/null && STARTED_OK=1
DELAYED=0;  grep -q '\[repro\] delaying user-service spawn' "$LOG" && DELAYED=1
LAST_CHURN=$(grep -oE 'churn=[0-9]+' "$RESULTS" 2>/dev/null | tail -n1 | cut -d= -f2)
LAST_CHURN=${LAST_CHURN:-0}
echo "variant=$VARIANT expect=$EXPECT hardfail=$HARD recovered=$RECOVERED churn=$LAST_CHURN delayed=$DELAYED"

[ "$STARTED_OK" = "1" ] || { echo "FAIL: driver never started"; exit 1; }
[ "$DELAYED" = "1" ]   || { echo "FAIL: repro spawn-delay never logged (race not forced)"; exit 1; }

if [ "$EXPECT" = "reproduce" ]; then
  [ "$HARD" = "1" ] && { echo "PASS(baseline): #201 reproduced (hard failure) as expected"; exit 0; }
  echo "FAIL(baseline): expected a hard failure but none occurred (churn=$LAST_CHURN)"; exit 1
else
  [ "$HARD" = "1" ] && { echo "FAIL(fixed): #201 hard failure - fix did not hold"; exit 1; }
  [ "$LAST_CHURN" -ge 100 ] || { echo "FAIL(fixed): too little churn ($LAST_CHURN) to trust a clean result"; exit 1; }
  echo "PASS(fixed): $LAST_CHURN churn cycles under the forced race, no hard failure (recovered=$RECOVERED)"; exit 0
fi
