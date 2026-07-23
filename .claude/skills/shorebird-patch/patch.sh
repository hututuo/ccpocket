#!/usr/bin/env bash
# Create a signed CC Pocket OTA patch on the owner track.
# Usage: patch.sh <ios|android> <release-version> [flutter-build-args...]

set -Eeuo pipefail
export PATH="$HOME/.shorebird/bin:$PATH"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <ios|android> <release-version> [flutter-build-args...]" >&2
  exit 64
fi

PLATFORM="$1"
RELEASE_VERSION="$2"
shift 2

case "$PLATFORM" in
  ios|android) ;;
  *) echo "Platform must be ios or android." >&2; exit 64 ;;
esac

command -v shorebird >/dev/null || {
  echo "Shorebird CLI is not installed. Install/login before publishing." >&2
  exit 69
}

: "${CCPOCKET_SHOREBIRD_APP_ID:?Set CCPOCKET_SHOREBIRD_APP_ID to your personal Shorebird app_id.}"
: "${SHOREBIRD_PUBLIC_KEY_PATH:?Set SHOREBIRD_PUBLIC_KEY_PATH to the RSA public PEM.}"
: "${SHOREBIRD_PRIVATE_KEY_PATH:?Set SHOREBIRD_PRIVATE_KEY_PATH to the RSA private PEM.}"

for key_path in "$SHOREBIRD_PUBLIC_KEY_PATH" "$SHOREBIRD_PRIVATE_KEY_PATH"; do
  if [ ! -r "$key_path" ]; then
    echo "Signing key is not readable: $key_path" >&2
    exit 66
  fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../../../apps/mobile"
CONFIGURED_APP_ID="$(awk '/^[[:space:]]*app_id:/ {print $2; exit}' "$PROJECT_DIR/shorebird.yaml")"
if [ "$CONFIGURED_APP_ID" = "00000000-0000-0000-0000-000000000000" ]; then
  echo "Refusing to publish: run Shorebird init with the owner's personal account first." >&2
  exit 78
fi
if [ "$CONFIGURED_APP_ID" != "$CCPOCKET_SHOREBIRD_APP_ID" ]; then
  echo "Refusing to publish: shorebird.yaml is not configured for the expected personal app_id." >&2
  echo "Run Shorebird init for your account, then retry." >&2
  exit 78
fi

for arg in "$@"; do
  case "$arg" in
    *allow-native-diffs*|*allow-asset-diffs*)
      echo "Refusing unsafe patch flag: $arg" >&2
      echo "Native, dependency, entitlement, Flutter/Xcode, and asset changes require a new base IPA." >&2
      exit 64
      ;;
  esac
done

cd "$PROJECT_DIR"
echo "Creating signed $PLATFORM patch for $RELEASE_VERSION on owner."
echo "Native and asset differences are strict failures."

shorebird patch "$PLATFORM" \
  --release-version="$RELEASE_VERSION" \
  --track=owner \
  --public-key-path="$SHOREBIRD_PUBLIC_KEY_PATH" \
  --private-key-path="$SHOREBIRD_PRIVATE_KEY_PATH" \
  -- "$@"

echo "Patch published to owner only. Stable promotion still requires explicit confirmation."
