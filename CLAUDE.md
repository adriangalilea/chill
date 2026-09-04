# chill

Fan control for the Mac, with Apple in charge by default. Named for what you
want from the machine, not for the mechanism. macOS 26, Apple Silicon only.
Not built yet: TODO.md is the build order, strategy/CLAUDE.md the why. This
file is the architecture chill is built to; nothing below is optional once
code exists.

Prior art, credited in README and About: SoloFan's Swift app (MIT,
github.com/SoloTeamDev/solofan, six PRs by Adrian: M4/M5 control, real die
temperatures, off-main-thread writes). SoloFan's `smc-helper` is GPL-derived
(smcFanControl) and is NOT a source: chilld's writer is written from the
IOKit AppleSMC user-client protocol and the key names. The `Ftst` unlock is
credited to agoodkind/macos-smc-fan (MIT). Sibling: mach measures the
machine, chill governs it; both read sensors through the same package.

## The one idea

A fan runs a CURVE: temperature in, rpm out. That is the whole model.

- `system` is Apple's curve. chill cannot read it, so it OBSERVES it: while a
  fan's mode reads 0 or 3 (Apple holds it), every sample (temperature, rpm)
  lands in a per-fan histogram that draws Apple's real behaviour on the
  canvas as a cloud. Read-only, default, always drawn as the reference.
- A named curve is yours: (°C, rpm) points, linear interpolation, one curve
  for every fan, each fan clamped to its own reported envelope. Editing
  happens ON the canvas, over the reference cloud, with the hottest die and
  the resulting target marked live.
- Manual is not a mode: a constant rpm is a flat curve. `boost` is a curve
  pinned at max for N minutes that ends by itself.

Who holds a fan is READ BACK, never inferred from the last write: mode 0 or
3 = Apple · mode 1 with chill's intent = chill · mode 1 (or `Ftst` = 1)
without chill's intent = `foreign`. There is no "automatic" that means
"chill's curve".

## The contract: intent, presence, vetoes

chill forces a fan iff all three hold, evaluated by the daemon every second:

1. **intent** ≠ system: the active curve or a boost. Persisted by the daemon
   in `/Library/Application Support/chill/policy.json`, so it survives
   reboot and login.
2. **presence** is live: some client spoke within the last 10 s. The app
   sends presence at 1 Hz while its session is on the console and the
   screens are awake; a CLI verb that needs presence holds it itself with
   `--watch` (Ctrl-C hands back) or refuses with exit 2 when no one is
   watching. Presence deadlines are `ContinuousClock` instants, which keep
   counting through sleep.
3. **no veto**: the daemon's own nets, a latched set. While any is set,
   presence is acknowledged but not applied, status names the veto, and
   lifting one never re-forces on its own; only the next evaluation does.
   - `lid`: `kIOPMMessageClamshellStateChange` (general-interest
     notification on IOPMrootDomain, bit 0 = closed); initial value from
     `AppleClamshellState`, re-read on `kIOMessageSystemHasPoweredOn`; key
     absent = no lid on this Mac, logged once. A closed lid with an external
     display keeps the Mac running for hours; chill has no airflow model for
     it, so Apple holds the fans until it opens.
   - `sleep`: `IORegisterForSystemPower` on the daemon's queue.
     `kIOMessageCanSystemSleep` acked at once; `kIOMessageSystemWillSleep`
     → auto, veto set, THEN `IOAllowPowerChange` (a missing ack delays
     every sleep 30 s). The veto lifts on the first client message after
     `kIOMessageSystemHasPoweredOn`, never on the wake itself: a dark wake
     has no client, so it gets Apple's curve. Exposure after any wake is
     bounded by presence, 10 s.
   - `thermal`: `ProcessInfo.thermalState` read once, then
     `thermalStateDidChangeNotification`; `.serious` or `.critical` sets it,
     30 s at `.fair` or below clears it (hysteresis, or it oscillates).
     `OSThermalNotificationLevel` is iOS-only; nobody reaches for it.
   - `noReading`: three consecutive samples without a die temperature.

Any other state is Apple's: daemon start (reconciliation, first act), SIGTERM
(a `DispatchSource` signal handler → auto → exit), normal exit, `chill daemon
uninstall` (auto over XPC, read back, then unregister), an upgrade (see
Wire). SIGKILL and panics run no code: `KeepAlive` restarts the daemon,
`ThrottleInterval` 1 so a crash loop still writes auto every second, and
the restart's first act is auto. A forced target and a set `Ftst` MAY
outlive their writer (they do on M5; M4 reports reclaim within seconds), so
reconciliation is the foundation, not a feature.

