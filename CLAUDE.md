# chill

Fan control for the Mac, with Apple in charge by default. Named for what you
want from the machine, not for the mechanism. macOS 26, Apple Silicon only.
TODO.md is the build order, strategy/CLAUDE.md the why. This file is the
architecture chill is built to; nothing below is optional.

Prior art, credited in README: SoloFan's Swift app (MIT,
github.com/SoloTeamDev/solofan, six PRs by Adrian: M4/M5 control, real die
temperatures, off-main-thread writes). SoloFan's `smc-helper` is GPL-derived
(smcFanControl) and is NOT a source: chilld's writer is written from the
IOKit AppleSMC user-client protocol and the key names. The `Ftst` unlock is
credited to agoodkind/macos-smc-fan (MIT). The per-generation SMC keys
that name the chip's parts (`MachSensors.Parts`, in mach's package) are
vendored from exelban/stats (MIT), credited in README. Sibling: mach
measures the machine, chill governs it; both read sensors through the
same package.

## The one idea

A fan runs a CURVE: temperature in, rpm out. That is the whole model.

- `system` is Apple's curve. chill cannot read it, so it OBSERVES it: while a
  fan's holder reads `apple` (mode 0 or 3 with `Ftst` clear: neither a
  foreign writer nor chill's own acquire muting the servo), every sample
  (temperature, rpm) lands in a per-fan histogram (`State.clouds`, the
  app persists it). Recorded, NOT drawn: as cells it read as anything but
  a curve, and it only takes a curve's shape after hours across many
  temperatures. If it returns to the plot it is as one dotted line, the
  median rpm per degree where data exists (root TODO).
- `chill` is the built-in curve, the one most people run: the fan's
  minimum until it kicks in, then one clean S to its maximum, two knobs
  (`kickIn`, `slope` in config.json), on disk as `chill.json` like any
  curve.
- A named curve is yours: (°C, rpm) points, one curve for every fan, each
  fan clamped to its own reported envelope. Interpolation is monotone
  cubic Hermite (`Curve.rpm(at:)`: tangents from the mean of the two
  secants, Fritsch and Carlson's limit, flat at the ends), one function
  for the daemon's writes and the plot's line. Editing happens ON the plot
  with the hottest die and the resulting target marked live.
- Manual is not a mode: a constant rpm is a flat curve. `gust` (the wire's
  `boost`) is a curve pinned at max for N minutes that ends by itself.

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
Wire). SIGKILL and panics run no code: `KeepAlive { Crashed }` restarts
the daemon after a signal death, `ThrottleInterval` 1 so a crash loop
still writes auto every second, and the restart's first act is auto. A
deliberate `exit` (a start refusal, the upgrade step-aside) is not a
crash: the daemon stays loaded and the next client message launches it
on demand through the mach service, so a Mac that can never run chilld
idles instead of looping. A fan that refuses auto at start is not a
refusal: it is logged and reads `foreign` until `chill system` reclaims
it. A forced target and a set `Ftst` MAY outlive their writer (they do on
M5; M4 reports reclaim within seconds), so reconciliation is the
foundation, not a feature.

### Honest status

`chill status` prints who holds the fans and why, in one line, always:

```
system · Apple's curve · die 51°C (hottest of 14) · 2318 · 2318 rpm
quiet · curve "quiet" · 51°C → 2600 rpm · watching: chill.app · 2603 · 2598 rpm
quiet · vetoed: lid closed · Apple holds the fans
quiet · no one watching → Apple holds the fans
boost · max rpm for 2m40s more · 7817 · 7811 rpm
foreign · forced by someone else · `chill system` reclaims
daemon: not installed | awaiting approval | unreachable | this Mac has no fans
```

The status that lies by omission is the bug this product exists to kill.
The head is the holder whenever it is someone else: a persisted curve
with no watcher, or under a veto, still reads `foreign` while another
writer forces the fans. The rpm on any holder line is the read-back,
never the cached envelope. Every XPC invalidation re-reads
`SMAppService.status` before reporting.

## Three processes

1. **chilld**, a root LaunchDaemon and the ONLY SMC writer. A separate
   executable at `Contents/MacOS/chilld` linking Foundation, IOKit, ChillKit
   and the sensor package; never AppKit, never swift-utils. Owns the loop:
   samples at 1 Hz, evaluates intent × presence × vetoes, writes targets,
   records the reference cloud for fans Apple holds. Keeps one IOKit
   connection open for the life of a curve session.
