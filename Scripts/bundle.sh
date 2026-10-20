#!/bin/sh
# Builds Loupe.app under .build, so the Dock and ⌘-Tab show its icon.
# Rebuilds the bundle from scratch each run. Debug by default, which is
# incremental and quick; pass "release" for an optimised build. A second
# argument of "snapshot" builds LoupeSnapshot.app instead, for snapshot runs:
# its own name and bundle id and no URL types, so Launch Services, AppleScript
# and "open -a Loupe" never mistake it for the real app, and building it never
# touches Loupe.app. Loupe.app builds in its own scratch path, so start.sh
# never waits on SwiftPM's lock while a test run or snapshot build holds .build.
set -eu

config=${1:-debug}
case ${2:-} in
  "")
    app=.build/Loupe.app name=Loupe id=com.glenmailer.Loupe
    scratch=.build/app
    ;;
  snapshot)
    app=.build/LoupeSnapshot.app name="Loupe Snapshot"
    id=com.glenmailer.Loupe.snapshot
    scratch=.build
    ;;
  *) echo "usage: Scripts/bundle.sh [debug|release] [snapshot]" >&2; exit 2 ;;
esac
cd "$(dirname "$0")/.."
# CodeEditLanguages ships prebuilt grammars whose debug info points at the
# maintainer's machine; the linker warns about each one. Nothing else is hidden.
log=$(mktemp)
if ! swift build --scratch-path "$scratch" -c "$config" >"$log" 2>&1; then cat "$log"; rm -f "$log"; exit 1; fi
grep -v "unable to open object file: No such file or directory" "$log" || true
rm -f "$log"
bin=$(swift build --scratch-path "$scratch" -c "$config" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Loupe" "$app/Contents/MacOS/Loupe"
cp Sources/Loupe/Resources/Loupe.icns "$app/Contents/Resources/Loupe.icns"
# Reads the token the circleci CLI is signed in with, to fetch CI's reports.
cp Scripts/circleci-token "$app/Contents/Resources/circleci-token"
# Kept where Xcode puts them; the bundle root would break code signing.
for bundle in "$bin"/*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done

{
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>Loupe</string>
  <key>CFBundleIconFile</key><string>Loupe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
PLIST
  # A snapshot run claims no links, so none is ever sent to it.
  if [ "$id" = com.glenmailer.Loupe ]; then cat <<'PLIST'
  <!-- loupe:// is Loupe's own. https is offered only as an alternate handler, so
       a link router or "open -a Loupe" can send PR links here without Loupe
       becoming the default browser. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.glenmailer.Loupe.pullrequest</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>loupe</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>com.glenmailer.Loupe.web</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleURLSchemes</key><array><string>https</string></array>
    </dict>
  </array>
PLIST
  fi
  printf '</dict>\n</plist>\n'
} > "$app/Contents/Info.plist"

codesign --force --deep --sign - "$app"
echo "$app"