### Honest status

`chill status` prints who holds the fans and why, in one line, always:

```
system · Apple's curve · die 51°C (hottest of 14) · 2318 · 2318 rpm
quiet · curve "quiet" · 51°C → 2600 rpm · watching: chill.app · 2603 · 2598 rpm
quiet · vetoed: lid closed · Apple holds the fans
quiet · no one watching → Apple holds the fans
boost · 7817 rpm for 2m40s more
foreign · forced by someone else · `chill system` reclaims
daemon: not installed | awaiting approval | unreachable | this Mac has no fans
```

The status that lies by omission is the bug this product exists to kill.
Every XPC invalidation re-reads `SMAppService.status` before reporting.

## Three processes

1. **chilld**, a root LaunchDaemon and the ONLY SMC writer. A separate
   executable at `Contents/MacOS/chilld` linking Foundation, IOKit, ChillKit
   and the sensor package; never AppKit, never swift-utils. Owns the loop:
   samples at 1 Hz, evaluates intent × presence × vetoes, writes targets,
   records the reference cloud for fans Apple holds. Keeps one IOKit
   connection open for the life of a curve session.
2. **chill.app**, menu bar and canvas (swift-utils Ink + Keymap, fully
   keyboard navigable, `?` shows bindings, an `ActionID` registry as lore's).
   Edits curves, sends intent and presence, renders the daemon's state. It
   reads sensors and the SMC through the read-only package for the canvas;
   it never WRITES the SMC. Registered as a login item
   (`SMAppService.mainApp`) by `chill daemon install`, so presence returns
   at login and the persisted intent resumes.
3. **`chill` CLI**: the same binary as the app, argv-dispatched (no
   arguments = the app; that is what Finder and the login item launch, so a
   double click is never a silent death). Symlinked into `~/.local/bin` by
   install. Verbs: `status [--json]`, `curve list|show|use <name> [--watch]`,
   `boost [minutes] [--watch]`, `system`, `daemon install|uninstall|status`,
   `log [-f]`. `use` and `boost` need presence; the rest do not.

### Wire

Mach service `garden.untitled.chilld`. `launchd/garden.untitled.chilld.plist`
is copied verbatim by `assemble.sh` to `Contents/Library/LaunchDaemons/`:
Label `garden.untitled.chilld`, `BundleProgram Contents/MacOS/chilld`,
`MachServices { garden.untitled.chilld: true }`, `KeepAlive true`,
`ThrottleInterval 1`, `StandardOutPath`/`StandardErrorPath`
`/Library/Logs/chill/chilld.log`. No `AssociatedBundleIdentifiers`
(in-bundle plists self-associate). The app registers with
`SMAppService.daemon(plistName: "garden.untitled.chilld.plist")`; the daemon
listens on `NSXPCListener(machServiceName:)`; clients connect with
`NSXPCConnection(machServiceName:options: .privileged)` and both sides call
`setCodeSigningRequirement` (macOS 13+, before `resume()`) with the
requirement derived from the daemon's OWN code (`SecCodeCopySelf` →
`SecCodeCopyDesignatedRequirement` → `SecRequirementCopyString`): one
signed bundle, one Team ID, no hardcoded string.

`ChillKit` (a library target shared by all three) holds the protocol and the
payloads, `Codable` + `NSSecureCoding`:

- `hello(clientVersion) -> Hello { daemonVersion, protocol, fans: [Fan {
  index, min, max }], hasLid }`. Version mismatch: the daemon logs
  `upgrade: old → new` and exits 0; KeepAlive relaunches the new image and
  its first act is auto.
- `use(curve: Curve) -> State` · `boost(minutes) -> State` · `system() ->
  State` · `presence() -> State` · `state() -> State` · `take() -> State`.
- `State { intent, holder: apple | chill(curve) | acquiring | foreign,
  vetoes: [Veto], presence: Presence?, fans: [FanState { actual, target,
  mode }], die: Double?, lastReason, clouds: [Cloud { fan, bins: [[c,
  rpm, count]] }], protocolVersion }`. `State` IS the `status --json`
  document. `clouds` is the reference cloud as the daemon accumulates it
  in memory (fans Apple holds only); the app is the one that persists it.

