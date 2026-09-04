# chill

Apple stays in charge of your fans unless you draw otherwise, and the moment no one is watching, or the lid closes, or the Mac sleeps, or it runs hot, Apple is back. Fan control for the Mac, macOS 26, Apple Silicon.

A fan runs a curve: temperature in, rpm out. `system` is Apple's curve, drawn on the canvas as the cloud of what Apple really does. A named curve is yours, edited over that cloud. chill forces a fan only while all three hold: an intent (your curve or a timed boost), presence (the app or `chill ... --watch` spoke within the last 10 s) and no veto (lid closed, sleep, thermal pressure, no die reading). `chill status` says who holds the fans and why, in one line, always.

## Install

```
brew install --cask adriangalilea/tap/chill
```

Or the dmg on GitHub Releases. The daemon is a root LaunchDaemon registered by the app; macOS asks you to approve it once under System Settings, General, Login Items & Extensions.

## Update check

The app asks `chill.untitled.garden` once a day whether a newer version exists; that request doubles as the active-install count. `chill updates off` disables it. No other network, no telemetry; the logs hold fan and temperature numbers only.

## Build

```
mise run check      # format + compile, 0 warnings
mise run install    # /Applications/chill.app, signed with a Developer ID, daemon registered
```

An unsigned or ad-hoc bundle cannot register a LaunchDaemon; that is the platform's rule, not chill's. Anyone with an Apple Developer ID can build, sign and register their own.

## Prior art

SoloFan's Swift app (MIT, github.com/SoloTeamDev/solofan, six PRs by Adrian: M4/M5 control, real die temperatures, off-main-thread writes) is the prior art, credited here and in About. SoloFan's `smc-helper` is GPL-derived (smcFanControl) and is NOT a source: chilld's writer is written from the IOKit AppleSMC user-client protocol and the key names. The `Ftst` unlock is credited to agoodkind/macos-smc-fan (MIT). Sensors come from the same read-only package as mach.

MIT, see LICENSE.
