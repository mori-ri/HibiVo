#!/usr/bin/env bash
# Builds a release HibiVo.app and zips it for sharing: build/HibiVo-<version>-<arch>.zip
#
# The zip is made with ditto so the code signature and extended attributes survive.
# Recipients will see a Gatekeeper warning because the app is not notarized; see README.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCH="$(uname -m)"
ZIP="build/HibiVo-$VERSION-$ARCH.zip"

codesign --verify --strict build/HibiVo.app
rm -f "$ZIP"
ditto -c -k --keepParent build/HibiVo.app "$ZIP"

echo "Packaged $ZIP"
codesign -dv build/HibiVo.app 2>&1 | grep -E "^(Authority|Signature)=" || true