ONE presence holder at a time, keyed by the client's audit-token pid; a
second client's `use`/`boost` is refused with `heldBy(pid, name)` unless it
calls `take`. Fast user switching is out of scope.

### The SMC writer

Keys per fan `n`: `F{n}Ac` actual · `F{n}Tg` target · `F{n}Mn`/`F{n}Mx` the
reported envelope (thermalmonitord's thresholds, not motor limits; read ONCE
at daemon start, asserted positive and Mn < Mx, cached, shipped in `hello`,
never re-read live because `Mx` reads intermittently) · mode key `F{n}Md`,
lower-case `F{n}md` on M5, probed once with READ_KEYINFO. `FNum` counts
fans; zero fans = `hello` returns none, install refuses with "this Mac has
no fans". Types: rpm keys `flt ` (4-byte LE float), FNum/mode/`Ftst` `ui8`;
chilld asserts the type from READ_KEYINFO before every write and refuses an
Intel `fpe2` machine with a clear message.

Mode values: 0 auto · 1 forced · 3 system, Apple's `thermalmonitord`, the
default. Every write checks the 80-byte reply's `result` byte: 0x82 =
firmware rejected, 0x84 = no such key; `KERN_SUCCESS` alone means nothing.

- **acquire**: write mode 1, read back, require 1. If it did not stick and
  `Ftst` exists (absent on M5): write `Ftst = 1`, retry mode 1 every 100 ms
  for up to 10 s. Runs on its own task, never blocking the evaluator; the
  fan reads `acquiring` in status meanwhile (5 to 6 s on M4). `Ftst` stays
  1 for the life of the session so target changes are 20 ms writes.
  Firmware resets `Ftst` across sleep, and right after wake thermalmonitord
  transiently holds mode 3, so every evaluation whose read-back is not 1
  re-runs acquire.
- **auto**: per fan write mode 0; if `Ftst` exists and reads 1, write
  `Ftst = 0`; poll the mode until it reads 0 or 3; log the transition. A
  forgotten `Ftst = 1` mutes Apple's thermal servo, which is why
  reconciliation and every exit path run this exact routine.
- **target**: clamp to the cached envelope, hysteresis 50 rpm, slew at most
  N rpm per sample toward the curve value (N from the observed `F{n}Ac`
  slew on the reference cloud); the physical ramp is the firmware's.

## Sensors: one reader, two consumers

Die temperatures come from IOHIDEventSystemClient (the only source that is
right on Apple Silicon); fan telemetry from SMC reads. Both live in mach's
repo as the `MachSensors` library product (macOS 13 floor, beside
MachCore): per-sensor readings `[Sensor(name, celsius)]` with invalid ones
filtered, `hottest`, and an SMC reader with `info(key) -> (type, size)`
(cmd 9), typed reads (`flt `, `ui8`, `ui16`), `fans()` enumerated from
`FNum` returning actual/target/min/max/mode, a public 80-byte codec, and
typed errors from the result byte. No write function exists in the package:
read-only by construction; chilld composes its cmd 6 write on the codec.
chill consumes it as `.package(path: "../mach")` against the pinned
submodule pointer; on ship day it becomes the public `swift-hw` package
(MIT) and chill's dependency flips to a versioned URL.

The temperature that drives a curve is the HOTTEST die sensor (`PMU tdie*`
on M3 and later, `*ACC MTR` + `GPU MTR` on M1/M2). Never a mean: a 14-die
chip spreads several degrees under load. Status shows a cpu/gpu split only
where sensors name it.

## State

| path | owner | what |
|---|---|---|
| `~/.local/state/chill/curves/<name>.json` | app | `{ name, points: [{ c, rpm }] }`, one curve for all fans |
| `~/.local/state/chill/config.json` | app | `{ lastCurve, updatesEnabled }` |
| `~/.local/state/chill/cloud/<fan>.json` | app | 2-D histogram, 1 °C × 50 rpm bins, count per bin, capped at 5k bins, counts halved monthly; written on quit and every 5 min from `State.clouds`, never raw samples. The daemon accumulates it in memory and never writes into a home directory |
| `/Library/Application Support/chill/policy.json` | daemon | `{ intent, curve, boostUntil }`, the thing that survives reboot |
| `/Library/Logs/chill/chilld.log` | daemon | every transition with reason and before/after targets; `os_log` too, numbers and reasons `.public` (nothing personal exists here) |

Hysteresis and slew are constants in code, not per-curve fields.

## Surfaces, house rules

