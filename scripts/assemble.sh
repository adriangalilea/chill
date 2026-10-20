#!/bin/sh
# Bundle assembly, used by `mise run install` and `mise run release` so the
# app you run and the app you ship can never diverge.
#   scripts/assemble.sh <destination.app>     (VERSION in the environment)
# Two Mach-Os in one bundle: chill (app + CLI, the bundle's executable) and
# chilld (the root daemon) beside it in Contents/MacOS, which is where the
# launchd plist's BundleProgram points. The plist is stamped into
# Contents/Library/LaunchDaemons, the one place SMAppService.daemon reads.
# BUNDLE_ID names the app: the release's by default, the development build's
# (`garden.untitled.chill.dev`, "chill Dev") for local installs, whose daemon
# is `garden.untitled.chilld.dev` with its own log (Sources/ChillKit/Identity.swift).
# CONFIG picks the SwiftPM build to bundle (release, or debug).
# Assembled by hand (no Xcode).
set -e
dest="$1"
[ -n "$dest" ] || { echo "usage: scripts/assemble.sh <destination.app>"; exit 1; }
[ -n "$VERSION" ] || { echo "VERSION is not set"; exit 1; }
id="${BUNDLE_ID:-garden.untitled.chill}"
name="${BUNDLE_NAME:-chill}"
config="${CONFIG:-release}"
if [ "$id" = garden.untitled.chill ]; then daemon=garden.untitled.chilld root=chill; else daemon=garden.untitled.chilld.dev root=chill-dev; fi
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources" "$dest/Contents/Library/LaunchDaemons"
ditto ".build/$config/chill" "$dest/Contents/MacOS/chill"
ditto ".build/$config/chilld" "$dest/Contents/MacOS/chilld"
sed -e "s|__DAEMON__|$daemon|g" -e "s|__ROOT__|$root|g" launchd/daemon.plist.in > "$dest/Contents/Library/LaunchDaemons/$daemon.plist"
ditto Resources/Assets.car "$dest/Contents/Resources/Assets.car"
ditto Resources/chill.icns "$dest/Contents/Resources/chill.icns"
sed -e "s|__VERSION__|$VERSION|g" -e "s|__BUNDLE_ID__|$id|g" -e "s|__NAME__|$name|g" launchd/Info.plist.in > "$dest/Contents/Info.plist"
