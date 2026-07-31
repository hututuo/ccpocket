#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
desktop_entry="$repo_root/packages/bridge/dist/codex-desktop-shared-runtime.js"

if ! test -f "$desktop_entry"; then
  echo "Desktop pilot helper is not built. Run the Bridge build in this worktree first." >&2
  exit 1
fi

node_bin=$(command -v node)
exec "$node_bin" "$desktop_entry" "$@"
