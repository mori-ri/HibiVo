# Sourced by the other scripts.
#
# With only the Command Line Tools installed, the macOS 27 SDK declares SwiftUI's @State as a macro
# whose compiler plugin ships only with Xcode. Build against the macOS 26 SDK in that case.
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  SDK26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
  if [[ -z "${SDKROOT:-}" && -d "$SDK26" ]]; then
    export SDKROOT="$SDK26"
  fi
fi
