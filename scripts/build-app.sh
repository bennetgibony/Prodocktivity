#!/bin/zsh
# Builds build/proDOCKtivity.app and installs it to /Applications (pass --no-install to skip).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sdk.sh

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ArcSidebar"

APP=build/proDOCKtivity.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ArcSidebar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
[[ -f "Resources/Setup Guide.html" ]] && cp "Resources/Setup Guide.html" "$APP/Contents/Resources/"
# A premade setup for the setup tour's Quick setup (a setupNA file), if one is there.
[[ -f Resources/Premade.pdsetup ]] && cp Resources/Premade.pdsetup "$APP/Contents/Resources/"
# Translations from the String Catalog (English, the source language, is in the code).
python3 scripts/strings.py compile "$APP/Contents/Resources" >/dev/null

# A stable signing identity keeps macOS permissions (Accessibility etc.) across rebuilds.
# Create it once in Keychain Access → Certificate Assistant → Create a Certificate…
# (name "ArcSidebar Local Signing", type "Code Signing"). Falls back to ad-hoc signing.
IDENTITY="ArcSidebar Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && \
   codesign --force --sign "$IDENTITY" --identifier com.bennetgibony.ArcSidebar "$APP" 2>/dev/null; then
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - --identifier com.bennetgibony.ArcSidebar "$APP"
    echo "Signed ad-hoc (macOS will ask for permissions again after this build)"
fi
echo "Built $APP"

# Install into /Applications so it's easy to find (Accessibility list, Spotlight, Finder).
if [[ "${1:-}" != "--no-install" ]]; then
    pkill -f "/Applications/proDOCKtivity.app/Contents/MacOS" 2>/dev/null || true
    # Opening while the old copy is still quitting fails (error -600): wait for it to be gone.
    for _ in {1..20}; do pgrep -f "/Applications/proDOCKtivity.app/Contents/MacOS" >/dev/null || break; sleep 0.25; done
    rm -rf /Applications/proDOCKtivity.app
    cp -R "$APP" /Applications/proDOCKtivity.app
    echo "Installed /Applications/proDOCKtivity.app"
    # Launch Services sometimes isn't ready for the fresh copy yet (error -600): try a few times.
    for _ in {1..5}; do open /Applications/proDOCKtivity.app 2>/dev/null && break; sleep 1; done
fi
