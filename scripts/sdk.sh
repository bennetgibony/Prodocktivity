# Sourced by the build and test scripts. The macOS 27 SDK of the Command Line Tools turns
# SwiftUI's @State into a macro whose plugin only Xcode ships; without Xcode, build against
# the newest macOS 26 SDK instead (the deployment target stays as Package.swift says).
CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" != *Xcode* && ! -e "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
  OLD_SDK="$(ls -d "$CLT"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
  [[ -n "$OLD_SDK" ]] && export SDKROOT="$OLD_SDK"
fi
