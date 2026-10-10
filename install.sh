#!/usr/bin/env bash
#
# Pristine - installer
#
#   curl -fsSL https://raw.githubusercontent.com/PcMac24x7/pristine/main/install.sh | bash
#
# Extra options go after `bash -s --`, for example:
#   curl -fsSL <url> | bash -s -- --version 1.0.0
#   curl -fsSL <url> | bash -s -- --uninstall
#
set -euo pipefail

REPO="PcMac24x7/pristine"
APP_NAME="Pristine"
ASSET_PREFIX="Pristine"

VERSION=""
DEST="/Applications"
UNINSTALL=0

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [options]

  --version X.Y.Z   install a specific version instead of the latest
  --dest DIR        install into DIR instead of /Applications
  --uninstall       remove the app and its saved settings
  -h, --help        show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   [ $# -ge 2 ] || die "--version needs a value"; VERSION="${2#v}"; shift 2 ;;
    --dest)      [ $# -ge 2 ] || die "--dest needs a folder";   DEST="${2%/}";    shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "unknown option: $1" ;;
  esac
done

# ---- Checks ---------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "$APP_NAME is for macOS only."
macos_version="$(sw_vers -productVersion)"
[ "${macos_version%%.*}" -ge 14 ] || die "macOS 14 (Sonoma) or newer is required. You have $macos_version."

target="$DEST/$APP_NAME.app"

# Use sudo only if we can't write to the destination as the current user.
SUDO=""
if [ -d "$DEST" ]; then
  [ -w "$DEST" ] || SUDO="sudo"
else
  mkdir -p "$DEST" 2>/dev/null || SUDO="sudo"
fi
if [ -e "$target" ] && [ ! -w "$target" ]; then SUDO="sudo"; fi

quit_app() {
  if pgrep -f "$APP_NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
    say "Closing $APP_NAME..."
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8; do
      pgrep -f "$APP_NAME.app/Contents/MacOS/" >/dev/null 2>&1 || return 0
      sleep 1
    done
    die "$APP_NAME is still running. Quit it and run this again."
  fi
}

# ---- Uninstall ------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
  [ -d "$target" ] || die "$target was not found."
  bundle_id="$(defaults read "$target/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  quit_app
  [ -z "$SUDO" ] || say "Administrator permission is needed to remove the app."
  $SUDO rm -rf "$target"
  if [ -n "$bundle_id" ]; then defaults delete "$bundle_id" >/dev/null 2>&1 || true; fi
  say "Removed $APP_NAME."
  echo "Any backups it made were left in ~/Documents/Pristine Backups."
  echo "You can also remove its Full Disk Access entry in System Settings > Privacy & Security."
  exit 0
fi

# ---- Find the version -----------------------------------------------------

if [ -z "$VERSION" ]; then
  say "Looking up the latest release..."
  final_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
    || die "Could not reach GitHub."
  tag="${final_url##*/}"
  case "$tag" in
    ""|latest|releases) die "No release has been published yet: https://github.com/$REPO/releases" ;;
  esac
  VERSION="${tag#v}"
fi

asset="$ASSET_PREFIX-$VERSION.zip"
base="https://github.com/$REPO/releases/download/v$VERSION"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- Download and verify --------------------------------------------------

say "Downloading $APP_NAME $VERSION..."
curl -fL --progress-bar -o "$tmp/$asset" "$base/$asset" \
  || die "Download failed. Check that version $VERSION exists: https://github.com/$REPO/releases"
curl -fsSL -o "$tmp/$asset.sha256" "$base/$asset.sha256" \
  || die "Could not download the checksum file."

expected="$(awk '{print $1}' "$tmp/$asset.sha256")"
actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] \
  || die "Checksum mismatch. The download is damaged, so nothing was installed."
say "Checksum verified."

# ---- Install --------------------------------------------------------------

say "Unpacking..."
ditto -x -k "$tmp/$asset" "$tmp/unpacked"
src="$tmp/unpacked/$APP_NAME.app"
[ -d "$src" ] || die "The download did not contain $APP_NAME.app."

quit_app
[ -z "$SUDO" ] || say "Administrator permission is needed to write to $DEST."
$SUDO mkdir -p "$DEST"
if [ -e "$target" ]; then $SUDO rm -rf "$target"; fi
$SUDO ditto "$src" "$target"

# Files fetched with curl are not quarantined, but clear the flag in case it was set.
$SUDO xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

# Releases are signed. If the signature can't be verified, apply a local one so the app can launch.
if ! codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
  warn "The app's signature could not be verified. Applying a local signature."
  $SUDO codesign --force --deep --sign - "$target" >/dev/null 2>&1 || warn "Local signing failed."
fi

say "Installed $APP_NAME $VERSION to $target"
cat <<EOF

Next steps
  1. Open the app:
       open -a "$APP_NAME"
  2. Allow it to read browser data, which it needs to clear Safari and other browsers:
       System Settings > Privacy & Security > Full Disk Access > turn on "$APP_NAME"
     Then quit and reopen the app.

To remove it later:
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --uninstall
EOF
