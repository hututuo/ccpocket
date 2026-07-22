#!/usr/bin/env bash
# Create a signed base release. Native/asset/dependency changes use this path.
# Usage: release.sh <ios|android> [shorebird-release-args...]

set -Eeuo pipefail
export PATH="$HOME/.shorebird/bin:$PATH"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <ios|android> [shorebird-release-args...]" >&2
  exit 64
fi

PLATFORM="$1"
shift
case "$PLATFORM" in
  ios|android) ;;
  *) echo "Platform must be ios or android." >&2; exit 64 ;;
esac

command -v shorebird >/dev/null || {
  echo "Shorebird CLI is not installed. Install/login before releasing." >&2
  exit 69
}
: "${CCPOCKET_SHOREBIRD_APP_ID:?Set CCPOCKET_SHOREBIRD_APP_ID to your personal Shorebird app_id.}"
: "${SHOREBIRD_PUBLIC_KEY_PATH:?Set SHOREBIRD_PUBLIC_KEY_PATH to the RSA public PEM.}"
[ -r "$SHOREBIRD_PUBLIC_KEY_PATH" ] || {
  echo "Public signing key is not readable: $SHOREBIRD_PUBLIC_KEY_PATH" >&2
  exit 66
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../../../apps/mobile"
CONFIGURED_APP_ID="$(awk '/^[[:space:]]*app_id:/ {print $2; exit}' "$PROJECT_DIR/shorebird.yaml")"
if [ "$CONFIGURED_APP_ID" = "00000000-0000-0000-0000-000000000000" ]; then
  echo "Refusing to release: run Shorebird init with the owner's personal account first." >&2
  exit 78
fi
if [ "$CONFIGURED_APP_ID" != "$CCPOCKET_SHOREBIRD_APP_ID" ]; then
  echo "Refusing to release from an unexpected Shorebird app_id." >&2
  exit 78
fi

cd "$PROJECT_DIR"
shorebird release "$PLATFORM" \
  --public-key-path="$SHOREBIRD_PUBLIC_KEY_PATH" \
  "$@"

echo "Signed base release created. Install the generated IPA before publishing patches for it."
