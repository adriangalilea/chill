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
the gates need a signed install on real fans. Human gates, in order:
`mise run install` (Developer ID) → approve chilld in System Settings ›
Login Items → `chill daemon status` → quit SoloFan → first `chill curve
use <name> --watch` on real fans → `garden genesis chill --desc "..."`.

- [ ] Hello-world chilld: bundle assembled by `mise run install`
      (Developer ID required), plist under `Contents/Library/LaunchDaemons`
      with Label, BundleProgram, MachServices, KeepAlive, ThrottleInterval 1,
      log paths; registered, status polled to `.enabled` after approval,
      login item registered; one XPC round trip from the CLI with the
      code-signing requirement derived from the daemon's own code. Gate:
      `chill daemon status` reports pid and signature check; a copy of the
      CLI re-signed with another identity is rejected; record whether a
      signed-but-un-notarized install registers on macOS 26.
- [ ] SMC writer as specified in CLAUDE.md (mode 0/1/3, result byte,
      acquire with `Ftst` unlock on its own task, auto = mode 0 + `Ftst` 0
      + read-back, envelope cached once, type assertions). Gate on an
      M-series Mac: force a target from mode 3 and hold it 30 s; toggle
      system ↔ curve five times with no thrash and a truthful status
      throughout; `kill -9` during the unlock window → restart → `Ftst`
      reads 0 and mode reads 0 or 3.
- [ ] The contract: intent persisted in `policy.json`, presence with a
      `ContinuousClock` deadline, the veto set, the 1 Hz evaluator, the
      reference cloud for fans Apple holds. Gates: quit or `kill -9` the
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
- [ ] Refine `SMCWriter.slewPerSample` (300 rpm/s today) from the `F{n}Ac`
      slew the reference cloud records.
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

## Later, not designed in

- Per-power-source curves (docked vs battery); per-app curves.
- A `mach` row in the power area that reads chill's `State`.
- Intel Macs (`fpe2` targets) if anyone asks.
