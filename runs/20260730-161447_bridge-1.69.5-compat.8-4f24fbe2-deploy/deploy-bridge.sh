#!/bin/bash
set -Eeuo pipefail

label="com.ccpocket.bridge"
domain="gui/$(id -u)"
plist="/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist"
backup_dir="/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730/backups/20260730-162250_bridge-1.69.5-compat.8-4f24fbe2-deploy"
before_plist="$backup_dir/com.ccpocket.bridge.plist.before"
staged_plist="$backup_dir/com.ccpocket.bridge.plist.candidate"
deployed_plist="$backup_dir/com.ccpocket.bridge.plist.deployed"
old_cli="/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.7-4c5f875e/packages/bridge/dist/cli.js"
new_cli="/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.8-4f24fbe2/packages/bridge/dist/cli.js"

rollback() {
  result=$?
  trap - ERR
  /bin/launchctl unload "$plist" >/dev/null 2>&1 || true
  /usr/bin/ditto "$before_plist" "$plist"
  /bin/launchctl load -w "$plist" >/dev/null 2>&1 || true
  exit "$result"
}
trap rollback ERR

test -s "$plist"
test -s "$before_plist"
test -s "$old_cli"
test -s "$new_cli"
test "$(
  /usr/bin/plutil -extract EnvironmentVariables.BRIDGE_CLI_ENTRY raw -o - "$plist"
)" = "$old_cli"

/usr/bin/ditto "$before_plist" "$staged_plist"
/usr/bin/plutil -replace EnvironmentVariables.BRIDGE_CLI_ENTRY \
  -string "$new_cli" "$staged_plist"
/usr/bin/plutil -lint "$staged_plist" >/dev/null
test "$(
  /usr/bin/plutil -extract EnvironmentVariables.BRIDGE_CLI_ENTRY raw -o - "$staged_plist"
)" = "$new_cli"

/bin/launchctl unload "$plist"

for attempt in {1..40}; do
  if ! /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done
if /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  exit 1
fi

/usr/bin/ditto "$staged_plist" "$plist"
/usr/bin/cmp -s "$staged_plist" "$plist"
/bin/launchctl load -w "$plist"
/bin/rm -f "$backup_dir/version.json" "$backup_dir/version.pending.json"
for attempt in {1..600}; do
  if /usr/bin/curl --silent --fail --max-time 1 \
    http://127.0.0.1:8765/version > "$backup_dir/version.pending.json"; then
    /bin/mv "$backup_dir/version.pending.json" "$backup_dir/version.json"
    break
  fi
  /bin/sleep 0.25
done
test -s "$backup_dir/version.json"

/usr/bin/python3 - "$backup_dir/version.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    version = json.load(handle)
if version.get("version") != "1.69.5-compat.8":
    raise SystemExit(1)
PY

/usr/bin/curl --silent --show-error --fail --max-time 3 \
  http://127.0.0.1:8765/health > "$backup_dir/health.json"
/usr/bin/python3 - "$backup_dir/health.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    health = json.load(handle)
if health.get("status") != "ok":
    raise SystemExit(1)
PY

listener_count="$(
  /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN -t | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' '
)"
test "$listener_count" = "1"
/bin/launchctl print "$domain/$label" > "$backup_dir/launchctl.txt"
/usr/bin/grep -q 'state = running' "$backup_dir/launchctl.txt"
test "$(
  /usr/bin/plutil -extract EnvironmentVariables.BRIDGE_CLI_ENTRY raw -o - "$plist"
)" = "$new_cli"

/usr/bin/ditto "$plist" "$deployed_plist"
/usr/bin/cmp -s "$plist" "$deployed_plist"
trap - ERR

pid="$(
  /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN -t | /usr/bin/sort -u
)"
/usr/bin/python3 - "$pid" <<'PY'
import json
import sys

print(json.dumps({
    "pid": int(sys.argv[1]),
    "version": "1.69.5-compat.8",
    "gitCommit": "4f24fbe2",
    "listener": "127.0.0.1:8765",
}))
PY
