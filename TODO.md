# TODO

Build order. Each milestone ends with something runnable and a gate;
nothing below starts before the one above is green.

## 0 · seam and birth

- [x] In `apps/mach` (its own private repo): add the `MachSensors` library
      product beside MachCore (HIDSensors + a rewritten SMC reader: `info`
      via READ_KEYINFO, typed reads `flt `/`ui8`/`ui16`, `fans()` from
      `FNum`, public 80-byte codec, typed errors from the result byte, no
      write function; assert on unknown types instead of returning a
      float). MachCore and the App depend on it; `mach sensors` FNum line
      is the regression check; `mach check` stays green. Push from the
      mount, bump the pointer here. License header on the lifted files.
- [x] `apps/chill`: Package.swift (`.package(path: "../mach")`, product
      MachSensors; swift-utils by versioned URL; macOS 26), targets
      ChillKit · chilld · chill; `apps/chill/package.json` with the
      two-line `check`; root `pnpm chill` / `pnpm chill:install` aliases;
      `.swift-format` byte-identical to the root; `mise.toml` verbs with
      `APP = /Applications/chill.app`, `assemble.sh`, `locked.sh`,
      `.github/cliff.toml` from awake; `scripts/icon.svg` + `mise icon`.
- [ ] `garden genesis chill --desc "..."` (private + DRAFT).

## 1 · chilld: registration, then the writer, then the nets

Everything below is written and compiles (`mise check` at 0 warnings);
the gates need a signed install on real fans. Done on the M5 Max: the
signed install registers and is approved, chilld answers, SoloFan is
retired from this Mac, curves force real fans. Human gates left:
`garden genesis chill --desc "..."`, the M4's `Ftst` gates, the sleep
and lid gates below.

- [x] Hello-world chilld: bundle assembled by `mise run install`
      (Developer ID required), plist under `Contents/Library/LaunchDaemons`
      with Label, BundleProgram, MachServices, KeepAlive, ThrottleInterval 1,
      log paths; registered, status polled to `.enabled` after approval,
      login item registered; one XPC round trip from the CLI with the
      code-signing requirement derived from the daemon's own code. Proven:
      `chill daemon status` reports pid and signature; a Developer-ID
      signed, un-notarized bundle registers on macOS 26.6 (so `install`
      need not notarize). Not yet: a re-signed CLI copy rejected.
- [x] SMC writer as specified in CLAUDE.md (mode 0/1/3, result byte,
      acquire on its own task, auto = mode 0 + read-back, envelope cached
      once, type assertions). Proven on the M5 Max (no `Ftst`): targets
      forced and held, apple ↔ chill ↔ gust toggled many times with a
      truthful status, auto on every hand-back. The `Ftst` paths wait for
      the M4.
- [ ] The contract: intent persisted in `policy.json`, presence with a
      `ContinuousClock` deadline, the veto set, the 1 Hz evaluator, the
      reference cloud for fans Apple holds. Built; proven so far: the app's
      presence and the daemon's read-back at 1 Hz. Gates: quit or `kill -9` the
      app mid-curve → Apple within 1 s (XPC invalidation); `SIGSTOP` the
      app → within 10 s; close the lid on an external display → status
      shows the veto and stays Apple for as long as the lid is closed,
      presence notwithstanding; `launchctl kill TERM system/garden.untitled.chilld`
      → auto before exit; sleep → auto before the ack, no 30 s delay in
      `pmset -g log`; `chill daemon uninstall` → fans on Apple's curve,
      registration gone.
- [x] `chill status`, `system`, `daemon install|uninstall|status`, `log`.

## 2 · curves and the CLI

- [x] `Curve` in ChillKit: named, points (°C, rpm), interpolation, per-fan
      clamp to the envelope shipped in `hello`; files under
      `~/.local/state/chill/curves`; `chill curve list|show|use [--watch]`;
      flat curve = constant; `boost [minutes] [--watch]` self-ending in the
      daemon.
- [x] `status --json` = `State`; foreign detection from the read-back;
      `take` for a second client.
- [ ] Apple's observed curve back on the plot as ONE dotted line, the
      median rpm per degree where data exists, never as cells; only once
      hours of use across many temperatures exist to draw it from.
- [ ] Measure the field on one M-series Mac (Macs Fan Control, TG Pro,
      iStat Menus): `kill -9`, sleep, lid close; record whether the forced
      target survives. The strategy table and the pitch cite these numbers.

