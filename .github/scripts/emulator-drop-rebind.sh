#!/usr/bin/env bash
# Drop-vs-rebind reproduction driven by the external driver app in MODE_DROPREBIND.
# Env: EXPECT (clean|reproduce), VARIANT. Invoked by android-emulator-runner.
#
# Server is started with SHIZUKU_REPRO_FORCE_SPAWN_FAIL=1 (fail the first spawn per
# token, after a delay) and SHIZUKU_REPRO_SPAWN_DELAY_MS=0 (the fail hook supplies
# its own delay). The driver binds A, unbinds(remove=true) while the spawn is in
# flight, then rebinds B on the same record. baseline drops the record -> B never
# connects -> HARD FAILURE; fixed respawns -> B connects.
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
adb logcat -G 64M || true
adb logcat -c || true
adb shell svc power stayon true || true
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard 2>/dev/null || true
adb shell settings put global stay_on_while_plugged_in 3 2>/dev/null || true
adb shell dumpsys deviceidle disable >/dev/null 2>&1 || true

MGR_APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
APP_APK=$(ls stress-app/app/build/outputs/apk/debug/*.apk | head -n1)
echo "manager apk: $MGR_APK"; echo "app apk: $APP_APK"
adb install -r -g "$MGR_APK"
adb install -r -g "$APP_APK"

adb shell pm grant "$APP" moe.shizuku.manager.permission.API_V23 2>/dev/null || true
adb shell pm grant "$APP" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb shell dumpsys deviceidle whitelist +"$APP" >/dev/null 2>&1 || true
adb shell cmd appops set "$APP" RUN_ANY_IN_BACKGROUND allow 2>/dev/null || true

if adb shell run-as "$APP" id >/dev/null 2>&1; then echo "run-as OK"; else echo "WARNING: run-as $APP failed"; fi

# Client must be alive before the server's startup sweep so it gets the binder.
adb shell monkey -p "$MGR" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
adb shell am start -n "$APP/.MainActivity" >/dev/null 2>&1 || true
sleep 6

# Start the Shizuku server (code under test) with the force-spawn-fail env.
APK_DIR=$(dirname "$(adb shell pm path $MGR | sed 's/package://' | tr -d '\r' | head -n1)")
ABI=$(adb shell ls "$APK_DIR/lib/" | tr -d '\r' | head -n1)
echo "starter: $APK_DIR/lib/$ABI/libshizuku.so"
timeout 60 adb shell "SHIZUKU_REPRO_FORCE_SPAWN_FAIL=1 SHIZUKU_REPRO_SPAWN_DELAY_MS=0 $APK_DIR/lib/$ABI/libshizuku.so" || true

UP=0
for i in $(seq 1 60); do
  adb shell pgrep -f shizuku_server >/dev/null 2>&1 && { UP=1; break; }
  sleep 2
done
[ "$UP" = "1" ] || { echo "ERROR: shizuku_server never started"; adb logcat -d > "$LOG"; tail -n 120 "$LOG"; exit 1; }
echo "shizuku_server is up"
sleep 12   # let the startup sweep push the binder to the client

# Start the drop-rebind loop.
STARTED=0
for attempt in $(seq 1 5); do
  echo "=== bring-up attempt $attempt ==="
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell am start -n "$APP/.MainActivity" >/dev/null 2>&1 || true
  sleep 5
  adb shell am start-foreground-service -n "$SVC" --es mode droprebind >/dev/null 2>&1 || true
  for j in $(seq 1 8); do
    sleep 3
    pull_results
    grep -q 'Stress test started' "$RESULTS" 2>/dev/null && { STARTED=1; break; }
  done
  [ "$STARTED" = "1" ] && { echo "drop-rebind loop is running"; break; }
done

if [ "$STARTED" != "1" ]; then
  echo "ERROR: driver never started"; pull_results; cat "$RESULTS" 2>/dev/null
  adb logcat -d > "$LOG"; grep -E "\[repro\]|$APP" "$LOG" | tail -n 80 || true; exit 1
fi

# Poll: baseline hard-fails on the first iteration (~15s); fixed climbs churn.
CHURN_TARGET=3
DEADLINE=$((SECONDS+360))
STOP_REASON=deadline
while [ $SECONDS -lt $DEADLINE ]; do
  sleep 6
  adb logcat -d >> "$LOG" 2>/dev/null || true
  adb logcat -c >/dev/null 2>&1 || true
  pull_results
  grep -q 'HARD FAILURE' "$RESULTS" 2>/dev/null && { STOP_REASON=hardfail; echo "HARD FAILURE observed"; break; }
  LAST_CHURN=$(grep -oE 'churn=[0-9]+' "$RESULTS" 2>/dev/null | tail -n1 | cut -d= -f2)
  [ -n "${LAST_CHURN:-}" ] && [ "$LAST_CHURN" -ge $CHURN_TARGET ] && { STOP_REASON=target; echo "reached churn target $LAST_CHURN"; break; }
done

adb shell am startservice -n "$SVC" -a "$APP.STOP" >/dev/null 2>&1 || true
sleep 2
pull_results
adb logcat -d >> "$LOG" 2>/dev/null || true

echo "===== stress_results.log ====="; cat "$RESULTS" 2>/dev/null || echo "(empty)"
echo "===== [repro] logcat ====="
grep -E "\[repro\]|forcing spawn FAILURE|respawning|drop" "$LOG" | tail -n 120 || true
echo "=============================="

HARD=0;   grep -q 'HARD FAILURE' "$RESULTS" 2>/dev/null && HARD=1
STARTED_OK=0; grep -q 'Stress test started' "$RESULTS" 2>/dev/null && STARTED_OK=1
FORCED=0; grep -q 'forcing spawn FAILURE' "$LOG" 2>/dev/null && FORCED=1
RESPAWNED=0; grep -q 'respawning' "$LOG" 2>/dev/null && RESPAWNED=1
LAST_CHURN=$(grep -oE 'churn=[0-9]+' "$RESULTS" 2>/dev/null | tail -n1 | cut -d= -f2); LAST_CHURN=${LAST_CHURN:-0}
echo "variant=$VARIANT expect=$EXPECT hardfail=$HARD forced=$FORCED respawned=$RESPAWNED churn=$LAST_CHURN"

[ "$STARTED_OK" = "1" ] || { echo "FAIL: driver never started"; exit 1; }
[ "$FORCED" = "1" ]     || { echo "FAIL: force-spawn-fail never logged (trigger not fired)"; exit 1; }

if [ "$EXPECT" = "reproduce" ]; then
  [ "$HARD" = "1" ] && { echo "PASS(baseline): drop-vs-rebind reproduced (rebind stranded) as expected"; exit 0; }
  echo "FAIL(baseline): expected a hard failure but none occurred (churn=$LAST_CHURN)"; exit 1
else
  [ "$HARD" = "1" ] && { echo "FAIL(fixed): rebind was still stranded - fix did not hold"; exit 1; }
  [ "$RESPAWNED" = "1" ] || { echo "FAIL(fixed): never observed a respawn (fix path not exercised)"; exit 1; }
  [ "$LAST_CHURN" -ge $CHURN_TARGET ] || { echo "FAIL(fixed): too little churn ($LAST_CHURN) to trust clean"; exit 1; }
  echo "PASS(fixed): $LAST_CHURN drop-rebind cycles, respawn observed, no strand"; exit 0
fi
