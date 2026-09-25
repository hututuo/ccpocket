#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_bin="${CCPOCKET_FLUTTER:-/Users/huyiyang/.local/share/mise/installs/flutter/3.44.7/bin/flutter}"
manifest="$repo_root/test-fixtures/conversation-chain/real-rollout.manifest.json"
rollout_path="${CCPOCKET_REAL_ROLLOUT:-$(/usr/bin/jq -r '.sourcePathHint' "$manifest")}"

cd "$repo_root"
npm run bridge:build

real_chain_mode="${CCPOCKET_REAL_CHAIN:-auto}"
if [[ "$real_chain_mode" == "1" || \
      ( "$real_chain_mode" == "auto" && -r "$rollout_path" ) ]]; then
  (
    cd packages/bridge
    CCPOCKET_REAL_CHAIN=1 \
      CCPOCKET_REAL_ROLLOUT="$rollout_path" \
      npx vitest run src/blackbox/conversation-real-rollout.test.ts
  )
elif [[ "$real_chain_mode" == "0" ]]; then
  echo "Skipping the machine-local rollout chain by explicit request (CCPOCKET_REAL_CHAIN=0)."
else
  echo "BLOCKED: the machine-local rollout chain is required, but the frozen source is unavailable: $rollout_path" >&2
  echo "Set CCPOCKET_REAL_CHAIN=0 only when intentionally running the non-rollout receiver subset." >&2
  exit 2
fi

(
  cd apps/mobile
  "$flutter_bin" test --no-pub \
    test/blackbox/conversation_protocol_chain_test.dart \
    test/blackbox/conversation_real_bridge_chain_test.dart \
    test/blackbox/conversation_live_segment_receiver_test.dart \
    test/blackbox/conversation_latest_turn_gap_receiver_test.dart
)

echo "Receiver traces:"
ls -1dt /private/tmp/ccpocket-chain/* 2>/dev/null | head -5 || true
