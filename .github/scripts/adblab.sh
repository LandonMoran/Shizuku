#!/usr/bin/env bash
# [probe] Runs the ADB behavior bench headlessly on the emulator: install the
# nettest APK, grant the local-network permissions, launch MainActivity in auto
# mode, and scrape the ADBLAB result lines. The interactive-only loopback probe
# reports SKIP here (emulators do no real wireless-debugging); the value is the
# cross-version table for the headless probes (ports, settings, LNP, mDNS types).
set -uo pipefail
APP=dev.adbprobe
OUT=adblab-results.txt

wait_boot() {
  timeout 60 adb wait-for-device 2>/dev/null || true
  local t=0
  while [ "$(timeout 15 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
    sleep 3; t=$((t+3)); [ "$t" -ge 180 ] && { echo "  wait_boot TIMEOUT"; return 1; }
  done
  echo "  boot_completed (${t}s)"; return 0
}

wait_boot || echo "WARN: boot wait timed out"

APK=$(ls nettest/build/outputs/apk/debug/*.apk 2>/dev/null | head -n1)
echo "apk: $APK"
timeout 180 adb install -r -g "$APK" || echo "WARN: install nonzero"

for p in android.permission.NEARBY_WIFI_DEVICES android.permission.ACCESS_LOCAL_NETWORK android.permission.READ_LOGS; do
  timeout 15 adb shell pm grant $APP $p 2>/dev/null || true
done

# Best-effort: turn on wireless debugging so adbd advertises its mDNS service.
timeout 15 adb shell settings put global development_settings_enabled 1 || true
timeout 15 adb shell settings put global adb_wifi_enabled 1 || true
sleep 2

timeout 15 adb logcat -c || true
echo "launch auto probe run"
timeout 30 adb shell am start -n $APP/dev.adbprobe.MainActivity --ez auto true >/dev/null 2>&1 || echo "WARN: am start nonzero"

# The mDNS probe sweeps 3 types x 4s, so DONE can take ~15-20s.
for i in $(seq 1 30); do
  sleep 3
  adb logcat -d 2>/dev/null | tr -d '\r' | grep -q 'ADBLAB.*DONE' && break
done

echo "===== ADBLAB results (api ${API_LEVEL:-?}) ====="
adb logcat -d 2>/dev/null | tr -d '\r' | grep -oE 'RESULT\|[^"]*' | sort -u | tee "$OUT"
echo "==============================================="
[ -s "$OUT" ] || echo "(no ADBLAB result lines captured)"
exit 0
