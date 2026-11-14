#!/usr/bin/env bash
# Generates iOS/HibiVo.xcodeproj from iOS/project.yml with XcodeGen. Run it again after changing
# project.yml or adding files. See docs/ios.md.
#
# This script does not read scripts/env.sh: that pins the macOS SDK, and the iOS app needs Xcode's own.
set -euo pipefail
cd "$(dirname "$0")/../iOS"

if ! command -v xcodegen >/dev/null; then
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --spec project.yml

if [ ! -f Config/Signing.xcconfig ]; then
  echo
  echo "To run on an iPhone, copy iOS/Config/Signing.xcconfig.example to iOS/Config/Signing.xcconfig,"
  echo "put your team ID in it, and run this script again."
fi
echo "Open iOS/HibiVo.xcodeproj in Xcode and run the HibiVo scheme."