- **Canvas**: one window, the active curve over the reference clouds (one
  per fan, the second a lighter alpha of the same tone), y-axis from the
  lowest `Mn` to the highest `Mx`, live markers for the hottest die and
  the resulting target. Arrow keys move the selected point, ⇥ cycles, `n`
  adds, ⌫ removes, Ink.CursorScrollView for the curve list. Nothing
  animates indefinitely.
- **Menu bar**: the glyph is EFFECT, read from the daemon, never intent:
  outline = Apple holds the fans · filled = a curve does · bar = boost ·
  slashed outline = no daemon (not installed, awaiting approval,
  unreachable) · dotted = foreign. Right-click toggles system ↔ last curve.
  With no daemon the menu leads with the one action that fixes it:
  "install chilld" (`register()`) or "approve chilld in System Settings ›
  General › Login Items & Extensions" (`openSystemSettingsLoginItems()`),
  polling `SMAppService.status` until `.enabled`. Approval is admin-only; a
  standard user is told so.
- **`--demo` / `mise demo`**: every content-bearing root forks to a `-demo`
  sibling (`~/.local/state/chill-demo`: curves, config, cloud, seeded with a
  scripted cloud), sensors are a scripted temperature trace, the daemon is
  an in-process conformer of the same protocol the XPC proxy implements,
  never chilld. The CLI takes the same flag and marks its headers `· demo`;
  the window wears a lowercase mono `demo` kicker.
- **Mark**: `scripts/icon.svg`, rendered by `mise icon` (rsvg-convert →
  icns + icon.png); the menu glyph is a template render of the same paths.
- **Verbs**: `mise.toml`: `build · dev · demo · check · icon · install ·
  uninstall · notes · release · publish · cask`, awake's `assemble.sh`,
  `locked.sh` and `.github/cliff.toml` as the model. `VERSION` in
  mise.toml is truth; `notes/<version>.md` in the `### Added|Fixed|Changed|
  Performance|Polish` + `- ` grammar the release task checks is the
  release body and the words gate. `apps/chill/package.json` carries the
  two-line `check` for turbo; the root has `pnpm chill` and
  `pnpm chill:install`.
- **Install**: `APP = /Applications/chill.app` (launchd bootstraps the
  daemon at boot, before any home directory exists; the cask lands there
  too, so a dev build never registers a second root daemon). Sequence:
  `chill daemon uninstall` if an old bundle exists → assemble → sign with
  `Developer ID Application` (REQUIRED, no ad-hoc fallback: SMAppService
  refuses an unsigned or ad-hoc bundle with `kSMErrorInvalidSignature`, and
  a bundle carrying a LaunchDaemon must be notarized; whether a
  Developer-ID-signed but un-notarized install registers on macOS 26 is
  milestone 1's first gate, and if not, `install` notarizes with the same
  keychain profile `release` uses) → `chill daemon install` (register, poll
  status, register the login item). Uninstall: `chill daemon uninstall`
  BEFORE the bundle is trashed; a bundle trashed first leaves a `.notFound`
  registration in Login Items. The cask mirrors it: `postflight` install,
  `uninstall_preflight` uninstall, `zap` the state dir, logs and defaults.
- **Release**: awake's pipeline: sign, notarize, staple, dmg, tag, GitHub
  Release, `publish` (dmg → R2 behind `chill.untitled.garden/releases`, the
  counted URL, then `garden notes chill` → release rows), cask in
  `adriangalilea/tap` pointing at that R2 URL. Runs from the public repo's
  mount, never from the vendored dir. CI runs `mise check` + `git diff
  --exit-code` only.

## Gotchas known before the first line

- `F{n}Md` vs `F{n}md`: probe, never hardcode. `Ftst` absent on M5 (0x84).
- A mode write "succeeds" at the IOKit layer and does nothing: read the
  result byte and read the mode back. Post-wake, thermalmonitord holds mode
  3 for a few seconds and acquire loses the race unless it retries.
- Never trust display sleep as "lid closed": on macOS 26 WindowServer's
  display bookkeeping and the real panel diverge
  (`~/self/mac/lid-black-screen.md`). The daemon reads the clamshell state.
- A sleep delayed by 30 s means an unacknowledged `IORegisterForSystemPower`
  message.
- Dark wake cannot be detected with public API (`IOPMConnection`
  capabilities are private): the presence rule covers it.
- Mac App Store is not a channel: SMC writes and a root daemon are
  impossible in the sandbox. Monitoring-only would be allowed and is not
  the product.
