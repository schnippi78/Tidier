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
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework ApplicationServices -framework IOKit -framework CoreLocation

cp Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp -R Resources/*.lproj "$CONTENTS/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$CONTENTS/Resources/"

# Stable self-signed identity so TCC permissions (Accessibility, Screen Recording)
# survive rebuilds. Falls back to ad-hoc if the identity isn't present.
# Resolve by SHA-1 hash, not name: codesign treats two certs of the same name as
# "ambiguous" and refuses, so matching the exact valid identity is safer.
SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Tidier Self-Signed/{print $2; exit}')
if [ -n "$SIGN_HASH" ]; then
  echo "Signing (Tidier Self-Signed $SIGN_HASH)…"
  codesign --force --deep --sign "$SIGN_HASH" --identifier de.csho.Tidier "$OUT/$APP" || echo "  codesign FAILED"
else
  echo "Signing (ad-hoc — stable identity not found)…"
  codesign --force --deep --sign - "$OUT/$APP" >/dev/null 2>&1 || true
fi

echo "Built $OUT/$APP"
