#!/usr/bin/env bash
# Register Bridge Server as a launchd service for persistent startup.
#
# The plist launches Bridge Server via `zsh -li -c "exec node ..."` so that
# the user's full shell environment (mise, nvm, pyenv, Homebrew, etc.) is
# inherited — the same as running from Terminal.app.
#
# Usage:
#   npm run setup                          # Default setup (port 8765)
#   npm run setup -- --port 9000           # Custom port
#   npm run setup -- --api-key SECRET --require-api-key
#   npm run setup -- --uninstall           # Remove service
#
# Environment variables (overridden by CLI args):
#   BRIDGE_PORT     (default: 8765)
#   BRIDGE_HOST     (default: 0.0.0.0)
#   BRIDGE_API_KEY  (default: none)
#   BRIDGE_AUTH_MODE (key, paired_or_key, or open; default: inferred)
#   BRIDGE_REQUIRE_API_KEY (default: inferred from whether a key exists)
#   BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS (development-only, default: 0)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_LABEL="com.ccpocket.bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

# Defaults (env vars as fallback)
PORT="${BRIDGE_PORT:-8765}"
HOST="${BRIDGE_HOST:-0.0.0.0}"
API_KEY="${BRIDGE_API_KEY:-}"
AUTH_MODE="${BRIDGE_AUTH_MODE:-}"
REQUIRE_API_KEY="${BRIDGE_REQUIRE_API_KEY:-}"
ALLOW_UNAUTHENTICATED_DIAGNOSTICS="${BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS:-0}"
NO_START=false
UNINSTALL=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Register Bridge Server as a macOS launchd service.

Options:
  --port <port>       Bridge port (default: 8765)
  --host <host>       Bind address (default: 0.0.0.0)
  --api-key <key>     Set the saved Bridge connection key
  --auth-mode <mode>  Authentication mode: key, paired_or_key, or open
  --require-api-key   Require the configured connection key
  --no-require-api-key
                      Disable connection-key authentication
  --no-start          Register only, don't start immediately
  --uninstall         Remove the launchd service
  -h, --help          Show this help
EOF
}

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case $1 in
    --port) [[ $# -lt 2 ]] && { echo "Error: --port requires a value"; exit 1; }; PORT="$2"; shift 2 ;;
    --host) [[ $# -lt 2 ]] && { echo "Error: --host requires a value"; exit 1; }; HOST="$2"; shift 2 ;;
    --api-key) [[ $# -lt 2 ]] && { echo "Error: --api-key requires a value"; exit 1; }; API_KEY="$2"; shift 2 ;;
    --auth-mode) [[ $# -lt 2 ]] && { echo "Error: --auth-mode requires a value"; exit 1; }; AUTH_MODE="$2"; shift 2 ;;
    --require-api-key) REQUIRE_API_KEY=1; shift ;;
    --no-require-api-key) REQUIRE_API_KEY=0; shift ;;
    --no-start) NO_START=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ "$ALLOW_UNAUTHENTICATED_DIAGNOSTICS" == 1 && -z "$AUTH_MODE" ]]; then
  echo "Error: BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS requires an explicit BRIDGE_AUTH_MODE=open"
  exit 1
fi

case "$AUTH_MODE" in
  "") [[ -n "$API_KEY" ]] && AUTH_MODE=key || AUTH_MODE=open ;;
  key|paired_or_key|open) ;;
  *) echo "Error: BRIDGE_AUTH_MODE must be key, paired_or_key, or open"; exit 1 ;;
esac

case "$REQUIRE_API_KEY" in
  "") [[ -n "$API_KEY" ]] && REQUIRE_API_KEY=1 || REQUIRE_API_KEY=0 ;;
  1) REQUIRE_API_KEY=1 ;;
  0) REQUIRE_API_KEY=0 ;;
  *) echo "Error: BRIDGE_REQUIRE_API_KEY must be 1 or 0"; exit 1 ;;
esac
if [[ "$AUTH_MODE" != open && "$REQUIRE_API_KEY" == 1 && -z "$API_KEY" ]]; then
  echo "Error: connection-key authentication is enabled but BRIDGE_API_KEY is empty"
  exit 1
fi
case "$ALLOW_UNAUTHENTICATED_DIAGNOSTICS" in
  0|1) ;;
  *) echo "Error: BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS must be 1 or 0"; exit 1 ;;
esac
if [[ "$ALLOW_UNAUTHENTICATED_DIAGNOSTICS" == 1 && "$AUTH_MODE" != open ]]; then
  echo "Error: BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS requires BRIDGE_AUTH_MODE=open"
  exit 1
fi

# --- Uninstall ---
if [ "$UNINSTALL" = true ]; then
  echo "==> Uninstalling Bridge Server service..."
  launchctl stop "$PLIST_LABEL" 2>/dev/null || true
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  echo "    Service removed."
  exit 0
fi

# --- Verify node is available ---
if ! command -v node &>/dev/null; then
  echo "ERROR: node not found in PATH. Install Node.js first."
  exit 1
fi
echo "==> Node.js: $(command -v node)"

# --- Build if needed ---
if [ ! -d "$ROOT_DIR/packages/bridge/dist" ]; then
  echo "==> Building Bridge Server..."
  cd "$ROOT_DIR" && npm run bridge:build
fi

ENTRY_POINT="$ROOT_DIR/packages/bridge/dist/index.js"

# --- Create LaunchAgents directory ---
mkdir -p "$HOME/Library/LaunchAgents"

# --- Build environment block ---
ENV_BLOCK="        <key>BRIDGE_PORT</key>
        <string>$PORT</string>
        <key>BRIDGE_HOST</key>
        <string>$HOST</string>"

ENV_BLOCK="$ENV_BLOCK
        <key>BRIDGE_REQUIRE_API_KEY</key>
        <string>$REQUIRE_API_KEY</string>
        <key>BRIDGE_AUTH_MODE</key>
        <string>$AUTH_MODE</string>"

if [ -n "$API_KEY" ]; then
  ENV_BLOCK="$ENV_BLOCK
        <key>BRIDGE_API_KEY</key>
        <string>$API_KEY</string>"
fi

if [ "$ALLOW_UNAUTHENTICATED_DIAGNOSTICS" = 1 ]; then
  ENV_BLOCK="$ENV_BLOCK
        <key>BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS</key>
        <string>1</string>"
fi

# --- Generate plist ---
echo "==> Writing $PLIST_PATH"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>

    <!--
        Launch via login+interactive shell to inherit the user's full
        environment (mise, nvm, pyenv, Homebrew, etc.) — same as Terminal.app.
        exec replaces the zsh process with node, so the process tree
        becomes: launchd → node (no leftover zsh).
    -->
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-li</string>
        <string>-c</string>
        <string>exec node $ENTRY_POINT</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$ROOT_DIR</string>

    <key>EnvironmentVariables</key>
    <dict>
$ENV_BLOCK
    </dict>

    <key>RunAtLoad</key>
    <false/>

    <key>KeepAlive</key>
    <false/>

    <key>StandardOutPath</key>
    <string>/tmp/ccpocket-bridge.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/ccpocket-bridge.err</string>
</dict>
</plist>
EOF

# --- Register with launchctl ---
echo "==> Registering service..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

# --- Start ---
if [ "$NO_START" = false ]; then
  sleep 1
  launchctl start "$PLIST_LABEL" || true
  echo "==> Bridge Server started on port $PORT"
else
  echo "==> Service registered (not started). Run: launchctl start $PLIST_LABEL"
fi

echo "    Done."
