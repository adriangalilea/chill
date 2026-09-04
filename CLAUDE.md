# chill

Fan control for the Mac, with Apple in charge by default. Named for what you
want from the machine, not for the mechanism. Not built yet: TODO.md is the
build order, strategy/CLAUDE.md the why. This file is the architecture chill
is built to, so nothing below is optional once code exists.

Prior art: SoloFan (MIT, github.com/SoloTeamDev/solofan), which Adrian
contributed six PRs to (M4/M5 control, real die temperatures, off-main-thread
writes). chill is a clean rewrite with a different architecture, credited in
README and About; no SoloFan code is carried over. Sibling: mach measures the
machine, chill governs it; both read sensors through the same package.

## The one idea

A fan runs a CURVE: temperature in, rpm out. That is the whole model.

- `system` is Apple's curve. chill cannot read it, so it OBSERVES it: every
  sample while the SMC is in auto is a point (temperature, rpm) that draws
  Apple's real behaviour on the canvas as a cloud. Read-only, default, always
  drawn as the reference.
- A named curve is yours: a list of (°C, rpm) points, interpolated linearly,
  clamped to the fan's hardware min/max. Editing happens ON the canvas, over
  the reference cloud, with the current temperature and the resulting target
  marked live.
- Manual is not a mode. A constant rpm is a flat curve. `boost` is a curve
  pinned at max for N minutes that ends by itself.

There is no "automatic" that means "chill's curve": a curve is either Apple's
or named, and the UI never hides which one holds the fans.

## Three processes, one contract

1. **chilld** (root LaunchDaemon, registered by the app with
   `SMAppService.daemon`, plist shipped in the bundle, one admin approval
   ever). The ONLY writer of the SMC. Owns the IOKit connection, holds the
   fan keys (`F{n}Ac` actual, `F{n}Tg` target, `F{n}Mn`/`F{n}Mx` limits,
   `F{n}Md` mode; the mode key is lower-case `F{n}md` on M5, probed at
   startup). Speaks XPC, and accepts a client only if its code-signing
   requirement matches the app's Team ID. No sudoers, no shell, no helper
   binary a user could swap.
2. **chill.app** (menu bar, swift-utils Ink + Keymap, fully keyboard
   navigable, `?` shows bindings). Samples at 1 Hz through the shared sensor
   package, evaluates the active curve, and RENEWS a lease on the daemon with
   the targets. It never touches the SMC.
3. **`chill` CLI** (symlink into the bundle, like awake): `status [--json]`,
   `curve list|use <name>|show`, `boost [minutes]`, `system`, `daemon
   install|uninstall`, `log`. The CLI and the app are the same XPC client;
   everything the menu can do, a script can do.

### The lease is the safety net

A forced target lives 10 s. The app renews it every second; if renewal
stops for ANY reason (app quit, crash, hang, dark wake where the app does
not run, the Mac asleep), the daemon writes `auto` to every fan and Apple is
back in charge. Nothing else has to be right for that to happen: no
NSWorkspace notification, no quit handler, no cooperation from the app. The
daemon additionally goes to `auto` on its own, before any lease expiry, when:

- the lid closes (IOPMrootDomain clamshell state, watched directly, not via
  display sleep): a closed lid has no airflow model chill can trust;
- the system is about to sleep or enters dark wake (IOKit power
  notifications inside the daemon);
- the kernel raises a thermal pressure level;
- the daemon itself starts (startup reconciliation: the SMC is never left in
  a forced state chill cannot account for) or exits (every exit path).

The daemon runs under launchd `KeepAlive`, so a crash is a restart, and the
restart's first act is `auto`. This is the awake principle applied to fans:
a wish, renewed, never a lock.

### Honest status

`chill status` names who holds the fans and why, in one line, always:

```
system · Apple's curve · cpu 51°C gpu 44°C · 2318 rpm · 2318 rpm
quiet · curve "quiet" · 51°C → 2600 rpm · lease 9s · fans 2603 · 2598
boost · 7817 rpm for 2m40s more
```

If the SMC is forced by something that is not chill (another tool, a stale
helper), status says `foreign: forced by someone else` and offers `chill
system` to reclaim it. The status that lies by omission is the bug this
product exists to kill.

## Sensors: one reader, two consumers

Die temperatures come from IOHIDEventSystemClient (the only source that is
right on Apple Silicon), fan telemetry from SMC reads; both already live in
mach's `MachCore` (`HIDSensors.swift`, `SMC.swift`). chill depends on that
code by path inside the monorepo. When chill goes public those two files
leave MachCore for a public package (`swift-hw`, beside swift-utils) so mach
and chill both consume it and neither carries a copy. SMC WRITES exist only
in chilld; the shared package stays read-only by construction.

The temperature that drives a curve is the max of CPU and GPU die
temperatures. Smoothing is the curve's job (hysteresis of 50 rpm, a 2 s
ramp), never the sensor's.

## Surfaces, house rules

- **Canvas**: one window, the curve over the reference cloud, live markers.
  Arrow keys move the selected point, ⇥ cycles points, `n` adds, ⌫ removes.
  Ink.CursorScrollView for the curve list. Nothing animates indefinitely.
- **Menu bar**: the glyph is EFFECT, not intent (as awake's cup): outline
  when Apple holds the fans, filled when a curve does, a bar when boosting.
  Right-click toggles system ↔ last curve.
- **`--demo` / `mise demo`**: synthetic sensors (a scripted temperature
  trace) and a fake daemon, so the canvas can be filmed without heating a
  Mac; the window says DEMO.
- **Mark**: `scripts/icon.svg`, rendered by `mise icon`; the menu glyph is a
  template render of the same paths.
- **Verbs**: `mise.toml` (`build · dev · demo · check · install · uninstall
  · notes · release · cask`), awake's scripts as the model; `VERSION` in
  mise.toml is truth; `notes/<version>.md` is the release body and the
  words gate.
- **Release**: awake's pipeline verbatim: sign (Developer ID), notarize,
  staple, dmg, tag, GitHub Release, cask in `adriangalilea/tap`. CI runs
  `mise check` only.

## Gotchas known before the first line

- `F{n}Md` vs `F{n}md`: casing differs by silicon (M5 is lower-case).
  Probe with `SMCGetKeyInfo` at daemon start, never hardcode.
- A forced SMC target SURVIVES the writer's death. That is why the lease and
  the startup reconciliation are not features but the foundation.
- SMAppService daemons need the plist under
  `Contents/Library/LaunchDaemons/` with `BundleProgram` relative to the
  bundle, and the bundle must be properly signed; an ad-hoc dev build can
  register but the user sees a scarier prompt. `mise run install` signs with
  the Developer ID when present, like awake.
- Never trust display sleep as "lid closed": on macOS 26 WindowServer's
  display bookkeeping and the real panel state diverge
  (`~/self/mac/lid-black-screen.md`). The daemon reads the clamshell state
  from IOPMrootDomain.
- Mac App Store is not a channel: SMC writes and a root daemon are
  impossible in the sandbox. Monitoring-only would be allowed and is not
  the product.
