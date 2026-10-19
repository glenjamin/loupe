#!/bin/sh
# Builds Loupe.app and opens it. Quits the copy running from this checkout
# first and waits until it's gone, as an open sent while it's still exiting
# goes to it and fails with -600. Debug build unless given "release".
set -eu

main() {
  cd "$(dirname "$0")"
  sh Scripts/bundle.sh "${1:-debug}"
  app="$(pwd -P)/.build/Loupe.app"
  # Only this bundle's processes: snapshot runs and other checkouts are left be.
  pids=$(running_pids "$app/Contents/MacOS/Loupe")
  for pid in $pids; do quit "$pid"; done
  for pid in $pids; do
    if ! wait_for_exit "$pid"; then
      echo "Loupe (pid $pid) hasn't quit after 10 seconds; it may be" \
        "asking something. Quit it, then run start.sh again." >&2
      exit 1
    fi
  done
  open "$app"
}

# Processes whose command is the given executable, as Launch Services starts it.
running_pids() {
  ps -axo pid=,command= | awk -v exe="$1" '{
    pid = $1
    sub(/^ *[0-9]+ +/, "")
    if ($0 == exe || index($0, exe " ") == 1) print pid
  }'
}

# Asks that one process to quit, as the Dock's Quit would.
quit() {
  osascript -l JavaScript -e 'function run(argv) {
    ObjC.import("AppKit")
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]))
    if (!app.isNil()) app.terminate
  }' "$1" >/dev/null
}

# Waits until the process has exited and Launch Services no longer lists it.
wait_for_exit() {
  tries=0
  while kill -0 "$1" 2>/dev/null || [ -n "$(lsappinfo find "pid=$1")" ]; do
    [ "$tries" -ge 50 ] && return 1
    tries=$((tries + 1))
    sleep 0.2
  done
}

main "$@"
