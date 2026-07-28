#!/usr/bin/env bash
#
# setup-hooks.sh — Install git hooks for the project.
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# `.git` is a file in linked worktrees, so constructing
# `$REPO_ROOT/.git/hooks` fails there. Ask Git for the effective shared hooks
# directory instead; this keeps ordinary clones and linked worktrees aligned.
HOOKS_DIR="$(git rev-parse --path-format=absolute --git-path hooks)"

echo "Installing git hooks..."
mkdir -p "$HOOKS_DIR"

# pre-commit hook
cat > "$HOOKS_DIR/pre-commit" << 'HOOK'
#!/usr/bin/env bash
# Auto-installed by scripts/setup-hooks.sh
# Runs secret detection before every commit.

REPO_ROOT="$(git rev-parse --show-toplevel)"
exec "$REPO_ROOT/scripts/check-secrets.sh"
HOOK

chmod +x "$HOOKS_DIR/pre-commit"

echo "Installed: pre-commit (secret detection)"
echo "Done. Hooks are active."
