#!/usr/bin/env bash
# Builds DisplayControl.app (and a zip) into ./dist. Ad-hoc signed.
# Notarization needs a Developer ID and is not automated here:
#   codesign --force --options runtime --entitlements Packaging/DisplayControl.entitlements --sign "Developer ID Application: NAME" dist/DisplayControl.app
#   xcrun notarytool submit dist/DisplayControl.zip --apple-id ... --wait && xcrun stapler staple dist/DisplayControl.app
set -euo pipefail
cd "$(dirname "$0")/.."

build() { swift build -c release "$@"; }

# With only the Command Line Tools installed, the newest SDK can lack the SwiftUI macro plugin.
# If the default SDK fails, fall back to older SDKs that ship with the tools.
if ! build >/tmp/displaycontrol-build.log 2>&1; then
  echo "Default SDK failed, trying older SDKs..."
  ok=0
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX2*.sdk 2>/dev/null | sort -r); do
    if build --sdk "$sdk" >/tmp/displaycontrol-build.log 2>&1; then echo "Built with $sdk"; ok=1; break; fi
  done
  [ "$ok" = 1 ] || { tail -30 /tmp/displaycontrol-build.log; exit 1; }
fi

BIN="$(swift build -c release --show-bin-path)"
APP="dist/DisplayControl.app"
rm -rf "$APP" dist/DisplayControl.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/DisplayControlApp" "$APP/Contents/MacOS/DisplayControl"
cp "$BIN/displaycontrol" "$APP/Contents/Resources/bin/displaycontrol"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
mkdir -p dist/completions && cp Packaging/completions/* dist/completions/ 2>/dev/null || true

# Ad-hoc signing changes the code identity on every rebuild, which resets the Accessibility grant.
codesign --force --deep --sign - "$APP/Contents/Resources/bin/displaycontrol"
codesign --force --deep --sign - "$APP"
(cd dist && ditto -c -k --keepParent DisplayControl.app DisplayControl.zip)
shasum -a 256 dist/DisplayControl.zip | tee dist/DisplayControl.zip.sha256
echo "Built $APP"
