#!/usr/bin/env bash
# Runs the test suite.
#
# With only the Command Line Tools installed, the swift-testing macro plugin sometimes fails to
# load on the first compile after test files change ("plugin for module 'TestingMacros' not
# found"). Rebuilding succeeds, so retry the build a few times before giving up.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
for attempt in 1 2 3; do
  if swift build --build-tests >/dev/null 2>&1; then break; fi
  if [[ $attempt == 3 ]]; then swift build --build-tests; exit 1; fi
done
swift test --skip-build "$@"
