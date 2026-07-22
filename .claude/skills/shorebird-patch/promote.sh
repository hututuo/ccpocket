#!/usr/bin/env bash
# Promote one verified owner patch to stable.
# Usage: promote.sh <release-version> <patch-number> --confirm-stable

set -Eeuo pipefail
export PATH="$HOME/.shorebird/bin:$PATH"

if [ "$#" -ne 3 ] || [ "$3" != "--confirm-stable" ]; then
  echo "Usage: $0 <release-version> <patch-number> --confirm-stable" >&2
  echo "The confirmation flag is required because this affects every stable device." >&2
  exit 64
fi

RELEASE_VERSION="$1"
PATCH_NUMBER="$2"
: "${CCPOCKET_SHOREBIRD_APP_ID:?Set CCPOCKET_SHOREBIRD_APP_ID to your personal Shorebird app_id.}"
command -v shorebird >/dev/null || {
  echo "Shorebird CLI is not installed." >&2
  exit 69
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../../../apps/mobile"
CONFIGURED_APP_ID="$(awk '/^[[:space:]]*app_id:/ {print $2; exit}' "$PROJECT_DIR/shorebird.yaml")"
if [ "$CONFIGURED_APP_ID" = "00000000-0000-0000-0000-000000000000" ]; then
  echo "Refusing to promote: run Shorebird init with the owner's personal account first." >&2
  exit 78
fi
if [ "$CONFIGURED_APP_ID" != "$CCPOCKET_SHOREBIRD_APP_ID" ]; then
  echo "Refusing to promote from an unexpected Shorebird app_id." >&2
  exit 78
fi

cd "$PROJECT_DIR"
shorebird patches set-track \
  --release-version="$RELEASE_VERSION" \
  --patch-number="$PATCH_NUMBER" \
  --track=stable

echo "Patch $PATCH_NUMBER is now on stable."
