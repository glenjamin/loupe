#!/bin/sh
# Runs the UI suite: each Scripts/ui-tests/*.loupe (only those whose name contains the
# argument, if given) as a snapshot run against the fixtures (LOUPE_FIXTURES), with the fake
# GitHub serving probe/, no network, and a fresh database and fixture checkouts of its own.
# Builds the snapshot bundle and the checkouts as needed, then runs the scripts in parallel
# (LOUPE_UI_JOBS at a time, 4 by default). Prints a line per script with its time, then each
# failure's output; PNGs and output go to .build/ui-tests/<script>/. Exits 1 if any failed.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
suite="$root/.build/ui-tests"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
seconds() { printf '%d.%ds' $(($1 / 1000)) $(($1 % 1000 / 100)); }

if [ "${1:-}" = "--run" ]; then
  # One script, in the work directory the suite made; called by the suite below.
  script=$2 work=$3
  name=$(basename "$script" .loupe)
  run="$work/$name" out="$suite/$name"
  rm -rf "$out"
  mkdir -p "$run" "$out"
  # An APFS clone, so each run's own checkouts cost next to nothing.
  cp -cR "$suite/.checkouts" "$run/checkouts"
  id="com.glenmailer.Loupe.uitest.$name"
  defaults delete "$id" >/dev/null 2>&1 || true
  start=$(now_ms)
  status=0
  LOUPE_FIXTURES="$run" LOUPE_SNAPSHOT_SCRIPT="$root/$script" LOUPE_SNAPSHOT_DIR="$out" \
    "$suite/.apps/$name.app/Contents/MacOS/Loupe" >"$out/output.txt" 2>&1 </dev/null || status=$?
  took=$(seconds $(( $(now_ms) - start )))
  defaults delete "$id" >/dev/null 2>&1 || true
  rm -rf "$run"
  if [ "$status" -eq 0 ]; then
    echo "pass  $name  $took"
  else
    echo "FAIL  $name  $took"
    echo "$name" >>"$work/failed"
  fi
  exit 0
fi

filter=${1:-}
scripts=$(ls Scripts/ui-tests/*.loupe | grep -F -- "$filter" || true)
if [ -z "$scripts" ]; then
  echo "No script in Scripts/ui-tests matches \"$filter\"" >&2
  exit 2
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/loupe-ui-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
suite_start=$(now_ms)

sh Scripts/bundle.sh debug snapshot >&2
app="$root/.build/LoupeSnapshot.app"
mkdir -p "$suite/.apps"

# The fixture checkouts, made again only when what makes them has changed. Runs only read them.
stamp=$(cat Sources/LoupeFakeGitHub/FixtureCheckouts.swift Sources/LoupeFakeGitHub/FakeRepository.swift | shasum | cut -d' ' -f1)
if [ "$(cat "$suite/.checkouts.stamp" 2>/dev/null)" != "$stamp" ]; then
  rm -rf "$suite/.checkouts"
  "$app/Contents/MacOS/Loupe" --fixture-checkouts "$suite/.checkouts"
  echo "$stamp" >"$suite/.checkouts.stamp"
fi

# Each script runs the bundle under an id of its own, so its settings are its own, from a copy
# kept between suites with the executable hard-linked: macOS checks each new executable on its
# first launch, so a copy is made again only when the build has changed.
for script in $scripts; do
  name=$(basename "$script" .loupe)
  copy="$suite/.apps/$name.app"
  if [ "$(stat -f %i "$copy/Contents/MacOS/Loupe" 2>/dev/null)" != "$(stat -f %i "$app/Contents/MacOS/Loupe")" ]; then
    rm -rf "$copy"
    mkdir -p "$copy/Contents/MacOS"
    cp -cR "$app/Contents/Resources" "$copy/Contents/Resources"
    cp "$app/Contents/Info.plist" "$copy/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "com.glenmailer.Loupe.uitest.$name" "$copy/Contents/Info.plist"
    ln "$app/Contents/MacOS/Loupe" "$copy/Contents/MacOS/Loupe"
  fi
done

echo "$scripts" | xargs -P "${LOUPE_UI_JOBS:-4}" -I{} sh "$0" --run {} "$work"

took=$(seconds $(( $(now_ms) - suite_start )))
count=$(echo "$scripts" | wc -l | tr -d ' ')
if [ ! -f "$work/failed" ]; then
  echo "All $count passed in $took"
  exit 0
fi
for name in $(cat "$work/failed"); do
  out="$suite/$name"
  echo
  echo "--- $name"
  # The last steps that passed, then the failure and the part of the tree it looked in; or the
  # end of the output, if the run stopped without saying.
  grep '^ok' "$out/output.txt" | tail -3 || true
  if grep -q '^FAIL' "$out/output.txt"; then
    awk '/^FAIL/ { failing = 1 } failing { print; if (++shown == 80) exit }' "$out/output.txt"
  else
    tail -20 "$out/output.txt"
  fi
  if [ -f "$out/failure.png" ]; then echo "$out/failure.png"; fi
  echo "full output: $out/output.txt"
done
echo
echo "$(wc -l <"$work/failed" | tr -d ' ') of $count failed in $took"
exit 1
