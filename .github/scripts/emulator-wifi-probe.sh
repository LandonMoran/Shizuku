#!/usr/bin/env bash
# [repro] Wi-Fi recon. The FIXED #188 worker only runs under a NetworkType.UNMETERED
# WorkManager constraint, which needs an active network with INTERNET + NOT_METERED.
# The port probe showed Wi-Fi present but DISCONNECTED and a metered eth0 as default.
# This answers, empirically:
#   1. Does the emulated AndroidWifi AP auto-associate if we wait?
#   2. Can we force-connect it (cmd wifi / svc wifi)?
#   3. Once connected, is WIFI the DEFAULT network, and does it carry INTERNET +
#      NOT_METERED + VALIDATED (what WorkManager needs)?
#   4. Can we override metering (cmd netpolicy set-metered-network)?
# Pure recon; drives no app code. Never merged.
set -uo pipefail

wait_boot() {
  adb wait-for-device
  adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done' 2>/dev/null || true
}
netdump() {
  echo "  wifi state : [$(adb shell dumpsys wifi 2>/dev/null | grep -iE 'Wi-Fi is|current SSID' | head -1 | tr -d '\r')]"
  echo "  default net: [$(adb shell dumpsys connectivity 2>/dev/null | grep -iE 'Active default network' | head -1 | tr -d '\r')]"
  echo "  caps       : [$(adb shell dumpsys connectivity 2>/dev/null | grep -iE 'Capabilities:.*INTERNET' | head -1 | tr -d '\r')]"
  echo "  metered ifs: [$(adb shell dumpsys netpolicy 2>/dev/null | grep -iE 'Metered ifaces' | head -1 | tr -d '\r')]"
}

wait_boot
echo "############ 1. fresh state ############"
netdump

echo "############ 2. wait up to 60s for AndroidWifi auto-association ############"
for i in $(seq 1 20); do
  SSID=$(adb shell dumpsys wifi 2>/dev/null | grep -iE 'current SSID|mWifiInfo SSID' | head -1 | tr -d '\r')
  echo "  t=$((i*3))s $SSID"
  echo "$SSID" | grep -iq 'AndroidWifi' && { echo "  -> associated"; break; }
  sleep 3
done

echo "############ 3. force-connect attempts ############"
echo "svc wifi enable:";        adb shell svc wifi enable 2>&1 | tr -d '\r' || true
echo "cmd wifi connect open:";  adb shell cmd wifi connect-network AndroidWifi open 2>&1 | tr -d '\r' || true
echo "cmd wifi status:";        adb shell cmd wifi status 2>&1 | tr -d '\r' | head -6 || true
sleep 8
netdump

echo "############ 4. metering overrides ############"
adb shell cmd netpolicy set-metered-network AndroidWifi false 2>&1 | tr -d '\r' || true
adb shell cmd connectivity 2>&1 | tr -d '\r' | head -1 || true
sleep 3
netdump

echo "############ 5. the WorkManager question: any INTERNET + NOT_METERED net? ############"
adb shell dumpsys connectivity 2>/dev/null | tr -d '\r' | grep -iE 'NetworkAgentInfo.*(WIFI|ETHERNET)' | head -6 || true
echo "NOT_METERED present on a validated net?"
adb shell dumpsys connectivity 2>/dev/null | tr -d '\r' | grep -iE 'Capabilities:.*NOT_METERED' | head -6 || echo "  (none found)"

echo "############ WIFI PROBE COMPLETE ############"
exit 0
