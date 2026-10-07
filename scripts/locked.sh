#!/bin/sh
# THE BUILD MUTEX: every compiling task runs through this, so concurrent
# invocations serialize instead of fighting over .build. The lock holds its
# owner's pid: a lock whose owner is dead (a killed build, whose trap never
# ran) is taken at once, and a waiter says who it waits for, so a build is
# never silently stuck behind another.
#   scripts/locked.sh <command...>
set -e
lock="${TMPDIR:-/tmp}/chill-build.lock"
said=""
# The lock is a directory holding one file, removed by exact name.
drop() { rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true; }
while ! mkdir "$lock" 2>/dev/null; do
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -z "$owner" ]; then
    # Made but not yet signed: its owner is between mkdir and the write.
    # One that stays unsigned for a second was left by a killed build.
    sleep 1
    [ -z "$(cat "$lock/pid" 2>/dev/null || true)" ] && drop
    continue
  fi
  if ! kill -0 "$owner" 2>/dev/null; then
    echo "chill: build lock held by pid $owner, which is gone: taking it" >&2
    drop
    continue
  fi
  if [ "$said" != "$owner" ]; then
    echo "chill: waiting for build pid $owner: $(ps -o command= -p "$owner" | cut -c1-120)" >&2
    echo "chill: kill $owner to stop it" >&2
    said="$owner"
  fi
  sleep 1
done
echo $$ >"$lock/pid"
trap drop EXIT
"$@"
