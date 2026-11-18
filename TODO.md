# TODO

## Next

- [ ] CI cannot build chill: GitHub's hosted runners stop at macOS 26 and chill needs macOS 27 and Swift 6.4. swift-utils runs on the household runner its `MAC_RUNNER` repo variable names; chill joins it the same way (push to main only, no `pull_request` run: a public repo's pull request would run a stranger's code on the Mac), Adrian's call. Until then every push reads red.
- [ ] The stage scenes still print the status line from before heat (`51°C → 2600 rpm`, now `heat 51°C → 2600 rpm`): `mise scene` rewrites the garden's timelines and the CDN's clips.
- [ ] The heat constants (`Heat.chipSettles` 1.5 s, `Heat.coolerSheds` 45 s) are one M5 Max's, measured at Apple's idle fans. The cooler sheds faster with more air, so under chill's fans the fall is if anything slower than the cooler: conservative. A Mac that disagrees is measured with `chill sensors --follow --json` under a step load and replayed with `Examples/HeatReplay`. Live proof on real fans of the bursts (the replays are the proof today: an M4 Pro's working day, 8.4 fan reversals a minute to 0.5) is by ear on the M4 after the upgrade.
- [ ] chilld costs about 0.2 % of a core, nearly all of it the 1 Hz SMC reads (two dozen part keys, each fan's mode, actual and target, `Ftst`). Unprofiled: a `sample` of a root process needs root.
- [ ] Installs from before 0.2.0 keep `~/.local/state/chill/cloud/`, which nothing reads now; it goes with the rest of the app's state when chill is deleted.

- [ ] Updates through Sparkle as well as brew, as one pattern for every app (lore already ships Sparkle and the release tooling writes its feed). The daily check exists (`UpdateCheck.swift`, awake's model: the menu says a newer version is out, brew upgrades it); Sparkle would install it in one press. Brew stays truthful with `auto_updates true` on the cask (brew then leaves the upgrade to the app unless `--greedy`), and an upgraded bundle already takes chilld over (AppInstallations' `ImageWatch`). The pattern is swift-utils' TODO (Sparkle's three plist keys stay app-side, the appcast is `ship`'s release half), not hand-rolled here. The update check's switch is the app menu's alone: `config.json` is the app's file and the running app rewrites it, so a CLI `updates on|off` would be overwritten.
- [ ] Apple's observed curve back on the plot as ONE dotted line, the median rpm per degree where data exists, never as cells; only once hours of use across many temperatures exist to draw it from.
- [ ] Measure the field on one M-series Mac (Macs Fan Control, TG Pro, iStat Menus): `kill -9`, sleep, lid close; record whether the forced target survives.
- [ ] Spotlight, Shortcuts and Siri through App Intents (`toggle`, `chill`, `apple`, `use <curve>`, `status`) over Keymap's `IntentSupport`. Blocked on build plumbing, not code: the intent metadata Spotlight reads is extracted by Xcode's `appintentsmetadataprocessor`, which `swift build` never runs. The tool is invocable by hand (`xcrun appintentsmetadataprocessor`, wants a source-file list and the compiler's const-values); wire it into `assemble.sh`, then write the intents.

## The lab

The lab window duplicates the popover today (same plot, the curve list, the keys) and drifts from it; the popover is the product. The window is where the things below live so the menu bar stays lean.

- A "heat it" button: stress the machine on purpose to WATCH the plot do its thing, the die climbing, the fans following, the afterglow. Doubles as the fast way to record Apple's observed curve: an hour of varied use compressed into minutes.
- Useful heat: if the button burns watts, let the burn do work. Fits for a bursty, sporadic, elastic contribution that pays even with a handful of users, best first:
  - GIMPS (Prime95 / mprime, Mac build): real number theory, checkpoints every few minutes so a gust-length burst counts, per-user credit.
  - Folding@home or BOINC (Einstein@Home, Rosetta@home): work units checkpoint, the client pauses and resumes; more setup than GIMPS, more science.
  - A thermal atlas of Macs: every heat run uploads an anonymous trace (chip, die and fan over time, Apple's observed curve) to a public dataset of how each Mac model heats and cools.
  - Your own work: re-encode a video archive, run your test suites, warm caches; useful at N = 1, no network.
  Coins are out: the heat should mean something.

## Later, not designed in

- Per-power-source curves (docked vs battery); per-app curves.
- Intel Macs (`fpe2` targets) if anyone asks.
