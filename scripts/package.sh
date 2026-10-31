#!/bin/zsh
# Makes dist/proDOCKtivity.zip, the release download.
# - Neutral app id (no personal name), signed with the local certificate.
# - Contains only the app: no spaces, pins, ideas or settings (those live in each user's own Library).
# - Fails if anything personal (home folder paths, your name) is found inside the app.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/make-guide.py
./scripts/build-app.sh --no-install

DIST=dist
rm -rf "$DIST" && mkdir -p "$DIST"
APP="$DIST/proDOCKtivity.app"
cp -R build/proDOCKtivity.app "$APP"

SHARE_ID="app.prodocktivity.sidebar"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SHARE_ID" "$APP/Contents/Info.plist"
# Remove debug info (it contains this Mac's file paths).
codesign --remove-signature "$APP/Contents/MacOS/ArcSidebar"
strip -S -x "$APP/Contents/MacOS/ArcSidebar"
xattr -cr "$APP"
if security find-certificate -c "ArcSidebar Local Signing" >/dev/null 2>&1; then
  codesign --force --sign "ArcSidebar Local Signing" --identifier "$SHARE_ID" "$APP"
else
  codesign --force --sign - --identifier "$SHARE_ID" "$APP"
fi

# Privacy check: only the feedback address may mention you.
ME="$(id -un)"
# The update repository's owner (PDUpdateRepository, e.g. "owner/prodocktivity") is public on purpose.
OWNER="$(/usr/libexec/PlistBuddy -c 'Print :PDUpdateRepository' "$APP/Contents/Info.plist" 2>/dev/null | cut -d/ -f1)"
FOUND="$(LC_ALL=C grep -r -a -o -i -e "/Users/[A-Za-z0-9._-]*" -e "[[:alnum:]._-]*${ME}[[:alnum:]@._-]*" "$APP" | grep -v -i -x ".*:prodocktivity@bennet-gibony.com" | grep -v -x ".*/Info.plist:${OWNER:-__none__}" | sort -u || true)"
if [[ -n "$FOUND" ]]; then
  echo "Personal data found in the app, not packaging:"; echo "$FOUND"; exit 1
fi
echo "Privacy check passed (only the ideas email address is included)."

# One folder with everything, and the same folder as a single ZIP to send.
FOLDER="$DIST/proDOCKtivity"
mkdir -p "$FOLDER"
mv "$APP" "$FOLDER/proDOCKtivity.app"
cp "Resources/Setup Guide.html" "$FOLDER/Setup Guide.html"
cp "Resources/What's New.html" "$FOLDER/What's New.html"
xattr -cr "$FOLDER"
ditto -c -k --norsrc --keepParent "$FOLDER" "$DIST/proDOCKtivity.zip"
echo "Ready: $FOLDER/ (app, setup guide, what's new) and the same as $DIST/proDOCKtivity.zip"
