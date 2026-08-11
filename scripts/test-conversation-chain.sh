#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_bin="${CCPOCKET_FLUTTER:-/Users/huyiyang/.local/share/mise/installs/flutter/3.44.7/bin/flutter}"
manifest="$repo_root/test-fixtures/conversation-chain/real-rollout.manifest.json"
rollout_path="${CCPOCKET_REAL_ROLLOUT:-$(/usr/bin/jq -r '.sourcePathHint' "$manifest")}"

cd "$repo_root"
npm run bridge:build

if [[ "${CCPOCKET_REAL_CHAIN:-auto}" == "1" || \
      ( "${CCPOCKET_REAL_CHAIN:-auto}" == "auto" && -r "$rollout_path" ) ]]; then
  (
    cd packages/bridge
    CCPOCKET_REAL_CHAIN=1 \
      CCPOCKET_REAL_ROLLOUT="$rollout_path" \
      npx vitest run src/blackbox/conversation-real-rollout.test.ts
  )
else
  echo "Skipping the machine-local rollout chain: frozen source is unavailable."
fi

(
  cd apps/mobile
  "$flutter_bin" test --no-pub \
    test/blackbox/conversation_protocol_chain_test.dart \
    test/blackbox/conversation_real_bridge_chain_test.dart
)

echo "Receiver traces:"
ls -1dt /private/tmp/ccpocket-chain/* 2>/dev/null | head -5 || true
