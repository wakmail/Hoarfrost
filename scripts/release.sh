#!/bin/zsh
# Builds, signs, packages, and publishes a Hoarfrost release.
#
#   scripts/release.sh 0.2.0
#
# Needs: Xcode, the Developer ID certificate in the login keychain, the
# Sparkle EdDSA key in the keychain (generate_keys), and gh logged in.
# Publishes Hoarfrost_<v>.dmg, Hoarfrost_<v>.zip, and appcast.xml as
# assets of release v<v>. The app's Sparkle feed reads the appcast from
# the latest release, so publishing here is what ships the update.
set -euo pipefail
VERSION=${1:?usage: release.sh <version>}
IDENTITY="Developer ID Application: Youli Hui (KYTBGS96P8)"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
DD="$WORK/dd"

echo "Building $VERSION"
xcodebuild -project "$ROOT/Thaw.xcodeproj" -scheme Thaw -configuration Release \
  -derivedDataPath "$DD" MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build | tail -1

APP="$DD/Build/Products/Release/Hoarfrost.app"
codesign --force --deep --options runtime --timestamp \
  --preserve-metadata=entitlements,requirements,flags --sign "$IDENTITY" "$APP"
codesign -v --deep --strict "$APP"

STAGE="$WORK/stage"; mkdir "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
DMG="$WORK/Hoarfrost_$VERSION.dmg"
hdiutil create -volname "Hoarfrost" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
ZIP="$WORK/Hoarfrost_$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

SPARKLE=$(find "$DD/SourcePackages/artifacts" -type d -name bin -path '*parkle*' | head -1)
CAST="$WORK/cast"; mkdir "$CAST"; cp "$DMG" "$CAST/"
"$SPARKLE/generate_appcast" --account Hoarfrost \
  --download-url-prefix "https://github.com/wakmail/Hoarfrost/releases/download/v$VERSION/" \
  "$CAST"

git -C "$ROOT" tag "v$VERSION" 2>/dev/null || true
git -C "$ROOT" push -q origin "v$VERSION"
gh release create "v$VERSION" --title "Hoarfrost $VERSION" --generate-notes || true
gh release upload "v$VERSION" "$DMG" "$ZIP" "$CAST/appcast.xml" --clobber
echo "Published v$VERSION"
