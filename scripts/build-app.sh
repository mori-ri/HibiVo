#!/usr/bin/env bash
# Builds HibiVo.app from the SwiftPM executable (no Xcode project required).
#
#   scripts/build-app.sh            # release build → build/HibiVo.app
#   CONFIG=debug scripts/build-app.sh
#
# Signing: uses HIBIVO_SIGN_IDENTITY, then a "Developer ID Application" certificate, then the
# "HibiVo Self-Signed" certificate created by scripts/create-signing-cert.sh, so macOS keeps the
# Accessibility permission across rebuilds. Otherwise the app is ad-hoc signed and the permission must
# be re-granted after every build (tccutil reset Accessibility io.github.mori-ri.hibivo).
#
# Developer ID builds use the hardened runtime, which notarization requires. Release builds also get a
# secure timestamp, which needs the network, so debug builds skip it.
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
# Localized strings. The Japanese text in code is the key, so ja.lproj/Localizable.strings is empty.
cp -R Resources/ja.lproj Resources/en.lproj "$APP/Contents/Resources/"
# The app is distributed without the repository, so its license, warranty disclaimer and the exception for
# the icon and logo (see README) travel with it.
{
  cat LICENSE
  printf '\nThe app icon and logo are not covered by the MIT License above; their copyright belongs to the author.\n'
} >"$APP/Contents/Resources/LICENSE.txt"

# Prefer an explicit identity, then Developer ID, then the certificate from create-signing-cert.sh, then ad-hoc.
# A failed lookup means ad-hoc signing, not a failed build.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
IDENTITY="${HIBIVO_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # The hash stays unambiguous when an expired and a renewed certificate share a name.
  IDENTITY="$(awk '/"Developer ID Application: / { print $2; exit }' <<<"$IDENTITIES")"
fi
if [[ -z "$IDENTITY" ]] && grep -qF '"HibiVo Self-Signed"' <<<"$IDENTITIES"; then
  IDENTITY="HibiVo Self-Signed"
fi
IDENTITY="${IDENTITY:--}"

SIGN_ARGS=(--force --sign "$IDENTITY" --identifier io.github.mori-ri.hibivo)
# No `grep -q` in these pipelines: it exits at the first match, and pipefail then reports the writer's SIGPIPE.
if [[ "$IDENTITY" != - ]] && grep -iF "$IDENTITY" <<<"$IDENTITIES" | grep -F '"Developer ID Application: ' >/dev/null; then
  # The hardened runtime blocks the microphone unless the entitlement is present.
  SIGN_ARGS+=(--options runtime --entitlements Resources/HibiVo.entitlements)
  if [[ "$CONFIG" == release ]]; then
    SIGN_ARGS+=(--timestamp)
  else
    SIGN_ARGS+=(--timestamp=none)
  fi
fi
codesign "${SIGN_ARGS[@]}" "$APP"
echo "Built $APP (signed with: $IDENTITY)"
