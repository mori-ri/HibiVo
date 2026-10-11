#!/usr/bin/env bash
# Builds HibiVo.app from the SwiftPM executable (no Xcode project required).
#
#   scripts/build-app.sh            # release build → build/HibiVo.app
#   CONFIG=debug scripts/build-app.sh
#
# Signing: uses HIBIVO_SIGN_IDENTITY, or the "HibiVo Self-Signed" certificate created by
# scripts/create-signing-cert.sh, so macOS keeps the Accessibility permission across rebuilds.
# Otherwise the app is ad-hoc signed and the permission must be re-granted after every build
# (tccutil reset Accessibility io.github.mori-ri.hibivo).
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh
CONFIG="${CONFIG:-release}"
APP="build/HibiVo.app"

swift build -c "$CONFIG" --product HibiVo
BIN="$(swift build -c "$CONFIG" --show-bin-path)/HibiVo"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HibiVo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Logo.png Resources/Logo@2x.png Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
# Localized strings. The Japanese text in code is the key, so ja.lproj only holds InfoPlist.strings.
cp -R Resources/ja.lproj Resources/en.lproj "$APP/Contents/Resources/"

# Prefer an explicit identity, then the certificate from create-signing-cert.sh, then ad-hoc.
IDENTITY="${HIBIVO_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -qF '"HibiVo Self-Signed"'; then
  IDENTITY="HibiVo Self-Signed"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier io.github.mori-ri.hibivo "$APP"
echo "Built $APP (signed with: $IDENTITY)"
