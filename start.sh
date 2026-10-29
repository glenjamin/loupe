#!/bin/sh
# Builds Loupe.app and opens it. Quits the copy running from this checkout
# first and waits until it's gone, as an open sent while it's still exiting
# goes to it and fails with -600. Debug build unless given "release".
#
# "install" instead copies a release build (or debug, if given) to
# ~/Applications/Loupe.app, quitting that copy first if it's running. It's
# copied rather than moved so the checkout's bundle stays as it was, and the
# next build doesn't make it afresh.
set -eu

main() {
  cd "$(dirname "$0")"
  case ${1:-} in
    install) install_app "${2:-release}" ;;
    ""|debug|release) start "${1:-debug}" ;;
    *) echo "usage: ./start.sh [debug|release] | ./start.sh install [debug|release]" >&2; exit 2 ;;
  esac
}

start() {
  sh Scripts/bundle.sh "$1"
  app="$(pwd -P)/.build/Loupe.app"
  quit_all "$app"
  open "$app"
}

install_app() {
  sh Scripts/bundle.sh "$1"
  installed="$HOME/Applications/Loupe.app"
  quit_all "$installed"
  mkdir -p "$HOME/Applications"
  rm -rf "$installed"
  ditto .build/Loupe.app "$installed"
  echo "Installed $installed" >&2
}

# Quits every process running the bundle's executable and waits until they've
# gone; only that bundle's, so snapshot runs and other copies are left be.
quit_all() {
  pids=$(running_pids "$1/Contents/MacOS/Loupe")
  for pid in $pids; do quit "$pid"; done
  for pid in $pids; do
    if ! wait_for_exit "$pid"; then
      echo "Loupe (pid $pid) hasn't quit after 10 seconds; it may be" \
        "asking something. Quit it, then run start.sh again." >&2
      exit 1
    fi
  done
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
