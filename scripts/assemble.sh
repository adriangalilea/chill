#!/bin/sh
# Bundle assembly, used by BOTH `mise run install` and `mise run release` so
# the app you run and the app you ship can never diverge.
#   scripts/assemble.sh <destination.app>     (VERSION in the environment)
# Two Mach-Os in one bundle: chill (app + CLI, the bundle's executable) and
# chilld (the root daemon) beside it in Contents/MacOS, which is where the
# launchd plist's BundleProgram points. The plist is copied verbatim to
# Contents/Library/LaunchDaemons, the one place SMAppService.daemon reads.
# Assembled by hand (no Xcode).
set -e
dest="$1"
[ -n "$dest" ] || { echo "usage: scripts/assemble.sh <destination.app>"; exit 1; }
[ -n "$VERSION" ] || { echo "VERSION is not set"; exit 1; }
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources" "$dest/Contents/Library/LaunchDaemons"
ditto .build/release/chill "$dest/Contents/MacOS/chill"
ditto .build/release/chilld "$dest/Contents/MacOS/chilld"
ditto launchd/garden.untitled.chilld.plist "$dest/Contents/Library/LaunchDaemons/garden.untitled.chilld.plist"
ditto Resources/Assets.car "$dest/Contents/Resources/Assets.car"
ditto Resources/chill.icns "$dest/Contents/Resources/chill.icns"
sed "s|__VERSION__|$VERSION|g" launchd/Info.plist.in > "$dest/Contents/Info.plist"
