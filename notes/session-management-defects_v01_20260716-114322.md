# CC Pocket session-management defects v01

Status: `deferred`

Recorded: 2026-07-16 11:43 CST

This note preserves the read-only session audit for a later repair pass. No
session-management code or user session data was changed as part of this note.

## Confirmed defects

1. **Recent-session request generations are global across WebSocket clients.**
   `BridgeWebSocketServer.recentSessionsRequestId` is shared by the whole
   server. A newer list request from client B silently invalidates client A's
   in-flight response. This was reproduced with two local WebSocket clients:
   A's slow request received no response after B issued a later request.

2. **The Codex-only filter omits valid `exec` sessions.**
   `CodexThreadSourceKind` supports `exec`, but
   `CODEX_RECENT_THREAD_SOURCE_KINDS` contains only `cli`, `vscode`, and
   `appServer`. Live pagination returned 288 sessions in All (265 Codex and 23
   Claude) but only 256 in Codex-only. The nine missing Codex entries were all
   `source=exec` and remained visible in All through the rollout scan.

3. **Codex worktree project identity differs by data source.**
   Native `thread/list` uses raw `thread.cwd` as `projectPath`; rollout scanning
   normalizes `<project>-worktrees/<branch>` back to the main project and keeps
   the original path as `resumeCwd`. The mobile app groups by exact
   `projectPath`, so a worktree can move between a separate project and its main
   project depending on the active filter/data source.

4. **Per-project display expansion resets on refresh.**
   The grouped mobile view initially shows five sessions per project and adds
   twenty on Show more. A first-page refresh, reconnect, or filter change clears
   `projectSessionDisplayLimits`, so sessions below the first five repeatedly
   appear to disappear.

5. **Resume is not idempotent at the provider-session level.**
   An unacknowledged `resume_session` can be replayed after reconnect. The
   Bridge does not consistently reject an already-running provider thread, so
   one Codex/Claude history ID can acquire two different short Bridge runtime
   IDs.

## Verified non-causes and data notes

- `com.ccpocket.bridge` was stable during the audit; no second Bridge listened
  on the historical test port.
- `~/.ccpocket/archived-sessions.json` and
  `~/.ccpocket/worktree-sessions.json` were absent, so CC Pocket local archive
  filtering was not hiding the investigated sessions.
- Thread `019f64b8-50aa-76e1-866e-b537f7815adb` (`ccpocket分支`) exists and is
  returned by All and Codex.
- Thread `019f6701-51da-7181-9c72-217785bd592e` exists but is `source=exec` and
  therefore appears only in All; its real worktree cwd and branch remain in the
  rollout metadata.
- Separate from the CC Pocket defects, the old indexed thread
  `019e98cf-4bbe-7391-9c6b-779a08ab9482` (`快捷键`) no longer has a current DB
  row or rollout, while its generated-image directory still exists. Preserve
  those images and investigate backups before any restoration attempt.

## Deferred repair order

1. Make recent-session request generations per WebSocket client and add a
   two-client concurrency regression test.
2. Define one product rule for `exec` sessions and apply it consistently to All
   and Codex-only results.
3. Normalize Codex project/worktree identity at one boundary while retaining
   `resumeCwd`.
4. Preserve per-project display limits across ordinary refresh/reconnect.
5. Add provider-session-level idempotency for resume/replay.

Each fix should be a separate commit and must not be mixed with upstream sync.
