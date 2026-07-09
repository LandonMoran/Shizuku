#!/usr/bin/env bash
# [repro] #188 environment recon. Answers the questions the harness design hinges
# on, so we build the real A/B once instead of guessing:
#   1. On a fresh emulator boot, is service.adb.tcp.port / persist.adb.tcp.port set?
#   2. Does `adb root` work (userdebug image)?
#   3. Can we setprop persist.adb.tcp.port as root?
#   4. Does persist.adb.tcp.port SURVIVE a reboot?
#   5. After reboot, what does adbd set service.adb.tcp.port to?
#   6. Does the host adb connection survive setprop(persist) + reboot?
#   7. (last, risky) Does setprop service.adb.tcp.port drop the host connection?
# Pure recon: it drives no app code. Never merged into a PR.
set -uo pipefail

wait_boot() {
  adb wait-for-device
  adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done' 2>/dev/null || true
}

echo "############ 1. FRESH BOOT ############"
wait_boot
echo "id -u                 = [$(adb shell id -u 2>/dev/null | tr -d '\r')]"
echo "ro.build.type         = [$(adb shell getprop ro.build.type | tr -d '\r')]"
echo "service.adb.tcp.port  = [$(adb shell getprop service.adb.tcp.port | tr -d '\r')]"
echo "persist.adb.tcp.port  = [$(adb shell getprop persist.adb.tcp.port | tr -d '\r')]"
echo "adb_wifi_enabled      = [$(adb shell settings get global adb_wifi_enabled 2>/dev/null | tr -d '\r')]"
echo "--- all adb-ish props ---"
adb shell getprop | grep -Ei 'adb' | tr -d '\r' || true

echo "############ 2. adb root ############"
adb root || echo "adb root returned nonzero"
sleep 3; wait_boot
echo "id -u after root      = [$(adb shell id -u 2>/dev/null | tr -d '\r')]"

echo "############ 3. seed persist.adb.tcp.port=43217 ############"
if adb shell setprop persist.adb.tcp.port 43217 2>&1 | tr -d '\r'; then
  echo "setprop exit=$?"
fi
echo "persist now           = [$(adb shell getprop persist.adb.tcp.port | tr -d '\r')]"
echo "service now           = [$(adb shell getprop service.adb.tcp.port | tr -d '\r')]"

echo "############ 4/5/6. REBOOT and re-check ############"
adb reboot || echo "reboot cmd returned nonzero"
sleep 5; wait_boot
echo "host adb survived reboot: id -u = [$(adb shell id -u 2>/dev/null | tr -d '\r')]"
echo "AFTER REBOOT persist.adb.tcp.port = [$(adb shell getprop persist.adb.tcp.port | tr -d '\r')]"
echo "AFTER REBOOT service.adb.tcp.port = [$(adb shell getprop service.adb.tcp.port | tr -d '\r')]"

echo "############ WIFI / NETWORK (does the FIXED variant have an unmetered net?) ############"
echo "wifi_on               = [$(adb shell settings get global wifi_on 2>/dev/null | tr -d '\r')]"
adb shell dumpsys wifi 2>/dev/null | grep -iE 'Wi-Fi is|current SSID|mWifiInfo' | head -5 | tr -d '\r' || true
echo "--- active default network ---"
adb shell dumpsys connectivity 2>/dev/null | grep -iE 'Active default network|Current state|NetworkAgentInfo\{.*WIFI|VALIDATED|NOT_METERED|METERED' | head -20 | tr -d '\r' || true
echo "--- transport + metered of default net (cmd) ---"
adb shell cmd connectivity 2>/dev/null | head -1 | tr -d '\r' || true
adb shell dumpsys netpolicy 2>/dev/null | grep -iE 'meter' | head -10 | tr -d '\r' || true

echo "############ 7. (risky, last) setprop service.adb.tcp.port=43217 ############"
adb root || true; sleep 2; wait_boot
adb shell setprop service.adb.tcp.port 43217 2>&1 | tr -d '\r' || true
sleep 3
echo "host still connected? id -u = [$(timeout 15 adb shell id -u 2>/dev/null | tr -d '\r')]"
echo "service.adb.tcp.port  = [$(timeout 15 adb shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')]"

echo "############ PROBE COMPLETE ############"
exit 0
