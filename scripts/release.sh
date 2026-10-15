#!/bin/bash
# Builds a UNIVERSAL (arm64 + x86_64) Tidier.app, packages it as a DMG, and — when a
# Developer ID identity and notarytool credentials are present — notarizes and staples it.
#
# Signing:
#   • Developer ID Application cert present  → hardened-runtime + timestamp signing (notarizable)
#   • otherwise                              → stable self-signed "Tidier Self-Signed"
#                                              (runs locally; Gatekeeper blocks it on other Macs)
#
# Notarization (only with a Developer ID signature):
#   store credentials once:
#     xcrun notarytool store-credentials tidier-notary \
#        --apple-id "<you@example.com>" --team-id "<TEAMID>" --password "<app-specific-pw>"
#   then run:   NOTARY_PROFILE=tidier-notary scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Tidier.app"
OUT="build"
CONTENTS="$OUT/$APP/Contents"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)"
DMG="$OUT/Tidier-$VERSION.dmg"
SDK="$(xcrun --show-sdk-path)"
FRAMEWORKS="-framework AppKit -framework SwiftUI -framework ServiceManagement -framework ApplicationServices -framework IOKit -framework CoreLocation"

rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "Compiling universal (arm64 + x86_64)…"
swiftc Sources/*.swift -o "$OUT/Tidier-arm64" -sdk "$SDK" -target arm64-apple-macos14.0  -swift-version 5 $FRAMEWORKS
swiftc Sources/*.swift -o "$OUT/Tidier-x86_64" -sdk "$SDK" -target x86_64-apple-macos14.0 -swift-version 5 $FRAMEWORKS
lipo -create "$OUT/Tidier-arm64" "$OUT/Tidier-x86_64" -output "$CONTENTS/MacOS/Tidier"
rm -f "$OUT/Tidier-arm64" "$OUT/Tidier-x86_64"
echo "  $(lipo -archs "$CONTENTS/MacOS/Tidier")"

cp Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp -R Resources/*.lproj "$CONTENTS/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$CONTENTS/Resources/"

# --- sign ---
DEVID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')
NOTARIZABLE=0
if [ -n "$DEVID" ]; then
  echo "Signing with Developer ID + hardened runtime: $DEVID"
  codesign --force --deep --options runtime --timestamp \
           --sign "$DEVID" --identifier de.csho.Tidier "$OUT/$APP"
  NOTARIZABLE=1
else
  SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Tidier Self-Signed/{print $2; exit}')
  if [ -n "$SIGN_HASH" ]; then
    echo "Signing self-signed (Tidier Self-Signed $SIGN_HASH) — NOT notarizable"
    codesign --force --deep --sign "$SIGN_HASH" --identifier de.csho.Tidier "$OUT/$APP"
  else
    echo "Signing ad-hoc — NOT notarizable"
    codesign --force --deep --sign - "$OUT/$APP"
  fi
fi

# --- DMG (drag-to-Applications layout) ---
echo "Building DMG…"
STAGE="$OUT/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$OUT/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Tidier $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "  $DMG"

# --- notarize + staple (only if Developer ID signed AND a profile is given) ---
if [ "$NOTARIZABLE" = "1" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "Notarizing via profile '$NOTARY_PROFILE' (this can take a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "Stapling…"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG" && echo "✓ notarized + stapled"
elif [ "$NOTARIZABLE" = "1" ]; then
  echo "⚠️  Developer-ID signed but NOTARY_PROFILE not set → DMG not notarized."
  echo "    Run again with: NOTARY_PROFILE=<profile> scripts/release.sh"
else
  echo "⚠️  No Developer ID cert → DMG is NOT notarized; Gatekeeper will block it on other Macs."
fi

echo "Done: $DMG"
