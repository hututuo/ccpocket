#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
probe_entry="$repo_root/packages/bridge/dist/codex-shared-runtime-l0.js"

if ! test -f "$probe_entry"; then
  echo "Shared-runtime L0 probe is not built. Run the Bridge build first." >&2
  exit 1
fi

node_bin=$(command -v node)
exec "$node_bin" "$probe_entry" "$@"
