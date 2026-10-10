#!/usr/bin/env bash
#
# Build, package and (optionally) publish a release.
#
#   ./scripts/release.sh 1.0.0              build and package into ./dist
#   ./scripts/release.sh 1.0.0 --publish    ...then create the GitHub release (needs the `gh` CLI)
#
# Signing: pick one.
#
#   A) Developer ID + notarization (needs a paid Apple Developer account). Best for users:
#        export TEAM_ID=ABCDE12345
#        export SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
#        export NOTARY_PROFILE=pristine-notary
#      Create the notary profile once with:
#        xcrun notarytool store-credentials pristine-notary \
#            --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
#
#   B) No paid account: leave those variables unset. The app is ad-hoc signed, and
#      install.sh handles the rest on the user's Mac.
#
# Optional overrides: PROJECT, SCHEME, BUILD_NUMBER
#
set -euo pipefail

APP_NAME="Pristine"
ASSET_PREFIX="Pristine"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: $0 <version> [--publish]   (example: $0 1.0.0 --publish)"
VERSION="${VERSION#v}"
PUBLISH=0
if [ "${2:-}" = "--publish" ]; then PUBLISH=1; fi

cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || die "Xcode command line tools are required."

PROJECT="${PROJECT:-$(find . -maxdepth 1 -name '*.xcodeproj' | sed -n 1p)}"
[ -n "$PROJECT" ] || die "No .xcodeproj found in $(pwd). Run this from the repository root."
SCHEME="${SCHEME:-$(xcodebuild -list -project "$PROJECT" | sed -n '/Schemes:/,$p' | sed -n '2p' | sed 's/^[[:space:]]*//')}"
[ -n "$SCHEME" ] || die "Could not find a scheme. In Xcode: Product > Scheme > Manage Schemes, and tick Shared."
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

say "Project: $PROJECT   Scheme: $SCHEME   Version: $VERSION ($BUILD_NUMBER)"

if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null || die "Install the GitHub CLI first:  brew install gh && gh auth login"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "You have uncommitted changes. Commit and push them before publishing."
  fi
fi

BUILD="build"
DIST="dist"
rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

COMMON=(
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
)

# ---- Build ----------------------------------------------------------------

if [ -n "${SIGN_IDENTITY:-}" ]; then
  : "${TEAM_ID:?Set TEAM_ID (your 10-character Apple team ID) for Developer ID builds}"
  say "Building with Developer ID signing..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$BUILD/App.xcarchive" archive \
    "${COMMON[@]}" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES

  cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

  xcodebuild -exportArchive -archivePath "$BUILD/App.xcarchive" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" -exportPath "$BUILD/export"
  BUILT_APP="$(find "$BUILD/export" -maxdepth 1 -name '*.app' | sed -n 1p)"
else
  say "Building without a paid signing identity (ad-hoc signature)..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$BUILD/DerivedData" build \
    "${COMMON[@]}" CODE_SIGNING_ALLOWED=NO
  BUILT_APP="$(find "$BUILD/DerivedData/Build/Products/Release" -maxdepth 1 -name '*.app' | sed -n 1p)"
  codesign --force --deep --sign - "$BUILT_APP"
fi
[ -d "$BUILT_APP" ] || die "The build did not produce an app."

# The installer expects the bundle to be named exactly "$APP_NAME.app".
PKG="$BUILD/pkg"
mkdir -p "$PKG"
ditto "$BUILT_APP" "$PKG/$APP_NAME.app"
APP="$PKG/$APP_NAME.app"

# ---- Notarize -------------------------------------------------------------

if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  say "Notarizing (this can take a few minutes)..."
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
elif [ -n "${SIGN_IDENTITY:-}" ]; then
  say "Signed but NOT notarized (NOTARY_PROFILE is not set). Browser downloads will show a Gatekeeper warning."
fi

# ---- Package --------------------------------------------------------------

ZIP="$DIST/$ASSET_PREFIX-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
( cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
SHA="$(awk '{print $1}' "$ZIP.sha256")"

say "Built: $ZIP"
say "sha256: $SHA"

# ---- Publish --------------------------------------------------------------

if [ "$PUBLISH" = 1 ]; then
  say "Creating GitHub release v$VERSION..."
  gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" \
    --title "$APP_NAME $VERSION" --generate-notes
  say "Published. Anyone can now install it with install.sh."
else
  echo
  echo "Not published. To publish, run:  ./scripts/release.sh $VERSION --publish"
fi

echo
echo "Homebrew tap: set  version \"$VERSION\"  and  sha256 \"$SHA\"  in the cask file."
