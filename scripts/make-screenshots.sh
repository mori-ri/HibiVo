#!/usr/bin/env bash
# Renders the landing page images into the given directory (default: site/assets/screens).
# The app's data points at an empty temporary home, so only the sample data in
# Sources/HibiVoScreenshots appears, never the data of whoever runs this.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

OUT="${1:-site/assets/screens}"
swift build --product HibiVoScreenshots >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
# The tool isn't a bundle: strings are found next to the executable.
for LPROJ in en ja; do
  rm -rf "$BIN_DIR/$LPROJ.lproj"
  cp -R "Resources/$LPROJ.lproj" "$BIN_DIR/$LPROJ.lproj"
done

for LANGUAGE in ja en; do
  HOME_DIR="$(mktemp -d)"
  CFFIXED_USER_HOME="$HOME_DIR" "$BIN_DIR/HibiVoScreenshots" "$LANGUAGE" "$OUT" -AppleLanguages "($LANGUAGE)" \
    -AppleLocale "$([[ $LANGUAGE == ja ]] && echo ja_JP || echo en_US)"
  rm -rf "$HOME_DIR"
done
defaults delete HibiVoScreenshots 2>/dev/null || true
rm -f "$HOME/Library/Preferences/HibiVoScreenshots.plist"
