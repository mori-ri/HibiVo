#!/usr/bin/env bash
# Builds a release HibiVo.app and packages it for sharing:
#   build/HibiVo-<version>-<arch>.dmg   what people download: drag HibiVo.app onto the Applications link inside
#   build/HibiVo-<version>-<arch>.zip   kept for the update button of 0.7.0 and earlier, which links to the zip
#
# The zip is made with ditto so the code signature and extended attributes survive.
#
# A distributable package is signed with Developer ID, notarized and stapled, so recipients get no Gatekeeper
# warning, and is built from committed source only. Anything else stops with an error. Notarization needs
# a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials hibivo-notary --apple-id <Apple ID> --team-id <team ID>
# HIBIVO_NOTARY_PROFILE selects another profile.
#
# The app is notarized and stapled first, so the copy inside the disk image carries its own ticket and opens
# offline once it is in Applications. The disk image is then signed, notarized and stapled as well.
#
# NOTARIZE=0 is for trying a build locally: it allows any signature and uncommitted changes, skips
# notarization, and names the files HibiVo-<version>-<arch>-local.{dmg,zip} so they can't be mistaken for a release.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${HIBIVO_NOTARY_PROFILE:-hibivo-notary}"
NOTARIZE="${NOTARIZE:-1}"

if [[ "$NOTARIZE" != 0 && -n "$(git status --porcelain)" ]]; then
  echo "error: 作業ツリーに未コミットの変更があります。配布物はコミット済みのソースから作ってください (試すだけなら NOTARIZE=0)。" >&2
  exit 1
fi

CONFIG=release scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCH="$(uname -m)"
BASE="build/HibiVo-$VERSION-$ARCH"
[[ "$NOTARIZE" != 0 ]] || BASE="$BASE-local"
ZIP="$BASE.zip"
DMG="$BASE.dmg"
STAGE="build/dmg-stage"

make_zip() {
  rm -f "$1"
  ditto -c -k --keepParent build/HibiVo.app "$1"
}

# The volume holds the app and a link to /Applications, so installing is a single drag.
make_dmg() {
  rm -rf "$STAGE" "$1"
  mkdir -p "$STAGE"
  ditto build/HibiVo.app "$STAGE/HibiVo.app"
  ln -s /Applications "$STAGE/Applications"
  # hdiutil now and then fails with "Resource busy" while Spotlight or another process looks at the volume.
  local attempt
  for attempt in 1 2 3; do
    if hdiutil create -quiet -volname HibiVo -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$1"; then
      rm -rf "$STAGE"
      return 0
    fi
    echo "hdiutil create failed (attempt $attempt)." >&2
    sleep 2
  done
  echo "error: ディスクイメージを作成できませんでした。" >&2
  return 1
}

# Submits a file and waits for the verdict, printing the log when Apple turns it down.
notarize() {
  echo "Submitting $1 to the Apple notary service…"
  # Decide from the reported status: an Invalid submission is not a failure of the command itself.
  local result status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)" || {
    echo "error: 公証の送信に失敗しました。プロファイル $PROFILE は package.sh の先頭の手順で作成できます。" >&2
    return 1
  }
  status="$(plutil -extract status raw -o - - <<<"$result")"
  if [[ "$status" != Accepted ]]; then
    echo "error: 公証が通りませんでした ($1, status: $status)。" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$result")" --keychain-profile "$PROFILE" >&2 || true
    return 1
  fi
}

# After a failure, nothing with the release name may be left behind, nor any half-made intermediate.
SUBMISSION="$BASE-unnotarized.zip"
UNSTAPLED="$BASE-unnotarized.dmg"
CERTS="build/package-cert"
PACKAGED=0
cleanup() {
  rm -rf "$STAGE" "$SUBMISSION" "$UNSTAPLED" "$CERTS"*
  [[ "$PACKAGED" == 1 ]] || rm -f "$ZIP" "$DMG"
}
trap cleanup EXIT
rm -f "$ZIP" "$DMG"

codesign --verify --strict build/HibiVo.app
# Captured first: with pipefail, `codesign | grep -q` fails on SIGPIPE and would look like a missing signature.
SIGNATURE="$(codesign -dvv build/HibiVo.app 2>&1)"
# A release must never fall back to a signature users can't verify.
if [[ "$NOTARIZE" != 0 ]] && ! grep -q '^Authority=Developer ID Application: ' <<<"$SIGNATURE"; then
  echo "error: Developer ID で署名されていません。証明書を確認してください (試すだけなら NOTARIZE=0)。" >&2
  exit 1
fi

if [[ "$NOTARIZE" == 0 ]]; then
  make_zip "$ZIP"
  make_dmg "$DMG"
  echo "NOTARIZE=0: skipping notarization. These files are for local testing only."
else
  make_zip "$SUBMISSION"
  notarize "$SUBMISSION"
  xcrun stapler staple build/HibiVo.app
  spctl --assess --type execute --verbose build/HibiVo.app
  # The ticket lives in the bundle, so both packages are made only now, from the stapled app.
  make_zip "$ZIP"

  # The disk image is signed with the certificate that signed the app. It is named by its SHA-1, like
  # build-app.sh does, because the common name is ambiguous while a renewed certificate sits beside the old one.
  codesign -d --extract-certificates="$CERTS" build/HibiVo.app 2>/dev/null
  IDENTITY="$(shasum -a 1 "${CERTS}0" | awk '{ print toupper($1) }')"
  # Made under a temporary name and renamed once stapled, so a release-named image is always a finished one.
  make_dmg "$UNSTAPLED"
  codesign --force --timestamp --sign "$IDENTITY" "$UNSTAPLED"
  notarize "$UNSTAPLED"
  xcrun stapler staple "$UNSTAPLED"
  spctl --assess --type open --context context:primary-signature --verbose "$UNSTAPLED"
  mv "$UNSTAPLED" "$DMG"
fi

PACKAGED=1
echo "Packaged $DMG and $ZIP"
grep -E "^(Authority|Signature)=" <<<"$SIGNATURE" || true
