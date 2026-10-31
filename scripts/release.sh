#!/bin/zsh
# Prepares a new version for the in-app updater: ./scripts/release.sh 0.2
# - sets the version in Info.plist (and counts the build number up),
# - builds dist/proDOCKtivity.zip with scripts/package.sh (signed with "ArcSidebar Local Signing":
#   updates only install when they're signed with the same certificate as the copy people have),
# - says how to publish it. It never uploads anything itself.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.2>}"
PLIST=Resources/Info.plist
REPO="$(/usr/libexec/PlistBuddy -c 'Print :PDUpdateRepository' "$PLIST" 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"
security find-certificate -c "ArcSidebar Local Signing" >/dev/null 2>&1 || {
  echo "The signing certificate \"ArcSidebar Local Signing\" is missing: updates would not install. Stopping."; exit 1; }
./scripts/package.sh
echo
echo "Version $VERSION is in dist/proDOCKtivity.zip. Commit Info.plist, then publish:"
if [[ -z "$REPO" ]]; then
  echo "  (Set PDUpdateRepository in Resources/Info.plist to \"owner/repo\" first, then build again.)"
elif command -v gh >/dev/null; then
  echo "  gh release create v$VERSION dist/proDOCKtivity.zip --repo $REPO --title \"proDOCKtivity $VERSION\" --notes \"…\""
else
  echo "  https://github.com/$REPO/releases/new  → tag v$VERSION, attach dist/proDOCKtivity.zip, Publish."
fi
