#!/usr/bin/env bash
# [probe] #197 Path A viability. Question: can the emulator's adbd perform real
# Wireless-debugging PAIRING headlessly -- i.e. can we (a) get adbd to start a
# pairing server and (b) read the pairing CODE + the pairing IP:PORT without a
# human tapping the UI? If yes, an authentic end-to-end #197 test is possible
# against real adbd (scrape the code, submit it clean -> success, submit it with a
# trailing space -> baseline fails / fixed succeeds). If no, we fall back to a
# custom known-code SPAKE2 server harness (Path B), which does not depend on any
# of this.
#
# This is a PROBE: it gathers evidence, prints a single VERDICT line, and always
# exits 0. It never drives app code. Bounded (never hangs). Never merged.
set -uo pipefail
LOG=probe.txt
: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }

wait_boot() {
  timeout 60 adb wait-for-device 2>/dev/null || true
  local t=0
  while [ "$(timeout 15 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
    sleep 3; t=$((t+3)); [ "$t" -ge 180 ] && { say "  wait_boot TIMEOUT"; return 1; }
  done
  say "  boot_completed (${t}s)"; return 0
}

# Dump the current window to XML and pull it locally. Bounded.
ui_dump() {
  timeout 20 adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || return 1
  timeout 15 adb pull /sdcard/ui.xml ./ui.xml >/dev/null 2>&1 || return 1
  return 0
}

# Find the first node whose text/content-desc contains $1 (case-insensitive) and
# tap its center. Returns 0 on tap, 1 if not found. Uses python to parse bounds.
ui_tap() {
  local needle="$1"
  ui_dump || return 1
  local xy
  xy=$(python3 - "$needle" <<'PY'
import sys, re
needle = sys.argv[1].lower()
try:
    xml = open('ui.xml', encoding='utf-8', errors='ignore').read()
except Exception:
    sys.exit(1)
for m in re.finditer(r'<node\b[^>]*?>', xml):
    tag = m.group(0)
    text = (re.search(r'text="([^"]*)"', tag) or [None, ''])[1]
    desc = (re.search(r'content-desc="([^"]*)"', tag) or [None, ''])[1]
    if needle in text.lower() or needle in desc.lower():
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if b:
            x = (int(b.group(1)) + int(b.group(3))) // 2
            y = (int(b.group(2)) + int(b.group(4))) // 2
            print(f"{x} {y}"); break
PY
)
  [ -n "$xy" ] || return 1
  # shellcheck disable=SC2086
  timeout 15 adb shell input tap $xy >/dev/null 2>&1 || return 1
  say "  tapped '$needle' at ($xy)"
  return 0
}

wait_boot || say "WARN: initial boot wait timed out"

say "############ 1. bring up Wi-Fi (pairing/mDNS needs a real network) ############"
timeout 15 adb shell svc wifi enable 2>&1 | tr -d '\r' || true
timeout 15 adb shell cmd wifi connect-network AndroidWifi open 2>&1 | tr -d '\r' || true
sleep 8
say "  wifi: [$(timeout 15 adb shell dumpsys wifi 2>/dev/null | grep -iE 'Wi-Fi is|current SSID' | head -1 | tr -d '\r')]"

say "############ 2. enable developer options + wireless debugging ############"
timeout 15 adb shell settings put global development_settings_enabled 1 || true
BEFORE=$(timeout 15 adb shell ss -H -ltn 2>/dev/null | tr -d '\r' | awk '{print $4}' | sort -u)
timeout 15 adb shell settings put global adb_wifi_enabled 1 || true
sleep 5
say "  adb_wifi_enabled=[$(timeout 15 adb shell settings get global adb_wifi_enabled | tr -d '\r')]"
AFTER=$(timeout 15 adb shell ss -H -ltn 2>/dev/null | tr -d '\r' | awk '{print $4}' | sort -u)
say "  NEW listening sockets after enabling wireless debugging:"
comm -13 <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/    /' | tee -a "$LOG" || true

say "############ 3. adbd / pairing service evidence in logs + dumpsys ############"
timeout 20 adb logcat -d 2>/dev/null | tr -d '\r' | grep -iE 'adbwifi|adb_wifi|pairing|adb-tls|AdbDebugging|mdns' | tail -n 20 | sed 's/^/    /' | tee -a "$LOG" || say "    (no adbd wireless-debugging log lines)"
timeout 15 adb shell dumpsys adb 2>/dev/null | tr -d '\r' | grep -iE 'pairing|wifi|tls|port' | head -n 15 | sed 's/^/    /' | tee -a "$LOG" || true

say "############ 4. navigate to 'Pair device with pairing code' + scrape ############"
# Best-effort: open developer settings, then walk Wireless debugging -> Pair.
timeout 20 adb shell am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS >/dev/null 2>&1 || true
sleep 3
# Some builds expose a direct wireless-debugging screen; try it too (harmless if absent).
timeout 15 adb shell am start -a android.settings.ADB_WIRELESS_SETTINGS >/dev/null 2>&1 || true
sleep 2
ui_tap "wireless debugging" || say "  (could not find 'Wireless debugging' toggle row)"
sleep 2
ui_tap "pair device with pairing code" || ui_tap "pair device" || say "  (could not find 'Pair device with pairing code')"
sleep 3

CODE=""; IPPORT=""
if ui_dump; then
  # code may render grouped ("123 456"); strip spaces from text then match 6 digits.
  CODE=$(python3 - <<'PY'
import re
t = open('ui.xml', encoding='utf-8', errors='ignore').read()
texts = re.findall(r'text="([^"]*)"', t)
for s in texts:
    d = re.sub(r'\s+', '', s)
    m = re.fullmatch(r'\d{6}', d)
    if m:
        print(d); break
PY
)
  IPPORT=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}' ui.xml 2>/dev/null | head -n1)
fi
say "  scraped pairing code=[${CODE:-none}]  ip:port=[${IPPORT:-none}]"

say "############ VERDICT ############"
VIABLE=no
[ -n "$CODE" ] && [ -n "$IPPORT" ] && VIABLE=yes
say "PROBE VERDICT: PATH_A_VIABLE=$VIABLE"
if [ "$VIABLE" = "yes" ]; then
  say "  -> authentic real-adbd pairing is reachable headlessly; Path A end-to-end #197 test is feasible."
else
  say "  -> could NOT obtain a pairing code + port headlessly; use the custom known-code"
  say "     SPAKE2 server harness (Path B) for the end-to-end #197 test."
fi
exit 0
