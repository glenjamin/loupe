#!/bin/sh
# Builds Loupe.app under .build, so the Dock and ⌘-Tab show its icon.
# Rebuilds the bundle from scratch each run. Debug by default, which is
# incremental and quick; pass "release" for an optimised build.
set -eu

config=${1:-debug}
cd "$(dirname "$0")/.."
# CodeEditLanguages ships prebuilt grammars whose debug info points at the
# maintainer's machine; the linker warns about each one. Nothing else is hidden.
log=$(mktemp)
if ! swift build -c "$config" >"$log" 2>&1; then cat "$log"; rm -f "$log"; exit 1; fi
grep -v "unable to open object file: No such file or directory" "$log" || true
rm -f "$log"
bin=$(swift build -c "$config" --show-bin-path)
app=.build/Loupe.app

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Loupe" "$app/Contents/MacOS/Loupe"
cp Sources/Loupe/Resources/Loupe.icns "$app/Contents/Resources/Loupe.icns"
# Kept where Xcode puts them; the bundle root would break code signing.
for bundle in "$bin"/*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Loupe</string>
  <key>CFBundleDisplayName</key><string>Loupe</string>
  <key>CFBundleIdentifier</key><string>com.glenmailer.Loupe</string>
  <key>CFBundleExecutable</key><string>Loupe</string>
  <key>CFBundleIconFile</key><string>Loupe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
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
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app"
echo "$app"
