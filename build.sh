#!/bin/bash
# Builds Tidier.app with swiftc (no full Xcode required) and assembles the bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Tidier.app"
OUT="build"
CONTENTS="$OUT/$APP/Contents"

rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

SDK="$(xcrun --show-sdk-path)"

echo "Compiling…"
swiftc Sources/*.swift \
  -o "$CONTENTS/MacOS/Tidier" \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -swift-version 5 \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework ApplicationServices -framework IOKit

cp Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp -R Resources/*.lproj "$CONTENTS/Resources/"

# Stable self-signed identity so TCC permissions (Accessibility, Screen Recording)
# survive rebuilds. Falls back to ad-hoc if the identity isn't present.
SIGN_ID="Tidier Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "Signing ($SIGN_ID)…"
  codesign --force --deep --sign "$SIGN_ID" --identifier de.csho.Tidier "$OUT/$APP" >/dev/null 2>&1 || true
else
  echo "Signing (ad-hoc — stable identity not found)…"
  codesign --force --deep --sign - "$OUT/$APP" >/dev/null 2>&1 || true
fi

echo "Built $OUT/$APP"
