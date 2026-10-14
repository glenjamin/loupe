#!/bin/sh
# Builds Loupe.app and opens it. Quits a running copy first so the new build
# is the one that launches.
set -eu

cd "$(dirname "$0")"
sh Scripts/bundle.sh
osascript -e 'tell application "Loupe" to quit' >/dev/null 2>&1 || true
open .build/Loupe.app
