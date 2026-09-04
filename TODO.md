# TODO

Build order. Each milestone ends with something runnable; nothing below
starts before the one above is green.

## 0 · seam (before any chill code)

- [ ] Lift `HIDSensors.swift` + `SMC.swift` (reads only) out of MachCore into
      a shared target both apps consume by path; mach's `check` stays green.
      The public `swift-hw` package waits for chill's ship day.
- [ ] `garden genesis chill --desc "..."` (private + DRAFT). Mark: `scripts/icon.svg`.

## 1 · chilld: the daemon and the lease

- [ ] Root LaunchDaemon, `SMAppService.daemon`, plist in the bundle. XPC with
      a code-signing requirement on the client.
- [ ] SMC writer: `F{n}Md`/`F{n}md` probe, `set(targets:)`, `auto()`. Startup
      reconciliation: first act is `auto`.
- [ ] Lease: 10 s, renewed by the client; expiry → `auto`. Log every
      transition with the reason (`os_log`, subsystem `garden.untitled.chill`).
- [ ] Own nets, before expiry: clamshell closed (IOPMrootDomain), will-sleep
      and dark wake (IOKit power notifications), thermal pressure, every
      exit path.
- [ ] `chill daemon install|uninstall`, `chill status` reading the daemon's
      state, `chill system`. Gate: quit the client mid-curve → fans return
      to Apple within 10 s; `kill -9` the daemon → restart → `auto`.

## 2 · curves and the CLI

- [ ] `Curve` model: named, points (°C, rpm), linear interpolation, clamp to
      hardware limits, 50 rpm hysteresis, 2 s ramp. Persisted as JSON in
      the app's container; `chill curve list|use|show`.
- [ ] Flat curve = constant rpm. `boost [minutes]` = max, self-ending.
- [ ] The observer: while `system`, record (temp, rpm) points into a rolling
      cloud per fan; that is the reference the canvas draws.
- [ ] `status --json`, `log`. Foreign-forced detection (mode forced, no
      lease) → `foreign` in status.

## 3 · the app

- [ ] Menu bar (Ink + Keymap): effect glyph, curve picker, boost, system,
      `?` bindings. Right-click toggles system ↔ last curve.
- [ ] Canvas: reference cloud, active curve, live temperature and target
      markers, keyboard point editing, Ink.CursorScrollView list.
- [ ] `--demo`: scripted temperature trace + fake daemon; DEMO on screen.
- [ ] `mise.toml` verbs, `assemble.sh` from awake, icon pipeline, `check`
      at 0 warnings, `.swift-format` byte-identical to the root.

## 4 · ship

- [ ] Notes gate: `notes/0.1.0.md` written by a human, README with the
      prior-art paragraph (SoloFan, MIT, the six PRs) and the lease as the
      first sentence.
- [ ] `mise run release`: sign, notarize, staple, dmg, tag, GitHub Release,
      cask in `adriangalilea/tap`. Public repo, submodule mount.
- [ ] Surface: feature stills (the canvas; `status` flipping to system on
      quit), `garden genesis chill --ship`, `chill.untitled.garden`.
- [ ] Retire SoloFan from the fleet: Brewfile/apps script, `smc-helper`
      sudoers rule removed (`/etc/sudoers.d/smc-fan-helper`),
      `/usr/local/bin/smc-helper` trashed.

## Later, not designed in

- Per-app or per-power-source curves (docked vs battery).
- A `mach` row that reads chill's state (who holds the fans) in the
  power area.
