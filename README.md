# chill

Apple stays in charge of your fans unless you draw otherwise, and the moment no one is watching, or the Mac sleeps, or it runs hot, Apple is back. Fan control for the Mac, macOS 26, Apple Silicon.

A fan runs a curve: temperature in, rpm out. `apple` is macOS's own curve. `chill` is the built-in one, a floor until it kicks in and then one clean S to the fan's maximum, shaped by a single knob. A custom curve is yours, drawn on the plot point by point. chill forces a fan only while all of these hold: an intent (a curve, or a timed boost from the CLI), presence (the app or `chill ... --watch` spoke within the last 10 s), no veto (sleep, thermal pressure, no reading), and the curve asking more than the fan's floor; at the floor Apple keeps the fan. `chill status` says who holds the fans and why, in one line, always.

## Install

```
brew install --cask adriangalilea/tap/chill
```

Or the dmg on GitHub Releases. The daemon is a root LaunchDaemon registered by the app; macOS asks you to approve it once under System Settings, General, Login Items & Extensions.

## Network

None. The daemon and the app never touch the network; the logs hold fan and temperature numbers only.

## Build

```
mise run check      # format + compile, 0 warnings
mise run install    # /Applications/chill.app, signed with a Developer ID, daemon registered
```

An unsigned or ad-hoc bundle cannot register a LaunchDaemon; that is the platform's rule, not chill's. Anyone with an Apple Developer ID can build, sign and register their own.

## Prior art

SoloFan's Swift app (MIT, github.com/SoloTeamDev/solofan, six PRs by Adrian: M4/M5 control, real die temperatures, off-main-thread writes) is the prior art, credited here. SoloFan's `smc-helper` is GPL-derived (smcFanControl) and is NOT a source: chilld's writer is written from the IOKit AppleSMC user-client protocol and the key names. The `Ftst` unlock is credited to agoodkind/macos-smc-fan (MIT). Sensors come from the same read-only package as mach. The SMC temperature keys that name the chip's parts (cpu, gpu, memory) per generation, the ones the curve follows, are vendored from exelban/stats (MIT, github.com/exelban/stats, `Modules/Sensors/values.swift`), the one maintained catalogue of Apple's unpublished keys.

MIT, see LICENSE.
