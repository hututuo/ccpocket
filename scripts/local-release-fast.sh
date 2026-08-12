#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_bin="${CCPOCKET_FLUTTER:-/Users/huyiyang/.local/share/mise/installs/flutter/3.44.7/bin/flutter}"
cache_root="${CCPOCKET_FAST_RELEASE_CACHE:-$HOME/Library/Caches/CCPocketLocalRelease}"
bridge_plist="${CCPOCKET_BRIDGE_PLIST:-$HOME/Library/LaunchAgents/com.ccpocket.bridge.plist}"

usage() {
  cat <<'EOF'
Usage:
  scripts/local-release-fast.sh plan --base <git-ref> [--json]
  scripts/local-release-fast.sh gate --base <git-ref> [--force] [--dry-run]
  scripts/local-release-fast.sh bridge-runtime --base <git-ref> [--runtime-name <name>] [--dry-run]
  scripts/local-release-fast.sh ipa --base <git-ref> --build-number <n> [--output <path>] [--dry-run]

The fast lane is deliberately local-only. It never pushes, tags, publishes stable,
changes the LaunchAgent, switches production Bridge, or installs an IPA.

Stages are cached by exact source/product/lock/toolchain fingerprint. A matching
successful stage is reused; --force invalidates only the requested stage.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

command_name="${1:-}"
if [[ -z "$command_name" || "$command_name" == "-h" || "$command_name" == "--help" ]]; then
  usage
  exit 0
fi
shift

base=""
json_output=0
force=0
dry_run=0
runtime_name=""
build_number=""
output_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || die "--base requires a value"
      base="$2"
      shift 2
      ;;
    --json)
      json_output=1
      shift
      ;;
    --force)
      force=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --runtime-name)
      [[ $# -ge 2 ]] || die "--runtime-name requires a value"
      runtime_name="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || die "--build-number requires a value"
      build_number="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      output_path="$2"
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$command_name" in
  plan|gate|bridge-runtime|ipa) ;;
  *) die "unknown command: $command_name" ;;
esac

[[ -n "$base" ]] || die "--base is required"

need git
need jq
need shasum

cd "$repo_root"
head_sha="$(git rev-parse HEAD)"
base_sha="$(git rev-parse "$base^{commit}")"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "detached HEAD is not allowed for local release"

status="$(git status --porcelain)"
[[ -z "$status" ]] || die "worktree is not clean"

changed_file="$(mktemp /private/tmp/ccpocket-fast-release-paths.XXXXXX)"
trap 'rm -f "$changed_file"' EXIT
git diff --name-only "$base_sha..$head_sha" > "$changed_file"

