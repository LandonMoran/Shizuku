# Reproducing Shizuku bugs on a GitHub Actions emulator

This is the playbook we used to reproduce, fix, and *prove the fix for* issue
**#201** (the UserService bind/unbind race), written up so the next bug doesn't
start from a blank page. It covers both harness shapes we need:

- **Shape A — race / stress harness:** for nondeterministic bugs (races,
  freeze/cache recovery). Force the triggering state, then hammer until it shows.
- **Shape B — boot-state harness:** for deterministic bugs that depend on
  device state at boot (a stale system property, a settings flag). Seed the
  state, reboot, observe. No stress loop needed.

The single most important idea, in both shapes:

> **Force the state. Don't wait for it to happen organically.**
> A race you can't schedule and a boot condition you can't seed are both
> untestable in CI. Every harness below works by *manufacturing* the exact
> precondition the bug needs, behind an env/property gate, so the failure is
> on-demand instead of once-in-a-blue-moon.

---

## Step 0 — Is this bug even emulator-reproducible?

The emulator is **stock AOSP**. Ask one question before writing a line of YAML:

**Does the bug live in Shizuku's code / AOSP behavior, or in an OEM's custom layer?**

| Reproducible on AOSP emulator | Not reproducible (OEM/hardware) |
|---|---|
| Bind/unbind & provider races (#201) | MIUI/HyperOS/OneUI/ColorOS process killers |
| Stale system property at boot (#188) | Vendor doze / battery-manager quirks |
| Settings-flag on boot/shutdown (#221) | "Works on some devices" reports |
| User-service spawn/recovery failures | Chipset- or firmware-specific behavior |
| Anything you can reach with `setprop`, `settings put`, `svc`, `dumpsys`, `am`, `pm`, `adb reboot` | Android versions with no emulator image yet (e.g. Android 17 today) |

Rule of thumb: if the report says **"on some devices"** or names a specific
skin, it's probably the OEM layer — skip it. If the mechanism is a property, a
setting, a broadcast, or an AOSP process-lifecycle state, it will reproduce.

*Caveat:* a "screen-off / keeps dying" report **can** collapse into the AOSP
`cached/frozen-process` family (the #201 mechanism) rather than an OEM killer.
When it does, it becomes reproducible via `dumpsys deviceidle force-idle` /
cached-process simulation. Read the thread before deciding.

---

## The A/B discipline (this is what makes it *proof*, not vibes)

A green "fixed" job proves nothing on its own — maybe the trigger never fired.
Every harness runs **two variants of the same code path**:

- **`baseline`** — the *stock*, pre-fix code. Expectation: **reproduce** (fail
  loudly). If baseline goes green, your trigger is too weak and the whole run is
  worthless.
- **`fixed`** — your patched code. Expectation: **clean**.

The workflow encodes the expectation per-variant and the harness script
*asserts* it (see "Exit codes are assertions" below). We keep the baseline as a
sibling branch (`…-baseline`) so both build from real history, not a flag.

> **Keep the `fixed` variant current — re-sync it before every run.** An A/B
> only proves something about the code the `fixed` job *actually builds*. The
> **`baseline` never changes** — it's stock, pre-fix code whose only job is to
> reproduce, so freeze it: once it reproduces, it always will, and you never
> need to touch it again. But the **`fixed` variant must incorporate the latest
> fix, re-checked every single run.** If the fix moved since the harness last
> built it — new commits on the fix branch, a converged or rebased branch (e.g.
> a hand-merge of two PRs that touch one file, like #244+#247), a bumped API
> submodule pin, a freshly resolved conflict — then the harness's `fixed`
> checkout is **stale**, and a green proves an *old* version, not what ships.
> Before you trust a `fixed` pass: diff the harness's `fixed` sources against
> the real fix branch, or re-point/re-sync the checkout to it. "Fixed passed"
> has to mean *this* fix passed.

We also fan out across **emulator profiles** (`fast`/`medium`/`slow` — varying
cores/RAM/heap) so a timing bug that only shows on a starved device still gets
caught. See the matrix in `.github/workflows/emulator-201-providernull.yml`.

---

## Anatomy of the workflow (`.github/workflows/emulator-201-*.yml`)

Key pieces, all load-bearing:

```yaml
on:
  push:
    branches: [ claude/code-session-review-vp9clq ]   # harness-only branch
  workflow_dispatch:

concurrency:
  group: <name>-${{ github.ref }}
  cancel-in-progress: true            # don't stack runs on rapid pushes

strategy:
  fail-fast: false                    # let every variant/profile report
  matrix:
    variant:  [ {name: fixed, ref: <branch>, expect: clean},
                {name: baseline, ref: <branch>-baseline, expect: reproduce} ]
    profile:  [ fast, medium, slow ]  # cores/RAM/heap knobs
```

Steps that matter:

1. **`actions/checkout` with `submodules: recursive` and `fetch-depth: 0`.**
   Shizuku pins the API as a submodule; shallow clones break the version-code
   count and can miss the pinned commit. Always full-depth + recursive.
2. **Check out the driver app separately** (`landonmoran/test`, the stress
   tester) into `path: stress-app`.
3. **JDK 21 (temurin) + `gradle/actions/setup-gradle`**, then
   `sdkmanager --licenses`.
4. **Build both APKs** — `:manager:assembleDebug` (code under test) and the
   driver's `:app:assembleDebug`. Debug builds only; no keystore.
5. **Enable KVM** via the `99-kvm4all.rules` udev snippet — without it the
   emulator falls back to software and everything times out.
6. **`reactivecircus/android-emulator-runner@v2`** with:
   ```yaml
   api-level: 30
   target: google_apis          # google_apis image => emulated AndroidWifi AP
   arch: x86_64
   emulator-options: -no-window -no-audio -no-boot-anim -no-snapshot \
                     -gpu swiftshader_indirect -camera-back none
   script: bash .github/scripts/<harness>.sh
   ```
7. **`upload-artifact` with `if: always()`** — pull `logcat.txt` and the
   results log on every run, pass *or* fail. You will read these.

> **Wi-Fi note:** the `google_apis` image (API 30+) ships a fake `AndroidWifi`
> access point, so the guest believes it's on Wi-Fi. That satisfies the
> *device-side* precondition for wireless-debugging code paths. What is **not**
> reliable in CI is a real host↔guest `adb pair` handshake (mDNS over the
> emulated NAT). Design around it — see Shape B / #188 below, which needs the
> port-read path, **not** a live pairing.

---

## Shape A — the race / stress harness (what #201 needed)

Reference: `.github/scripts/emulator-201-providernull.sh`.

### 1. Instrument the code behind an env gate
The fix's code path carries dormant, env-gated "force" hooks that only activate
when the harness sets them:

- `SHIZUKU_REPRO_FORCE_NULL=2` — force the manager-provider lookup to return
  null for the first N attempts (simulates the frozen/unpublished manager
  provider that is the actual #201 condition).
- `SHIZUKU_REPRO_SPAWN_DELAY_MS` — widen the token-race window on demand.
- `[repro]`-tagged log lines (`forcing provider null`, `retrying in…`,
  `System.exit called, status: 1`) so the script can *prove the trigger fired*.

These flags are **off by default and never merged upstream** (see Branch
hygiene). They are the difference between "we think it's fixed" and "we watched
the exact failure happen and then not happen."

### 2. Boot, install, de-flake the device
```bash
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
adb logcat -G 64M            # big buffer
adb shell svc power stayon true
adb shell settings put global stay_on_while_plugged_in 3
adb shell dumpsys deviceidle disable      # keep the test itself out of doze
adb install -r -g <manager.apk>
adb install -r -g <driver.apk>
adb shell pm grant <driver> moe.shizuku.manager.permission.API_V23
adb shell dumpsys deviceidle whitelist +<driver>
```

### 3. Start the server *with the force env*
```bash
APK_DIR=$(dirname "$(adb shell pm path $MGR | sed 's/package://')")
ABI=$(adb shell ls "$APK_DIR/lib/" | head -n1)
adb shell "SHIZUKU_REPRO_FORCE_NULL=2 SHIZUKU_REPRO_SPAWN_DELAY_MS=0 \
           $APK_DIR/lib/$ABI/libshizuku.so"
```
(The manager/client must already be running so the startup sweep can push the
binder.)

### 4. Drive it — a real app in a churn loop
The driver (`com.landonmoran.repro201tester`) binds/unbinds a UserService in a
tight loop from a foreground service, writing progress (`churn=N`) and a
`HARD FAILURE` sentinel to `files/stress_results.log`, which the script pulls
with `run-as`. Baseline hard-fails almost immediately (every spawn hits the
forced null and `exit(1)`s); fixed climbs churn indefinitely.

### 5. Exit codes are assertions
The script doesn't just log — it **decides**:
```bash
if [ "$EXPECT" = "reproduce" ]; then         # baseline
  [ "$HARD" = 1 ] && [ "$NULLLOG" = 1 ] && exit 0   # reproduced -> PASS
  exit 1                                             # baseline went green -> trigger broken
else                                          # fixed
  [ "$HARD" = 1 ] && exit 1                   # fixed still failed
  [ "$RETRIED" = 1 ] || exit 1               # never saw the forced retry -> unproven
  [ "$LAST_CHURN" -ge 200 ] || exit 1        # too little churn to trust "clean"
  exit 0
fi
```
Note the two guards that stop false greens: **fixed** must have *observed the
forced trigger fire* (`RETRIED`) and *accumulated real churn* — otherwise a job
that silently did nothing would masquerade as a pass.

---

## Shape B — the boot-state harness (what #188 / #221 will need)

Deterministic bugs don't need a stress loop. They need: **seed state → reboot →
observe once.** Much simpler and faster.

### Worked target: #188 — faulty ADB TCP port in system properties on boot

Root cause (confirmed in source, not just the thread):

- `EnvironmentUtils.getAdbTcpPort()` reads `service.adb.tcp.port`, then falls
  back to **`persist.adb.tcp.port`** (which *survives reboot*).
- `AdbStartWorker.doWork()` does
  `val port = tcpPort.takeIf { !isWifiRequired() } ?: <mDNS discovery>`, and
  `isWifiRequired() == getAdbTcpPort() <= 0 || !getTcpMode()`.
- So **any** positive value in that property makes Shizuku connect *directly to
  it and skip mDNS discovery entirely*. On Android 11+ the wireless-debug port
  is dynamic, but `persist.adb.tcp.port` holds a **stale** port from a previous
  session → connect to a dead port → start fails. (Reporter Tech-Tac's
  workaround — toggle USB+Wi-Fi debugging once per boot — just clears the
  property so discovery runs.)

Harness sketch (no stress, no driver app needed):
```bash
# BASELINE expect=reproduce / FIXED expect=clean
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done'

# 1. Seed the faulty state a reboot would leave behind.
adb root                                   # emulator allows it; needed for setprop
adb shell setprop persist.adb.tcp.port 43210   # a bogus/dead port
# (enable Shizuku TCP mode in settings so isWifiRequired() is false)

# 2. Reboot so the property is what the start path sees at boot.
adb reboot; adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done'

# 3. Trigger autostart / manual start, capture the connect attempt.
adb shell am broadcast -a <shizuku boot/start intent>
adb logcat -d > logcat.txt

# 4. Assert:
#    baseline: connects to 43210, fails  -> reproduced (PASS if expect=reproduce)
#    fixed:    validates/falls back to mDNS, succeeds (or degrades cleanly)
```
You never need a working wireless handshake to *trigger* #188 — you need the
port-read path to run against a bad value. That's what makes it a clean Shape-B
target.

### #221 — "auto-disable USB debugging doesn't work on shutdown"
Same shape, trigger is **shutdown** not boot: enable the setting, `adb reboot`
(fires the shutdown sequence), and check whether the `ACTION_SHUTDOWN` receiver
flipped `Settings.Global` before the time-boxed shutdown broadcast ended. The
one wrinkle is that shutdown broadcasts are best-effort/time-limited — the repro
is essentially "does the receiver fire and finish in time."

---

## Interpreting results — don't trust a red blindly

A failing job is a *hypothesis*, not a verdict. On #201 the
`providernull-fixed-medium` job went red on the first run — but the artifact
showed `exited=0` (the fix held) and the failure was the **driver's own 5000 ms
health-probe timing out under load**, i.e. a harness artifact, not the bug.
`rerun_failed_jobs` came back green and confirmed it.

Checklist when a job is red:
1. Read `logcat.txt` and the results log from the artifact — did the *trigger*
   fire (`forcing provider null` / seeded property present)?
2. Did the code-under-test actually fail, or did the *harness* time out?
3. Is it flaky across profiles (real) or a one-off on the starved profile
   (suspect the harness)? Re-run failed jobs before believing it.

And the inverse: a green **fixed** job is only trustworthy because the script
*asserts the trigger fired* and *enough work happened*. Never let "it passed"
mean "the trigger silently no-op'd."

---

## Branch hygiene — keep instrumentation OUT of the fix PR

The force-hooks (`SHIZUKU_REPRO_FORCE_NULL`, spawn delays, `[repro]` logs), the
`emulator-201-*.yml` workflows, and the harness scripts **must never merge into
an upstream PR.** They live only on `claude/code-session-review-vp9clq*`
branches. The fix PR contains *only* the actual fix (e.g. #239's bounded retry
in `ServiceStarter.java`), byte-clean of any repro scaffolding. We verified this
for #201 by diffing the release APK's sources against stock and confirming zero
instrumentation shipped.

If you're reproducing a *new* bug while an unrelated release is in a tester's
hands (as with cjy0812 on `fix-201-latest`): do the new work on a **separate
branch, PR-only, with no release and no tag**, so the tester's world stays
frozen on exactly what they were given.

---

## Checklist for the next bug

- [ ] Step 0: AOSP-deterministic, or OEM/hardware? (skip if OEM)
- [ ] Pick the shape: race/stress (A) or boot-state (B)
- [ ] Confirm the mechanism in **source**, not just the thread (find the exact
      property / setting / code path)
- [ ] Add the force-hook behind an env/property gate, with `[repro]` logs that
      prove it fired
- [ ] Build a `baseline` sibling branch (stock code) alongside `fixed`
- [ ] Workflow: full-depth + recursive checkout, KVM, `google_apis` API 30+,
      `fail-fast: false`, profile matrix, `if: always()` artifacts
- [ ] Harness script *asserts* per-variant expectation via exit code, with
      guards against false greens (trigger-fired + enough work)
- [ ] **Re-sync the `fixed` variant to the current fix before running** (new
      commits / converged or rebased branch / submodule bump); leave `baseline`
      frozen — "fixed passed" must mean *this* fix passed
- [ ] Run A/B: baseline must reproduce, fixed must be clean, across profiles
- [ ] On red: read the artifact, separate harness artifact from real failure,
      re-run before believing
- [ ] Keep all of it off the fix PR
