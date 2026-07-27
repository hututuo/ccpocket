#!/bin/zsh
set -euo pipefail

PLIST='/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist'
ORIGINAL='/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/backups/20260727-115942_bridge-1.69.4-compat.2-52579b6b-deploy/com.ccpocket.bridge.plist'
CANDIDATE='/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/backups/20260727-115942_bridge-1.69.4-compat.2-52579b6b-deploy/com.ccpocket.bridge.after.plist'
NEW_CLI='/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.2-52579b6b/packages/bridge/dist/cli.js'
EXPECTED_VERSION='1.69.4-compat.2'

wait_for_health() {
  for attempt in {1..80}; do
    /usr/bin/curl -fsS http://127.0.0.1:8765/health >/dev/null 2>&1 &&
      return 0
    /bin/sleep 0.25
  done
  return 1
}

rollback() {
  local exit_code=$?
  trap - EXIT
  (( exit_code == 0 )) && return
  print -u2 'Bridge activation failed; restoring the previous selector.'
  /bin/launchctl unload "$PLIST" >/dev/null 2>&1 || true
  /usr/bin/ditto "$ORIGINAL" "$PLIST"
  /usr/bin/plutil -lint "$PLIST"
  /bin/launchctl load "$PLIST"
  wait_for_health
  exit "$exit_code"
}
trap rollback EXIT

old_pid=$(
  /usr/sbin/lsof -nP -t -iTCP:8765 -sTCP:LISTEN | /usr/bin/sort -u
)
print "old_pid=$old_pid"

/bin/launchctl unload "$PLIST"
for attempt in {1..40}; do
  /usr/sbin/lsof -nP -t -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 || break
  /bin/sleep 0.25
done
if /usr/sbin/lsof -nP -t -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  print -u2 'Previous Bridge listener did not stop.'
  exit 11
fi

/usr/bin/ditto "$CANDIDATE" "$PLIST"
/usr/bin/plutil -lint "$PLIST"
/bin/launchctl load "$PLIST"
wait_for_health

version=$(/usr/bin/curl -fsS http://127.0.0.1:8765/version)
print -r -- "$version" |
  /usr/bin/grep -F "\"version\":\"$EXPECTED_VERSION\"" >/dev/null

listeners=$(
  /usr/sbin/lsof -nP -t -iTCP:8765 -sTCP:LISTEN | /usr/bin/sort -u
)
count=$(print -r -- "$listeners" |
  /usr/bin/awk 'NF { n++ } END { print n + 0 }')
[[ "$count" == 1 ]] || {
  print -u2 "Expected one Bridge listener, found $count"
  exit 12
}

new_pid="$listeners"
command=$(/bin/ps -ww -p "$new_pid" -o command=)
print -r -- "$command" | /usr/bin/grep -F -- "$NEW_CLI" >/dev/null

selected_cli=$(
  /usr/bin/plutil -extract EnvironmentVariables.BRIDGE_CLI_ENTRY raw "$PLIST"
)
[[ "$selected_cli" == "$NEW_CLI" ]]

print "new_pid=$new_pid"
print -r -- "$version"
trap - EXIT