bridge_changed=0
mobile_changed=0
mobile_native_changed=0
cloud_changed=0
test_or_docs_changed=0

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    packages/bridge/*|package-lock.json)
      bridge_changed=1
      ;;
    apps/mobile/ios/*|apps/mobile/android/*|apps/mobile/macos/*|apps/mobile/windows/*|apps/mobile/linux/*|apps/mobile/assets/*|apps/mobile/pubspec.yaml|apps/mobile/pubspec.lock)
      mobile_changed=1
      mobile_native_changed=1
      ;;
    apps/mobile/lib/*)
      mobile_changed=1
      ;;
    functions/*)
      cloud_changed=1
      ;;
    package.json|apps/mobile/test/*|test-fixtures/*|scripts/test-*|docs/*|notes/*|reviews/*|plans/*)
      test_or_docs_changed=1
      ;;
  esac
done < "$changed_file"

bridge_tree="$(git rev-parse "$head_sha:packages/bridge")"
mobile_tree="$(git rev-parse "$head_sha:apps/mobile")"
root_lock="$(git rev-parse "$head_sha:package-lock.json")"
mobile_lock="$(git rev-parse "$head_sha:apps/mobile/pubspec.lock")"

node_version="not-used"
flutter_version="not-used"
if [[ "$bridge_changed" == "1" ]]; then
  need node
  node_version="$(node --version)"
fi
if [[ "$mobile_changed" == "1" ]]; then
  [[ -x "$flutter_bin" ]] || die "Flutter is not executable: $flutter_bin"
  flutter_root="$(cd "$(dirname "$flutter_bin")/.." && pwd)"
  flutter_version_file="$flutter_root/bin/cache/flutter.version.json"
  [[ -r "$flutter_version_file" ]] || die "Flutter version metadata is unavailable: $flutter_version_file"
  flutter_version="$(jq -r '.frameworkVersion + ":" + .frameworkRevision' "$flutter_version_file")"
fi

fingerprint="$({
  printf '%s\n' "$head_sha" "$bridge_tree" "$mobile_tree" "$root_lock" "$mobile_lock"
  printf '%s\n' "$node_version" "$flutter_version"
} | shasum -a 256 | awk '{print $1}')"
bridge_fingerprint="$({
  printf '%s\n' "$bridge_tree" "$root_lock" "$node_version"
} | shasum -a 256 | awk '{print $1}')"
mobile_fingerprint="$({
  printf '%s\n' "$mobile_tree" "$mobile_lock" "$flutter_version"
} | shasum -a 256 | awk '{print $1}')"
chain_script_blob="$(git rev-parse "$head_sha:scripts/test-conversation-chain.sh" 2>/dev/null || echo missing)"
chain_fingerprint="$({
  printf '%s\n' "$bridge_tree" "$mobile_tree" "$root_lock" "$mobile_lock"
  printf '%s\n' "$node_version" "$flutter_version" "$chain_script_blob"
} | shasum -a 256 | awk '{print $1}')"
stage_dir="$cache_root/release/$fingerprint"
bridge_stage_dir="$cache_root/bridge/$bridge_fingerprint"
mobile_stage_dir="$cache_root/mobile/$mobile_fingerprint"
chain_stage_dir="$cache_root/conversation-chain/$chain_fingerprint"
plan_json="$stage_dir/plan.json"
gate_json="$stage_dir/source-gates.json"
bridge_gate_json="$bridge_stage_dir/build.json"
bridge_dist_zip="$bridge_stage_dir/bridge-dist.zip"
mobile_gate_json="$mobile_stage_dir/analyze.json"
chain_gate_json="$chain_stage_dir/chain.json"

make_plan_json() {
  mkdir -p "$stage_dir"
  jq -n \
    --arg head "$head_sha" \
    --arg base "$base_sha" \
    --arg branch "$branch" \
    --arg fingerprint "$fingerprint" \
    --arg bridgeFingerprint "$bridge_fingerprint" \
    --arg mobileFingerprint "$mobile_fingerprint" \
    --arg chainFingerprint "$chain_fingerprint" \
    --arg bridgeTree "$bridge_tree" \
    --arg mobileTree "$mobile_tree" \
    --arg rootLock "$root_lock" \
    --arg mobileLock "$mobile_lock" \
    --arg node "$node_version" \
    --arg flutter "$flutter_version" \
    --argjson bridgeChanged "$bridge_changed" \
    --argjson mobileChanged "$mobile_changed" \
    --argjson mobileNativeChanged "$mobile_native_changed" \
    --argjson cloudChanged "$cloud_changed" \
    --argjson testOrDocsChanged "$test_or_docs_changed" \
    --slurpfile changed <(jq -R -s 'split("\n") | map(select(length > 0))' "$changed_file") \
    '{
      schemaVersion: 1,
      source: {head: $head, base: $base, branch: $branch, clean: true},
      fingerprint: $fingerprint,
      stageFingerprints: {
        bridge: $bridgeFingerprint,
        mobile: $mobileFingerprint,
        conversationChain: $chainFingerprint
      },
      inputs: {
        bridgeTree: $bridgeTree,
        mobileTree: $mobileTree,
        rootLock: $rootLock,
        mobileLock: $mobileLock,
        node: $node,
        flutter: $flutter
      },
      changes: {
        bridge: ($bridgeChanged == 1),
        mobile: ($mobileChanged == 1),
        mobileNativeOrDependency: ($mobileNativeChanged == 1),
        cloud: ($cloudChanged == 1),
        testsOrDocs: ($testOrDocsChanged == 1),
        paths: $changed[0]
      },
      route: {
        bridgeRuntime: ($bridgeChanged == 1),
        ownerOtaEligibleByTree: (($mobileChanged == 1) and ($mobileNativeChanged == 0)),
        ipa: (($mobileChanged == 1) and ($mobileNativeChanged == 1)),
        cloud: ($cloudChanged == 1)
      }
    }' > "$plan_json"
}

make_plan_json

print_plan() {
  if [[ "$json_output" == "1" ]]; then
    cat "$plan_json"
    return
  fi
  echo "CC Pocket local release plan"
  echo "  source: $branch@$head_sha"
  echo "  base:   $base_sha"
  echo "  fingerprint: $fingerprint"
  echo "  Bridge fingerprint: $bridge_fingerprint"
  echo "  Mobile fingerprint: $mobile_fingerprint"
  echo "  Chain fingerprint:  $chain_fingerprint"
  echo "  Bridge changed: $bridge_changed"
  echo "  Mobile changed: $mobile_changed (native/dependency: $mobile_native_changed)"
  echo "  Cloud changed:  $cloud_changed"
  echo "  changed paths:  $(wc -l < "$changed_file" | tr -d ' ')"
  echo "  cached plan:    $plan_json"
}

if [[ "$command_name" == "plan" ]]; then
  print_plan
  exit 0
fi

run_logged() {
  local log_file="$1"
  shift
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@" 2>&1 | tee -a "$log_file"
}

bridge_dist_evidence_valid() {
  [[ -s "$bridge_gate_json" && -s "$bridge_dist_zip" ]] || return 1
  jq -e --arg fp "$bridge_fingerprint" '.status == "passed" and .fingerprint == $fp' "$bridge_gate_json" >/dev/null \
    || return 1
  expected_sha="$(jq -r '.distSha256 // empty' "$bridge_gate_json")"
  [[ -n "$expected_sha" ]] || return 1
  actual_sha="$(shasum -a 256 "$bridge_dist_zip" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]]
}

cache_bridge_dist() {
  local evidence_source="$1"
  local evidence_log="$2"
  need ditto
  [[ -s packages/bridge/dist/cli.js ]] || die "Bridge dist/cli.js is missing after a successful build"
  mkdir -p "$bridge_stage_dir"
  rm -f "$bridge_dist_zip"
  ditto -c -k --sequesterRsrc --keepParent packages/bridge/dist "$bridge_dist_zip"
  local dist_sha
  dist_sha="$(shasum -a 256 "$bridge_dist_zip" | awk '{print $1}')"
  jq -n \
    --arg fingerprint "$bridge_fingerprint" \
    --arg head "$head_sha" \
    --arg source "$evidence_source" \
    --arg evidenceLog "$evidence_log" \
    --arg distArchive "$bridge_dist_zip" \
    --arg distSha256 "$dist_sha" \
    '{schemaVersion: 1, status: "passed", fingerprint: $fingerprint,
      head: $head, source: $source, log: $evidenceLog,
      distArchive: $distArchive, distSha256: $distSha256}' \
    > "$bridge_gate_json"
}

if [[ "$command_name" == "gate" ]]; then
  if [[ "$force" == "0" && -s "$gate_json" ]] && \
      jq -e --arg fp "$fingerprint" '.status == "passed" and .fingerprint == $fp' "$gate_json" >/dev/null; then
    echo "Reusing source gates for exact fingerprint: $fingerprint"
    echo "$gate_json"
    exit 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    print_plan
    echo "Dry run: would execute committed/worktree diff checks."
    if [[ "$bridge_changed" == "1" && "$mobile_changed" == "1" ]]; then
      echo "Dry run: would execute the real conversation-chain gate once."
    elif [[ "$bridge_changed" == "1" ]]; then
      echo "Dry run: would build Bridge once."
    fi
    if [[ "$mobile_changed" == "1" ]]; then
      echo "Dry run: would analyze Mobile once without pub/clean."
    fi
    exit 0
  fi

  log_file="$stage_dir/source-gates.log"
  : > "$log_file"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  started_epoch="$(date +%s)"

  run_logged "$log_file" git diff --check "$base_sha..$head_sha"
  run_logged "$log_file" git diff --check

  bridge_already_built=0
  if [[ "$bridge_changed" == "1" && "$mobile_changed" == "1" ]]; then
    mkdir -p "$chain_stage_dir" "$bridge_stage_dir"
    if [[ "$force" == "0" && -s "$chain_gate_json" ]] && \
        jq -e --arg fp "$chain_fingerprint" '.status == "passed" and .fingerprint == $fp' "$chain_gate_json" >/dev/null; then
      echo "Reusing real conversation-chain gate: $chain_fingerprint" | tee -a "$log_file"
      if ! bridge_dist_evidence_valid; then
        bridge_log="$bridge_stage_dir/build.log"
        : > "$bridge_log"
        run_logged "$bridge_log" npm run bridge:build
        cache_bridge_dist "bridge-build-after-chain-reuse" "$bridge_log"
      fi
    else
      chain_log="$chain_stage_dir/chain.log"
      : > "$chain_log"
      chain_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      run_logged "$chain_log" bash scripts/test-conversation-chain.sh
      jq -n \
        --arg fingerprint "$chain_fingerprint" \
        --arg head "$head_sha" \
        --arg startedAt "$chain_started" \
        --arg finishedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg log "$chain_log" \
        '{schemaVersion: 1, status: "passed", fingerprint: $fingerprint,
          head: $head, startedAt: $startedAt, finishedAt: $finishedAt, log: $log}' \
        > "$chain_gate_json"
      cache_bridge_dist "conversation-chain" "$chain_log"
    fi
    bridge_already_built=1
  fi
  if [[ "$bridge_changed" == "1" && "$bridge_already_built" == "0" ]]; then
    mkdir -p "$bridge_stage_dir"
    if [[ "$force" == "0" ]] && bridge_dist_evidence_valid; then
      echo "Reusing Bridge build gate: $bridge_fingerprint" | tee -a "$log_file"
    else
      bridge_log="$bridge_stage_dir/build.log"
      : > "$bridge_log"
      run_logged "$bridge_log" npm run bridge:build
      cache_bridge_dist "bridge-build" "$bridge_log"
    fi
  fi
  if [[ "$mobile_changed" == "1" ]]; then
    mkdir -p "$mobile_stage_dir"
    if [[ "$force" == "0" && -s "$mobile_gate_json" ]] && \
        jq -e --arg fp "$mobile_fingerprint" '.status == "passed" and .fingerprint == $fp' "$mobile_gate_json" >/dev/null; then
      echo "Reusing Mobile analyze gate: $mobile_fingerprint" | tee -a "$log_file"
    else
      mobile_log="$mobile_stage_dir/analyze.log"
      : > "$mobile_log"
      (
        cd apps/mobile
        run_logged "$mobile_log" "$flutter_bin" analyze --no-pub --no-fatal-infos
      )
      jq -n \
        --arg fingerprint "$mobile_fingerprint" \
        --arg head "$head_sha" \
        --arg log "$mobile_log" \
        '{schemaVersion: 1, status: "passed", fingerprint: $fingerprint,
          head: $head, source: "mobile-analyze", log: $log}' \
        > "$mobile_gate_json"
    fi
  fi

  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  elapsed="$(( $(date +%s) - started_epoch ))"
  jq -n \
    --arg fingerprint "$fingerprint" \
    --arg head "$head_sha" \
    --arg startedAt "$started_at" \
    --arg finishedAt "$finished_at" \
    --argjson elapsedSeconds "$elapsed" \
    --arg log "$log_file" \
    --arg bridgeEvidence "$bridge_gate_json" \
    --arg mobileEvidence "$mobile_gate_json" \
    --arg chainEvidence "$chain_gate_json" \
    '{schemaVersion: 1, status: "passed", fingerprint: $fingerprint, head: $head,
      startedAt: $startedAt, finishedAt: $finishedAt, elapsedSeconds: $elapsedSeconds,
      log: $log,
      evidence: {
        bridge: $bridgeEvidence,
        mobile: $mobileEvidence,
        conversationChain: $chainEvidence
      }}' > "$gate_json"
  echo "Source gates passed in ${elapsed}s: $gate_json"
  exit 0
fi

if [[ "$command_name" == "bridge-runtime" ]]; then
  [[ "$bridge_changed" == "1" ]] || die "Bridge tree is unchanged; refusing needless runtime rebuild"
  if [[ "$dry_run" == "0" ]]; then
    bridge_dist_evidence_valid || die "Bridge build archive is missing or stale; run gate first"
  fi
  [[ -s "$bridge_plist" ]] || die "Bridge plist is missing: $bridge_plist"
  current_cli="$(plutil -extract EnvironmentVariables.BRIDGE_CLI_ENTRY raw "$bridge_plist")"
  suffix="/packages/bridge/dist/cli.js"
  [[ "$current_cli" == *"$suffix" ]] || die "unexpected production Bridge entry"
  current_runtime="${current_cli%$suffix}"
  [[ -d "$current_runtime/node_modules" ]] || die "current runtime cannot seed dependencies"
  current_manifest="$current_runtime/RELEASE_MANIFEST.txt"
  [[ -s "$current_manifest" ]] || die "current runtime lacks RELEASE_MANIFEST.txt"
  current_source="$(awk -F= '$1 == "source_head" {print $2; exit}' "$current_manifest")"
  [[ -n "$current_source" ]] || die "current runtime source_head is unavailable"
  current_lock="$(git rev-parse "$current_source:package-lock.json" 2>/dev/null || true)"
  [[ "$current_lock" == "$root_lock" ]] || die "dependency lock changed; use the slow dependency-install path once"

  if [[ -z "$runtime_name" ]]; then
    base_version="$(jq -r '.version' packages/bridge/package.json | sed -E 's/-compat\..*$//')"
    max_compat=0
    runtime_parent="$(dirname "$current_runtime")"
    for path in "$runtime_parent"/"$base_version"-compat.*-*; do
      [[ -d "$path" ]] || continue
      value="$(basename "$path" | sed -E "s/^${base_version//./\\.}-compat\.([0-9]+)-.*$/\\1/")"
      [[ "$value" =~ ^[0-9]+$ ]] || continue
      (( value > max_compat )) && max_compat="$value"
    done
    runtime_name="$base_version-compat.$((max_compat + 1))-${head_sha:0:8}"
  fi
  runtime_parent="$(dirname "$current_runtime")"
  final_runtime="$runtime_parent/$runtime_name"
  stage_runtime="$runtime_parent/.staging-$runtime_name"
  [[ ! -e "$final_runtime" ]] || die "runtime already exists: $final_runtime"

  if [[ "$dry_run" == "1" ]]; then
    echo "Dry run: dependency clone is valid ($current_lock)."
    echo "Dry run: would APFS-clone $current_runtime"
    echo "Dry run: would overlay the built Bridge into $final_runtime"
    exit 0
  fi

  case "$stage_runtime" in
    "$runtime_parent"/.staging-*) ;;
    *) die "unsafe runtime staging path" ;;
  esac
  [[ ! -e "$stage_runtime" ]] || die "staging runtime already exists: $stage_runtime"
  dist_extract=""
  cleanup_stage() {
    if [[ -n "$dist_extract" && -d "$dist_extract" ]]; then
      rm -rf "$dist_extract"
    fi
    if [[ -d "$stage_runtime" ]]; then
      rm -rf "$stage_runtime"
    fi
  }
  trap 'cleanup_stage; rm -f "$changed_file"' EXIT

  cp -cR "$current_runtime" "$stage_runtime"
  dist_extract="$(mktemp -d /private/tmp/ccpocket-fast-bridge-dist.XXXXXX)"
  rm -rf "$stage_runtime/packages/bridge/dist"
  ditto -x -k "$bridge_dist_zip" "$dist_extract"
  [[ -s "$dist_extract/dist/cli.js" ]] || die "cached Bridge dist archive is invalid"
  ditto "$dist_extract/dist" "$stage_runtime/packages/bridge/dist"
  rm -rf "$dist_extract"
  dist_extract=""
  ditto packages/bridge/scripts "$stage_runtime/packages/bridge/scripts"
  cp packages/bridge/package.json "$stage_runtime/packages/bridge/package.json"
  cp packages/bridge/file-browser-posix-helper.c "$stage_runtime/packages/bridge/file-browser-posix-helper.c"
  cp LICENSE "$stage_runtime/packages/bridge/LICENSE"
  cli_sha="$(shasum -a 256 "$stage_runtime/packages/bridge/dist/cli.js" | awk '{print $1}')"
  source_cli_sha="$(shasum -a 256 packages/bridge/dist/cli.js | awk '{print $1}')"
  source_sync_sha="$(shasum -a 256 packages/bridge/dist/local-features/conversation-sync-v2.js | awk '{print $1}')"
  runtime_sync_sha="$(shasum -a 256 "$stage_runtime/packages/bridge/dist/local-features/conversation-sync-v2.js" | awk '{print $1}')"
  [[ "$cli_sha" == "$source_cli_sha" ]] || die "runtime CLI does not match the exact HEAD build"
  [[ "$runtime_sync_sha" == "$source_sync_sha" ]] || die "runtime conversation sync bundle does not match the exact HEAD build"
  diff -qr packages/bridge/dist "$stage_runtime/packages/bridge/dist" >/dev/null \
    || die "runtime Bridge dist differs from the exact HEAD build"
  cat > "$stage_runtime/RELEASE_MANIFEST.txt" <<EOF
version=$runtime_name
source_head=$head_sha
source_fingerprint=$fingerprint
bridge_tree=$bridge_tree
package_lock=$root_lock
seed_runtime=$(basename "$current_runtime")
cli_sha256=$cli_sha
conversation_sync_sha256=$runtime_sync_sha
EOF
  grep -Fqx "source_head=$head_sha" "$stage_runtime/RELEASE_MANIFEST.txt" \
    || die "runtime manifest source_head mismatch"
  grep -Fq 'CODEX_TURN_ITEM_CURSOR_PREFIX' \
    "$stage_runtime/packages/bridge/dist/local-features/conversation-sync-v2.js" \
    || die "runtime is missing the bounded Codex turn-item cursor"
  grep -Fq 'withCachedCodexTurnItems' \
    "$stage_runtime/packages/bridge/dist/local-features/conversation-sync-v2.js" \
    || die "runtime is missing the bounded Codex turn-item fallback"
  mv "$stage_runtime" "$final_runtime"
  trap 'rm -f "$changed_file"' EXIT
  echo "Bridge runtime prepared (not activated): $final_runtime"
  echo "Bridge CLI SHA-256: $cli_sha"
  exit 0
fi

if [[ "$command_name" == "ipa" ]]; then
  [[ "$mobile_changed" == "1" ]] || die "Mobile tree is unchanged; refusing needless IPA rebuild"
  [[ "$build_number" =~ ^[0-9]+$ ]] || die "--build-number must be a positive integer"
  if [[ "$dry_run" == "0" ]]; then
    [[ -s "$mobile_gate_json" ]] || die "Mobile analyze evidence is missing; run gate first"
    jq -e --arg fp "$mobile_fingerprint" '.status == "passed" and .fingerprint == $fp' "$mobile_gate_json" >/dev/null \
      || die "source-gate evidence does not match this fingerprint"
  fi
  build_name="$(awk '/^version:/ {print $2; exit}' apps/mobile/pubspec.yaml | cut -d+ -f1)"
  if [[ -z "$output_path" ]]; then
    output_path="$repo_root/CC-Pocket-${build_name}-build${build_number}-${head_sha:0:8}-AltStore.ipa"
  fi
  [[ "$output_path" = /* ]] || output_path="$repo_root/$output_path"
  [[ ! -e "$output_path" || "$force" == "1" ]] || die "output already exists: $output_path"

  if [[ "$dry_run" == "1" ]]; then
    echo "Dry run: would reuse Flutter/Pods/DerivedData caches and build once:"
    echo "  $flutter_bin build ios --release --no-codesign --no-pub --no-tree-shake-icons --build-name $build_name --build-number $build_number"
    echo "Dry run: would package and audit $output_path"
    exit 0
  fi

  (
    cd apps/mobile
    "$flutter_bin" build ios --release --no-codesign --no-pub --no-tree-shake-icons \
      --build-name "$build_name" --build-number "$build_number"
  )
  runner_app="$repo_root/apps/mobile/build/ios/iphoneos/Runner.app"
  [[ -d "$runner_app" ]] || die "Runner.app was not produced"
  stage_ipa="$(mktemp -d /private/tmp/ccpocket-fast-ipa.XXXXXX)"
  ipa_complete=0
  cleanup_ipa() {
    rm -rf "$stage_ipa"
    if [[ "$ipa_complete" == "0" ]]; then
      rm -f "$output_path"
    fi
  }
  trap 'cleanup_ipa; rm -f "$changed_file"' EXIT
  mkdir -p "$stage_ipa/Payload"
  ditto "$runner_app" "$stage_ipa/Payload/Runner.app"
  staged_app="$stage_ipa/Payload/Runner.app"

  # Flutter/Xcode may copy prebuilt frameworks that still carry their vendor
  # signature. The AltStore input must be uniformly unsigned, so strip only the
  # disposable staging copy and leave the Xcode archive untouched.
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
      codesign --remove-signature "$candidate" >/dev/null 2>&1 || true
    fi
  done < <(find "$staged_app" -type f -print0)
  find "$staged_app" -type d -name _CodeSignature -prune -exec rm -rf {} +

  rm -f "$output_path"
  ditto -c -k --sequesterRsrc --keepParent "$stage_ipa/Payload" "$output_path"

  zipinfo -1 "$output_path" | awk '
    /^\// || /(^|\/)\.\.($|\/)/ {bad=1}
    END {exit bad ? 1 : 0}
  ' || die "unsafe ZIP path found"
  if find "$staged_app" -name embedded.mobileprovision -print -quit | grep -q .; then
    die "IPA unexpectedly contains provisioning"
  fi
  if find "$staged_app" -type d -name _CodeSignature -print -quit | grep -q .; then
    die "IPA unexpectedly contains a code-signature directory"
  fi
  bundle_id="$(plutil -extract CFBundleIdentifier raw "$staged_app/Info.plist")"
  actual_build="$(plutil -extract CFBundleVersion raw "$staged_app/Info.plist")"
  [[ "$bundle_id" == "com.k9i.ccpocket" ]] || die "unexpected bundle id: $bundle_id"
  [[ "$actual_build" == "$build_number" ]] || die "unexpected build number: $actual_build"
  macho_report="$stage_dir/ipa-macho.txt"
  find "$staged_app" -type f -print0 | xargs -0 file | grep 'Mach-O' > "$macho_report" || true
  [[ -s "$macho_report" ]] || die "no Mach-O files found"
  ! grep -Eq 'x86_64|i386' "$macho_report" || die "simulator architecture found in IPA"
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O' && codesign -dv "$candidate" >/dev/null 2>&1; then
      die "signed Mach-O remains in IPA staging: $candidate"
    fi
  done < <(find "$staged_app" -type f -print0)
  ipa_sha="$(shasum -a 256 "$output_path" | awk '{print $1}')"
  ipa_size="$(stat -f %z "$output_path")"
  jq -n \
    --arg head "$head_sha" \
    --arg fingerprint "$fingerprint" \
    --arg path "$output_path" \
    --arg version "$build_name" \
    --arg build "$build_number" \
    --arg sha256 "$ipa_sha" \
    --argjson bytes "$ipa_size" \
    '{schemaVersion: 1, status: "passed", head: $head, fingerprint: $fingerprint,
      path: $path, version: $version, build: $build, bytes: $bytes,
      sha256: $sha256, unsigned: true, provisioningProfile: false}' \
    > "$stage_dir/ipa.json"
  ipa_complete=1
  echo "IPA prepared and audited (not installed): $output_path"
  echo "SHA-256: $ipa_sha"
  echo "Bytes: $ipa_size"
  exit 0
fi
