#!/usr/bin/env bash
# Headless #201 PROVIDER-NULL test. Exercises the ServiceStarter provider-null
# retry fix (the starter-module half of #201), separate from the token-race half.
#
# The server is started with SHIZUKU_REPRO_FORCE_NULL=2 (and the token-race
# spawn-delay turned OFF), so every spawned ServiceStarter's manager-provider
# lookup is forced to return null for its first 2 attempts - simulating a
# frozen/unpublished manager provider (the reported #201 condition, "provider is
# null ... System.exit status 1"). The stock starter (baseline) has no retry and
# exits(1) -> the UserService never connects -> the app HARD-FAILs. The fixed
# starter retries past the 2 nulls -> connects -> clean.
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
dump_pn_logcat() {
  adb logcat -d 2>/dev/null | grep -Ei "forcing provider null|provider is null|System.exit called, status|retrying in|retry works|send binder to|BinderSender|$APP" | tail -n 120 || true
}

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
adb logcat -G 16M || true
adb logcat -c || true
adb shell svc power stayon true || true
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell settings put global stay_on_while_plugged_in 3 2>/dev/null || true
adb shell dumpsys deviceidle disable >/dev/null 2>&1 || true

MGR_APK=$(ls manager/build/outputs/apk/debug/*.apk | head -n1)
APP_APK=$(ls stress-app/app/build/outputs/apk/debug/*.apk | head -n1)
echo "manager apk: $MGR_APK"; echo "app apk:     $APP_APK"
adb install -r -g "$MGR_APK"
adb install -r -g "$APP_APK"

adb shell pm grant "$APP" moe.shizuku.manager.permission.API_V23 2>/dev/null || true
adb shell pm grant "$APP" android.permission.READ_LOGS 2>/dev/null || true
adb shell pm grant "$APP" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb shell dumpsys deviceidle whitelist +"$APP" >/dev/null 2>&1 || true

if adb shell run-as "$APP" id >/dev/null 2>&1; then echo "run-as OK"; else echo "WARNING: run-as failed"; fi

# Client must be running before the server so the startup sweep can push the binder.
adb shell monkey -p "$MGR" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
adb shell am start -n "$APP/.MainActivity" >/dev/null 2>&1 || true
sleep 6

# Start the server WITH the provider-null forcing env and the token-race delay OFF.
APK_DIR=$(dirname "$(adb shell pm path $MGR | sed 's/package://' | tr -d '\r' | head -n1)")
ABI=$(adb shell ls "$APK_DIR/lib/" | tr -d '\r' | head -n1)
echo "starter (force-null): $APK_DIR/lib/$ABI/libshizuku.so"
timeout 60 adb shell "SHIZUKU_REPRO_FORCE_NULL=2 SHIZUKU_REPRO_SPAWN_DELAY_MS=0 $APK_DIR/lib/$ABI/libshizuku.so" || true

UP=0
for i in $(seq 1 60); do
  adb shell pgrep -f shizuku_server >/dev/null 2>&1 && { UP=1; break; }
  sleep 2
done
[ "$UP" = "1" ] || { echo "ERROR: shizuku_server never started"; adb logcat -d > "$LOG"; tail -n 120 "$LOG"; exit 1; }
echo "shizuku_server is up (force-null mode)"
sleep 10

# Bring up the stress loop; retry if the binder isn't ready yet.
STARTED=0
for attempt in $(seq 1 5); do
  echo "=== bring-up attempt $attempt ==="
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell am start -n "$APP/.MainActivity" >/dev/null 2>&1 || true
  sleep 6
  adb shell am start-foreground-service -n "$SVC" >/dev/null 2>&1 || true
  for j in $(seq 1 8); do
    sleep 3; pull_results
    if grep -q 'Stress test started' "$RESULTS" 2>/dev/null; then
      if grep -Eq 'HALTED:' "$RESULTS" 2>/dev/null && ! grep -q 'churn=' "$RESULTS" 2>/dev/null; then
        adb shell am startservice -n "$SVC" -a "$APP.STOP" >/dev/null 2>&1 || true; break
      fi
      STARTED=1; break
    fi
  done
  [ "$STARTED" = "1" ] && { echo "stress loop is running"; break; }
  echo "-- diag --"; dump_pn_logcat
done
if [ "$STARTED" != "1" ]; then
  echo "ERROR: stress loop never started"; pull_results
  echo "--- results ---"; cat "$RESULTS" 2>/dev/null || echo "(empty)"
  adb logcat -d > "$LOG"; echo "--- logcat ---"; dump_pn_logcat; exit 1
fi

# Baseline HARD-FAILs quickly (every spawn exits on the forced null); fixed climbs.
DEADLINE=$((SECONDS+200))
while [ $SECONDS -lt $DEADLINE ]; do
  sleep 8; pull_results
  grep -q 'HARD FAILURE' "$RESULTS" 2>/dev/null && { echo "HARD FAILURE observed"; break; }
  grep -Eq '=== (Stopped|Halted)' "$RESULTS" 2>/dev/null && { echo "loop ended"; break; }
  LAST_CHURN=$(grep -oE 'churn=[0-9]+' "$RESULTS" 2>/dev/null | tail -n1 | cut -d= -f2)
  [ -n "${LAST_CHURN:-}" ] && [ "$LAST_CHURN" -ge 60 ] && { echo "reached churn=$LAST_CHURN"; break; }
done

adb shell am startservice -n "$SVC" -a "$APP.STOP" >/dev/null 2>&1 || true
sleep 3; pull_results
adb logcat -d > "$LOG" 2>/dev/null || true

echo "===== stress_results.log ====="; cat "$RESULTS" 2>/dev/null || echo "(empty)"
echo "===== provider-null logcat ====="
grep -E "forcing provider null|provider is null|System.exit called, status|retrying in|retry works|gave up after" "$LOG" | tail -n 120 || true
echo "==============================="

HARD=0;    grep -q 'HARD FAILURE' "$RESULTS" 2>/dev/null && HARD=1
STARTED_OK=0; grep -q 'Stress test started' "$RESULTS" 2>/dev/null && STARTED_OK=1
FORCED=0;  grep -q 'forcing provider null' "$LOG" && FORCED=1
NULLLOG=0; grep -Eq 'provider is null' "$LOG" && NULLLOG=1
RETRIED=0; grep -q 'forcing provider null (attempt 2/2)' "$LOG" && RETRIED=1
EXITED=0;  grep -Eq 'System.exit called, status: 1' "$LOG" && EXITED=1
LAST_CHURN=$(grep -oE 'churn=[0-9]+' "$RESULTS" 2>/dev/null | tail -n1 | cut -d= -f2); LAST_CHURN=${LAST_CHURN:-0}
echo "variant=$VARIANT expect=$EXPECT hardfail=$HARD churn=$LAST_CHURN forced=$FORCED retried=$RETRIED nulllog=$NULLLOG exited=$EXITED"

[ "$STARTED_OK" = "1" ] || { echo "FAIL: driver never started"; exit 1; }
[ "$FORCED" = "1" ]    || { echo "FAIL: provider-null was never forced (trigger inactive)"; exit 1; }

if [ "$EXPECT" = "reproduce" ]; then
  { [ "$HARD" = "1" ] && [ "$NULLLOG" = "1" ]; } && { echo "PASS(baseline): stock starter hit provider-null and wedged (#201 reproduced)"; exit 0; }
  echo "FAIL(baseline): expected a provider-null hard failure (hard=$HARD nulllog=$NULLLOG)"; exit 1
else
  [ "$HARD" = "1" ] && { echo "FAIL(fixed): hard failure - the retry did not absorb the forced provider-null"; exit 1; }
  [ "$RETRIED" = "1" ] || { echo "FAIL(fixed): never observed the 2nd forced-null retry - trigger too weak to prove the fix"; exit 1; }
  [ "$LAST_CHURN" -ge 40 ] || { echo "FAIL(fixed): too little churn ($LAST_CHURN) to trust a clean result"; exit 1; }
  echo "PASS(fixed): survived forced provider-null via bounded retry, $LAST_CHURN churn, no wedge"; exit 0
fi
