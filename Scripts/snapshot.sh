#!/bin/sh
# Builds Loupe.app, opens it with LOUPE_SNAPSHOT_DIR set so it writes a PNG of
# each window into the given directory once loaded, and prints their paths.
# Set LOUPE_DATABASE to run against a throwaway copy of the database.
set -eu

if [ $# -ne 1 ]; then
  echo "usage: Scripts/snapshot.sh <dir>" >&2
  exit 2
fi
mkdir -p "$1"
dir=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
sh Scripts/bundle.sh >&2
# Run directly rather than with `open`, which doesn't pass the environment on.
LOUPE_SNAPSHOT_DIR="$dir" .build/Loupe.app/Contents/MacOS/Loupe
