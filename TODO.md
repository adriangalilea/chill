# TODO

## Next

- [ ] Update check: a daily appcast GET from the app (awake's model), a `config.json` switch, `chill updates on|off` in main.swift and the verb list; README's Network section then declares it. Until it exists nothing claims it.
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