2. **chill.app**, menu bar and canvas (swift-utils Ink + Keymap, fully
   keyboard navigable, `?` shows bindings, an `ActionID` registry as lore's).
   Edits curves, sends intent and presence, renders the daemon's state
   (`Model`, one brain every surface reads; `Pulse` sends presence at 1 Hz
   while the session is on the console, `CGSessionCopyCurrentDictionary`,
   and the screens are awake, `NSWorkspace.screensDid{Sleep,Wake}`, and a
   plain `state()` otherwise, so the glyph never goes stale and no one is
   claimed to be watching). It reads sensors and the SMC through the
   read-only package only while no daemon answers; it never WRITES the
   SMC. Registered as a login item
   (`SMAppService.mainApp`) by `chill daemon install`, so presence returns
   at login and the persisted intent resumes.
3. **`chill` CLI**: the same binary as the app, argv-dispatched (no
   arguments = the app; that is what Finder and the login item launch, so a
   double click is never a silent death). Symlinked into `~/.local/bin` by
   install. Verbs: `status [--json]`, `curve list|show|use <name> [--watch]
   [--take]`, `boost [minutes] [--watch] [--take]`, `system`, `daemon
   install|uninstall|status`, `log [-f]`. `use` and `boost` set the intent
   and never claim presence themselves: a fan is forced only while someone
   watches, and whoever watches carries the intent. Without `--watch` they
   need another live watcher (chill.app) and exit 2 otherwise (`no one
   watching: run with --watch or open chill.app`); with `--watch` the CLI
   claims presence FIRST, which the daemon refuses `heldBy` while another
   watcher is live unless `--take` (only meaningful with `--watch`). The
   app's own `use` while a `--watch` CLI holds presence lands the same
   way: intent set, the CLI carries it, the app's pulse reads `heldBy`
   until `t` takes over. `status` exits 1 when it prints a `daemon:` line
   (the fans' state is unknown, a fanless Mac included). A bare
   build (ad-hoc signed) cannot derive a peer requirement and says so
   instead of connecting; only the installed bundle talks to chilld.

### Wire

Mach service `garden.untitled.chilld`. `launchd/garden.untitled.chilld.plist`
is copied verbatim by `assemble.sh` to `Contents/Library/LaunchDaemons/`:
Label `garden.untitled.chilld`, `BundleProgram Contents/MacOS/chilld`,
`MachServices { garden.untitled.chilld: true }`, `RunAtLoad true`,
`KeepAlive { Crashed: true }`, `ThrottleInterval 1`,
`StandardOutPath`/`StandardErrorPath`
`/Library/Logs/chill/chilld.log` (launchd creates no parent directory, so
chilld's first act makes `/Library/Logs/chill` and points its own fds 1
and 2 at the file, appending; `Log.open`). No `AssociatedBundleIdentifiers`
(in-bundle plists self-associate). The app registers with
`SMAppService.daemon(plistName: "garden.untitled.chilld.plist")`; the daemon
listens on `NSXPCListener(machServiceName:)`; clients connect with
`NSXPCConnection(machServiceName:options: .privileged)` and both sides call
`setCodeSigningRequirement` (macOS 13+, before `resume()`) with the
requirement derived from the daemon's OWN code (`SecCodeCopySelf` →
`SecCodeCopyDesignatedRequirement` → `SecRequirementCopyString`): one
signed bundle, one Team ID, no hardcoded string.

`ChillKit` (a library target shared by all three) holds the protocol and the
payloads (`Codable`, crossing XPC as JSON `Data`), plus everything a client
needs and the daemon does not: `Client` (one async core behind the XPC proxy
or the demo's `FakeDaemon`; sync helpers for the CLI, async for the app;
`hello` once per connection, retried through an upgrade relaunch; a 10 s
reply watchdog that fails the pending call and leaves the connection up,
so a retry reaches a daemon that is merely slow; every transport failure
classified against `SMAppService.status` before it is reported), `Demo`
(the roots `state`,
`curves`, `config`, `cloud` and the demo's seeds: curves, a scripted cloud,
the first last-curve), `CurveStore`, `FakeDaemon`, `Reason` (the status
vocabulary both daemons ship as `lastReason`), `Wire.version` (the
bundle's stamp, both ends) and `Wire.logFile`:

- `hello(clientVersion, role) -> Hello { daemonVersion, protocol, pid,
  fans: [Fan { index, min, max }], hasLid }`. `role` is what the client IS
  (`Role`: `chill.app`, `chill`, `chill --watch`; the app and the CLI are
  one executable, so the process name cannot tell them apart), kept per
  connection by the daemon and worn as the watcher's name in status and
  `heldBy`. Version mismatch: the daemon re-reads the bundle's Info.plist
  from disk (a plist it cannot read is a broken install: logged, the
  client refused, no step-aside); when THAT differs from its own image it
  logs `upgrade: old → new`, refuses `upgrading(from, to)` and exits 0;
  the client's retry launches the new image on demand and its first act
  is auto. When the disk still carries the daemon's version the client is
  the stale one and is refused `stale(client, daemon)` (`relaunch
  chill.app`) without an exit, so an old process left running cannot
  bounce the daemon at its pulse rate. `Client.hello` retries only
  `upgrading`, within `relaunchWindow`; every other refusal is the answer
  at once, and the app shows it as `Link.stale` with quit-and-relaunch as
  the fixing action.
- `use(curve: Curve) -> State` · `boost(minutes) -> State` · `system() ->
  State` · `presence() -> State` · `state() -> State` · `take() -> State`.
- `State { intent, holder: apple | chill(curve) | acquiring | foreign,
  vetoes: [Veto], presence: Presence?, fans: [FanState { actual, target,
  mode }], die: Double?, dieSensors: Int, lastReason, clouds: [Cloud {
  fan, bins: [[c, rpm, count]] }], protocolVersion }`. `State` IS the
  `status --json` document. `dieSensors` counts the die readings `die` is
  the max of, so status can say `(hottest of 14)`. `clouds` is the
  reference cloud as the daemon accumulates it in memory (fans Apple
  holds only); the app is the one that persists it.

ONE presence holder at a time, keyed by the CONNECTION (a `Session` per
accepted connection, its token minted at accept, owning the role `hello`
declared); the pid (`NSXPCConnection.processIdentifier`) names it in
status and `heldBy` and tells two of chill's own clients apart, the
listener's code-signing requirement is the gate. One process can hold two
connections for a moment (the app rebuilds its client after a watchdog
timeout while the old one drains), so a dead connection drops only the
presence it claimed itself, never the newer one's. A connection's verbs
reach the engine in wire order, chained per session (`state` apart), and
the app chains its own verbs the same way, so a held arrow key's burst of
`use` lands last-edit-last on both ends. Only `presence` and `take` claim
presence; a second client's `presence` is refused with `heldBy(pid,
name)` unless it calls `take` (`--take` on the CLI). Fast user switching
is out of scope.

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
- **target**: clamp to the cached envelope, hysteresis 50 rpm, then the
  curve's value whole: the ramp from wherever the fan was is the
  firmware's, and a softened target lingers (a gust's ceiling outlived
  the tab that ended it). The
  read-back judges the write: the firmware answers some `F{n}Tg` writes
  with a result byte (0x87 seen) and applies the value anyway, which is
  logged and fine; a read-back that disagrees is `targetRejected`, the
  fan stays chill's (mode 1 read back) and status says `smc: fan N target
  refused 0x87`. Only a failed READ makes a fan `unreadable`.

## Sensors: one reader, two consumers

Die temperatures come from IOHIDEventSystemClient (the only source that is
right on Apple Silicon); fan telemetry from SMC reads. Both live in mach's
repo as the `MachSensors` library product (macOS 13 floor, beside
MachCore): per-sensor readings `[Sensor(name, celsius)]` with invalid ones
filtered, `hottest`, and an SMC reader with `info(key) -> (type, size)`
(cmd 9), typed reads (`flt `, `ui8`, `ui16`), `fans()` enumerated from
`FNum` returning actual/target/mode (the live telemetry), `envelope(fan:)`
for Mn/Mx apart (read ONCE by every consumer: chilld's writer at start,
the app's `LocalSensors` when it opens; `Mx` reads intermittently), a
public 80-byte codec, and typed errors from the result byte. No write function exists in the package:
read-only by construction; chilld composes its cmd 6 write on the codec.
chill consumes it as `.package(path: "../mach")` against the pinned
submodule pointer; on ship day it becomes the public `swift-hw` package
(MIT) and chill's dependency flips to a versioned URL.

The temperature that drives a curve is the HOTTEST cpu or gpu sensor from
the SMC's named keys (`MachSensors.Parts`, `State.dieSource` says which),
and only where the catalogue knows no keys for the chip (M1/M2, or newer
than the catalogue) the hottest HID die. Never a mean: a chip spreads
several degrees under load. Why not the HID path from M3 on: its sensors
are `PMU tdie<n>`, the power management unit's dies (stats names them
"Power management unit die"), which warm when charging and read several
degrees UNDER the cores at idle (M5 Max: PMU 43 °C, cpu 51 °C); M1/M2
name the SoC's blocks (`*ACC MTR`, `GPU MTR`) and there the HID die is
right.

`Parts` is exelban/stats' catalogue (MIT), vendored in the package for
M3, M4, M5 (cpu, gpu, memory on M4), probed once with READ_KEYINFO by
every consumer (chilld over a second, read-only SMC handle; the app's
`LocalSensors`); the probe logs how many keys answered (an M5 Max: 18 of
18 cpu, 7 of 8 gpu). The temperature badge reads it on demand: hottest
sensor per group and how many; `ssd` and `battery` come from the HID path
by name, deduped (the HID path lists every sensor several times).

## State

| path | owner | what |
|---|---|---|
| `~/.local/state/chill/curves/<name>.json` | app | `{ name, points: [{ c, rpm }] }`, one curve for all fans |
| `~/.local/state/chill/config.json` | app | `{ lastCurve }`: the right-click toggle's target and the canvas's first cursor, written on every `use`; absent = first run (the demo starts on `quiet`) |
| `~/.local/state/chill/cloud/<fan>.json` | app | `{ fan, bins: [[c, rpm, count]], seen: { pid, bins }, lastHalved }`: a 2-D histogram, 1 °C × 50 rpm bins, capped at 5k bins (thinnest dropped), counts halved monthly; written on quit and every 5 min, never raw samples. The daemon accumulates its cloud in memory since ITS start and never writes into a home directory; the app folds each `State.clouds` shipment in as the delta since the last one from the same daemon pid (`seen`), so a daemon restart starts a fresh delta and a relaunched app never counts a sample twice. Nothing absorbed = no file, no directory |
| `/Library/Application Support/chill/policy.json` | daemon | `{ intent, curve, boostUntil }`, the thing that survives reboot |
| `/Library/Logs/chill/chilld.log` | daemon | every transition with reason and before/after targets; `os_log` too, numbers and reasons `.public` (nothing personal exists here) |

Hysteresis is a constant in code, not a per-curve field.

## Surfaces, house rules

- **The popover IS the product** (`MenuBar.swift`, an NSPopover sized by
  SwiftUI's ideal): a tab rail on top whose tabs ARE the intents, `apple ·
  chill · <each custom curve> · gust · +`; pressing one sends it, the dune
  plate slides to whichever the daemon reads back as running, never to the
  press. `?` apart on the right. Under it the plot, and a foot of ONE
  height on every tab (the knobs' height) so the popover never resizes:
  `chill` shows the two house sliders (`Knob`: hairline, dune run, mono
  reading), a custom curve shows the trash button, `apple` and `gust`
  nothing. No status line and no prose: what a tab means is its tooltip.
- **The plot** (`Plot.swift`): a heatmap at rest (ice to ember to red
  across the temperature axis, 7%), lit to 25% up to the die; the curve
  in dune, sampled every half degree from `Curve.rpm(at:)`; the die as a
  vertical hairline in its heat's color (`Palette.heat`: ice ≤45 °C,
  ember at 75, red at 100), each fan (or the pair while within 225 rpm)
  as a horizontal dune rule, chill's target as a dashed rule, the live
  point where die and rule cross as a halo in the heat with a heat core,
  and the afterglow: the path the point travelled, recorded by the
  animated layer on every frame it draws, a blurred stroke fading in
  25 s. Two animatable layers: `CurveLayer` (the line as sampled rpm, one
  length for every curve, so any curve morphs into any other) and
  `LiveLayer` (die, fans, targets, one fixed-length vector so a change of
  intent glides like any sample). The labels are `Badge`s, one SwiftUI
  view each pinned by a corner: at rest the one line, under the pointer
  (on their line or plate) the same view grows into its details, the
  die's into cpu/gpu/memory/ssd/battery, the fans' into actual, target,
  mode and holder. Editing, on a custom tab only: near the line a hollow
  ghost point follows the pointer ON the curve; pressing it bears the
  point, the same motion drags it, release lands it; a point under the
  pointer grows and rings (cursor: hand); right-click removes it (an
  NSEvent local monitor, since SwiftUI sees no secondary button, reading
  the hover's last plot-space position). Nothing lands from a press on
  empty plot. A point within reach always wins over the hover cards. The
  keyboard's selection has no look of its own. Three hues, alpha the only
  other variable: dune `#cfc5b4` (tempo's minutes) for what chill does,
  heat for the die, a neutral for Apple. Every edit LANDS: validated by
  `Curve`, written to its file, re-sent with `use` when it is the curve
  the daemon runs; no save step, no draft. Without a daemon the plot
  still shows the machine through `LocalSensors`; with one, `State` is
  the only source. Nothing animates indefinitely.
- **Canvas window** (`CanvasWindow`, `c`): the same plot larger beside
  the curve list (Ink.CursorScrollView) and an action bar; the keyboard
  surface. Every key is a `ChillAction` (`Actions.swift`): arrows move
  the selected point (1 °C / 50 rpm), ⇥ / ⇧⇥ cycle points, `n` adds one
  after, ⌫ removes it, `[` / `]` walk the curve list, ↩ uses the cursor's
  curve, ⌘N draws a new one, ⌘⌫ trashes one (Apple's curve first when it
  is the running one), ⌘1-9 pick by list order, `b` gust, `s` system, `t`
  take over, `?` the cheat sheet, ⎋ closes.
- **Menu bar glyph**: EFFECT, read from the daemon, never intent: outline
  = Apple holds the fans · filled = a curve does · bar = gust · slashed
  outline = no daemon (not installed, awaiting approval, unreachable) ·
  dotted = foreign. Left-click opens the popover, right-click toggles
  apple ↔ chill (MenuBarExtra has no right-click). With no daemon the
  popover leads with the one action that fixes it (`Fixer`): "install
  chilld" (`register()`) or "approve chilld in System Settings › General
  › Login Items & Extensions" (`openSystemSettingsLoginItems()`), polling
  `SMAppService.status` until `.enabled`. Approval is admin-only; a
  standard user (not in the `admin` group, `getgrouplist`) is told so.
  The poll IS the pulse: every failed exchange classifies against the
  live registration at 1 Hz. The tabs are disabled while the link is not
  live. The glyph (`Mark.swift`) is `Glyph(Link)` re-rendered through
  observation tracking, never on a timer.
- **Instrumentation**: `Log.swift`, os.Logger `garden.untitled.chill`:
  every tab and right-click press with what the daemon ran and whether
  the link was live, every verb with queue wait, duration and outcome,
  link drops, tabs disabled/enabled, presence flips, skipped pulses,
  popover open/close, the parts probe, right-click verdicts. `log stream
  --predicate 'subsystem == "garden.untitled.chill"'` beside the daemon's.
  A click that went nowhere is either missing there or answered there.
- **`--demo` / `mise demo`**: every content-bearing root forks to a `-demo`
  sibling (`~/.local/state/chill-demo`: curves, config, cloud, seeded with a
  scripted cloud), sensors are a scripted temperature trace, the daemon is
  `FakeDaemon` (ChillKit), an in-process conformer of the same protocol
  the XPC proxy implements, never chilld: two fans with a real envelope,
  a three-minute die breath, Apple's curve when it holds the fans, the
  presence rule, no vetoes, and a reference cloud it records from its own
  samples exactly as chilld does (the seeded cloud is the demo ROOT's,
  written by the app on first launch). The CLI takes the same flag and
  marks its headers `· demo`; the window wears a lowercase mono `demo`
  kicker and opens at launch, since the demo exists to be seen.
- **Mark**: `scripts/icon.svg`, rendered by `mise icon` (rsvg-convert →
  icns + icon.png); the menu glyph is a template render of the same paths.
- **Verbs**: `mise.toml`: `build · dev · demo · check · format · lint
  (advisory) · icon · install · uninstall · clean · notes · release ·
  publish · cask`, awake's `assemble.sh`,
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

## Gotchas

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
