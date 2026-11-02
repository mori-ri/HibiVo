#!/usr/bin/env bash
# Builds a release HibiVo.app and zips it for sharing: build/HibiVo-<version>-<arch>.zip
#
# The zip is made with ditto so the code signature and extended attributes survive.
#
# A distributable zip is signed with Developer ID, notarized and stapled, so recipients get no Gatekeeper
# warning, and is built from committed source only. Anything else stops with an error. Notarization needs
# a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials hibivo-notary --apple-id <Apple ID> --team-id <team ID>
# HIBIVO_NOTARY_PROFILE selects another profile.
#
# NOTARIZE=0 is for trying a build locally: it allows any signature and uncommitted changes, and names the
# zip HibiVo-<version>-<arch>-local.zip so it can't be mistaken for a release.
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
ZIP="build/HibiVo-$VERSION-$ARCH.zip"
[[ "$NOTARIZE" != 0 ]] || ZIP="build/HibiVo-$VERSION-$ARCH-local.zip"

make_zip() {
  rm -f "$ZIP"
  ditto -c -k --keepParent build/HibiVo.app "$ZIP"
}

codesign --verify --strict build/HibiVo.app
# Captured first: with pipefail, `codesign | grep -q` fails on SIGPIPE and would look like a missing signature.
SIGNATURE="$(codesign -dvv build/HibiVo.app 2>&1)"
# A release must never fall back to a signature users can't verify.
if [[ "$NOTARIZE" != 0 ]] && ! grep -q '^Authority=Developer ID Application: ' <<<"$SIGNATURE"; then
  echo "error: Developer ID で署名されていません。証明書を確認してください (試すだけなら NOTARIZE=0)。" >&2
  exit 1
fi
make_zip

if [[ "$NOTARIZE" == 0 ]]; then
  echo "NOTARIZE=0: skipping notarization. This zip is for local testing only."
else
  echo "Submitting to the Apple notary service…"
  # Decide from the reported status: an Invalid submission is not a failure of the command itself.
  RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)" || {
    echo "error: 公証の送信に失敗しました。プロファイル $PROFILE は package.sh の先頭の手順で作成できます。" >&2
    exit 1
  }
  STATUS="$(plutil -extract status raw -o - - <<<"$RESULT")"
  if [[ "$STATUS" != Accepted ]]; then
    echo "error: 公証が通りませんでした (status: $STATUS)。" >&2
    xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$RESULT")" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
  xcrun stapler staple build/HibiVo.app
  # The ticket lives in the bundle, so the zip has to be rebuilt to carry it.
  make_zip
  spctl --assess --type execute --verbose build/HibiVo.app
fi

echo "Packaged $ZIP"
codesign -dv build/HibiVo.app 2>&1 | grep -E "^(Authority|Signature)=" || true