## 3 · the app

- [x] Menu bar (Ink + Keymap, `ActionID` registry): effect glyph with the
      five states, curve picker, boost, system, `?` bindings, right-click
      toggles system ↔ last curve, the no-daemon menu that leads with the
      fixing action and polls `SMAppService.status`.
- [x] Canvas: reference clouds, active curve, live markers, keyboard point
      editing, Ink.CursorScrollView list, envelope from `hello`.
- [x] Presence at 1 Hz gated on console session + screens awake; the
      persisted intent resumes at login.
- [x] `--demo`: forked `chill-demo` roots, scripted trace, in-process fake
      daemon, `demo` kicker, CLI `· demo` headers.
- [ ] Update check: a daily appcast GET from the app (awake's model), a
      `config.json` switch, `chill updates on|off` in main.swift and the
      verb list; the README's Network section then declares it. Until it
      exists nothing claims it.
- [x] `mise check` at 0 warnings, format-clean.

## 4 · ship

- [ ] Publish `swift-hw` (github.com/adriangalilea/swift-hw, MIT, 0.1.0)
      from MachSensors; flip chill's dependency to `from: "0.1.0"`; mach
      keeps the path until its own open-source decision.
- [ ] Create github.com/adriangalilea/chill (MIT, awake's
      `.github/workflows/ci.yml`), move `apps/chill` into it, mount it as a
      submodule in `.gitmodules`.
- [ ] Words gate: `notes/0.1.0.md` in the release grammar, written by a
      human; README with the prior-art paragraph (SoloFan MIT app,
      smcFanControl GPL not used, agoodkind/macos-smc-fan MIT for `Ftst`),
      presence and the vetoes as the first sentence, the update check
      declared.
- [ ] `mise run release` from the mount: sign, notarize, staple, dmg, tag,
      GitHub Release, `publish` (R2 + `garden notes chill`), cask. Bump the
      pointer in the studio.
- [ ] Surface: feature stills (the canvas; `status` flipping to Apple on
      quit); `garden genesis chill --ship --icon Resources/icon.png --repo
      adriangalilea/chill --source https://github.com/adriangalilea/chill
      --license MIT --command "brew install --cask adriangalilea/tap/chill"
      --platform macos --stack swift`; `vercel domains add
      chill.untitled.garden untitled-garden`.
- [ ] Retire SoloFan from the fleet: Brewfile/apps script,
      `/etc/sudoers.d/smc-fan-helper` (sudo, pbcopy to Adrian),
      `/usr/local/bin/smc-helper` trashed.

## Deferred, for fun

- The canvas window becomes the lab. Today it duplicates the popover
  (same plot, the curve list, the keys) and drifts from it; the popover
  is the product. The window is where the things below live so the menu
  bar stays lean: the heat button, Apple's observed curve, the atlas,
  experiments. Until then it stays as it is, reachable with `c`.
- A "heat it" button: stress the machine on purpose to WATCH the plot do
  its thing, the die climbing, the fans following, the afterglow. mach
  already has the kernels (`Bench`, `GPUKernel`); chill would call the
  same package and show the run. Doubles as the fast way to record
  Apple's observed curve: an hour of varied use compressed into minutes.
- Useful heat: if the button burns watts, let the burn do work. Fits for
  a bursty, sporadic, elastic contribution that pays even with a handful
  of users, best first:
  - GIMPS (Prime95 / mprime, the classic torture test, Mac build):
    real number theory, checkpoints every few minutes so a gust-length
    burst counts, per-user credit, valuable at one user, scales linearly.
  - Folding@home or BOINC (Einstein@Home, Rosetta@home): work units
    checkpoint, the client pauses and resumes, contribution is counted
    per user; more setup than GIMPS, more science.
  - A thermal atlas of Macs: every heat run uploads an anonymous trace
    (chip, die and fan over time, Apple's observed curve) to a public
    dataset of how each Mac model heats and cools. Nobody has it, it is
    the field measurement strategy/ wants, and it is worth something at
    ten users.
  - Your own work: re-encode lore's archive, run your test suites, warm
    caches; useful at N = 1, no network.
  Coins are out: the heat should mean something.

## Later, not designed in

- Per-power-source curves (docked vs battery); per-app curves.
- A `mach` row in the power area that reads chill's `State`.
- Intel Macs (`fpe2` targets) if anyone asks.
