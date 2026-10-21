#!/bin/sh
# Builds LoupeSnapshot.app, opens it with LOUPE_SNAPSHOT_DIR set so it writes a PNG of
# each window into the given directory once loaded, and prints their paths.
# Set LOUPE_DATABASE to run against a throwaway copy of the database, and
# LOUPE_SNAPSHOT_SCRIPT to drive the run from a script; it exits non-zero when one fails.
# LOUPE_FIXTURES runs against the fake GitHub instead; Scripts/ui-tests.sh sets it up.
set -eu

if [ $# -ne 1 ]; then
  echo "usage: Scripts/snapshot.sh <dir>" >&2
  exit 2
fi
mkdir -p "$1"
dir=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
sh Scripts/bundle.sh debug snapshot >&2
# Run directly rather than with `open`, which doesn't pass the environment on, and in this
# process's place, so the run's exit status is the script's.
LOUPE_SNAPSHOT_DIR="$dir" exec .build/LoupeSnapshot.app/Contents/MacOS/Loupe
