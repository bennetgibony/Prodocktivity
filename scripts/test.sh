#!/bin/zsh
# Runs the tests. Works with only the Command Line Tools installed (no Xcode): the Testing
# framework lives there but isn't on the default search paths.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sdk.sh
DEV=/Library/Developer/CommandLineTools/Library/Developer
# With Xcode selected, plain `swift test` finds it by itself.
[[ "$(xcode-select -p)" == *Xcode* ]] && exec swift test "$@"
# Newer Command Line Tools keep the Testing macros in a folder of their own.
PLUGINS=()
TM="$CLT/usr/lib/swift/host/plugins/testing"
[[ -e "$TM/libTestingMacros.dylib" ]] && PLUGINS=(-Xswiftc -plugin-path -Xswiftc "$TM")
swift test "${PLUGINS[@]}" -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -F -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
