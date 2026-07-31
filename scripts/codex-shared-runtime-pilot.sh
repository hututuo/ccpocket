#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
pilot_entry="$repo_root/packages/bridge/dist/pilot-isolation.js"

usage() {
  cat <<'EOF'
Usage:
  codex-shared-runtime-pilot.sh prepare --root /private/tmp/ccp-sr-...
  codex-shared-runtime-pilot.sh prepare-identity --root /private/tmp/ccp-sr-... --source-codex-home /absolute/source/CODEX_HOME
  codex-shared-runtime-pilot.sh prepare-daemon --root /private/tmp/ccp-sr-... --source-cli /absolute/Desktop/codex --expected-version VERSION
  codex-shared-runtime-pilot.sh start-daemon   --root /private/tmp/ccp-sr-... --source-cli /absolute/Desktop/codex --expected-version VERSION
  codex-shared-runtime-pilot.sh verify-daemon  --root /private/tmp/ccp-sr-... --source-cli /absolute/Desktop/codex --expected-version VERSION
  codex-shared-runtime-pilot.sh stop-daemon    --root /private/tmp/ccp-sr-... --source-cli /absolute/Desktop/codex --expected-version VERSION
  codex-shared-runtime-pilot.sh launch --root /private/tmp/ccp-sr-... --bridge-entry /absolute/dist/cli.js --source-cli /absolute/Desktop/codex --expected-version VERSION [--phone-link 1]

The daemon lifecycle never invokes daemon bootstrap. By default launch keeps
the API-key phone link suppressed; --phone-link 1 explicitly enables it.
EOF
}

case "${1:-}" in
  help|-h|--help)
    usage
    exit 0
    ;;
esac

if ! test -f "$pilot_entry"; then
  echo "Pilot launcher is not built. Run the Bridge build in this worktree first." >&2
  exit 1
fi

# Resolve Node before the pilot replaces HOME. This avoids tool managers trying
# to bootstrap another runtime into the isolated home.
node_bin=$(command -v node)
exec "$node_bin" "$pilot_entry" "$@"
