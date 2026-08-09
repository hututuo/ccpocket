# Codex Desktop project synchronization

## Problem

Codex app-server exposes a conversation `cwd`, but Codex Desktop does not use
that path basename as its project identity. Desktop keeps user-facing projects,
renames, registered roots, per-thread assignments, and projectless threads in
`$CODEX_HOME/.codex-global-state.json`.

Treating every `cwd` or worktree leaf as a project caused Mobile to display
temporary directories and worktree names as separate projects. It also meant a
Desktop project rename never reached Mobile.

## Authority and data flow

The Bridge reads Desktop's global state as a bounded, read-only presentation
projection:

```text
Codex app-server thread id + canonical cwd
                   +
Desktop local-projects / thread-project-assignments / projectless-thread-ids
                   ↓
Bridge additive projectGroup fields
                   ↓
conversation_sync_v2 and legacy recent-session response
                   ↓
Mobile SQLite catalog → SessionListCubit → grouped UI
```

The canonical `projectPath` and `resumeCwd` remain unchanged. They continue to
control provider resume, file access, security checks, and new-turn behavior.
Desktop project metadata only controls grouping, labels, local filtering,
collapse state, and project pin state.

For every catalog row returned by the Bridge, membership and names match
Desktop. This projection covers Codex app-server rows and Claude/legacy recent
rows: a non-Codex row under a registered Desktop root joins the same stable
project, while an unmatched row joins the shared projectless section. Section
order remains CC Pocket's existing local rule (explicit pins, then latest
project activity) rather than copying Desktop's sidebar order.

## Additive fields

Catalog rows may contain:

- `projectGroupKind`: `desktopProject` or `projectless`;
- `projectGroupId`: Desktop's stable local project ID;
- `projectGroupName`: Desktop's current user-facing name;
- `projectGroupPath`: a registered root used only as a presentation/fallback
  path;
- `projectGroupingSnapshotComplete`: whether this row came from a complete
  Desktop grouping decision.

Exact thread assignment wins. An explicitly projectless thread is placed in one
localized “Not in a project” group. While an assignment is pending, the longest
registered root containing the thread cwd is used; otherwise the thread uses the
same projectless group. Different worktrees assigned to one Desktop project
therefore share one Mobile section.

## Refresh and cache behavior

- The global state reader is cached by file metadata and capped at 8 MiB.
- The session catalog monitor watches `.codex-global-state.json`; a Desktop
  rename or reassignment dirties the catalog without reading conversation
  history.
- Mobile persists the additive fields in the existing rebuildable catalog.
- A sparse old-Bridge refresh cannot erase a previously committed complete
  grouping snapshot. A newer complete snapshot may rename, move, or mark a
  conversation projectless.
- A transient malformed/partial rewrite retains the last good in-process
  projection; when no good snapshot exists, Mobile keeps legacy path grouping.
- Desktop project IDs are never sent to a legacy filesystem `projectPath`
  filter. Mobile applies those selections locally to the complete catalog.
- Legacy path-based collapse, pin, and display-limit preferences migrate to a
  stable Desktop project only when exactly one project in a complete,
  unfiltered catalog owns that path. A shared parent root, projectless row,
  incomplete projection, or reused worktree path cannot control two sections.
- A project-scoped pagination response is merged into the existing catalog and
  cache. Loading more rows in one project never replaces unrelated projects.
- A search that matches a Desktop-only project name is evaluated by the Bridge
  against its bounded project projection instead of forwarding that label to
  app-server as if it were conversation text.
- Mobile expands an incomplete initial catalog at most once to the existing
  1,000-thread Bridge safety window. It does not repeatedly double requests
  when Bridge reports that older rows still exist.

## Conversation names

Conversation names are provider thread metadata, not Desktop project metadata.
For a durable Codex thread in shared-daemon mode:

- Mobile rename uses app-server `thread/name/set` against the exact thread ID;
- app-server persistence remains authoritative and emits
  `thread/name/updated`;
- the shared control event invalidates the one catalog projection, and Mobile
  consumes the resulting provider name in both the home row and the mounted
  session title;
- a rename made in Codex Desktop follows the same event and catalog path back
  to Mobile;
- concurrent renames use app-server ordering; the newest persisted provider
  value wins. Mobile does not maintain a competing title database.

This makes durable conversation names bidirectional in shared mode. Project
names remain Desktop-owned and flow from Desktop to Mobile only; Mobile does not
rewrite Desktop's project configuration.

## Compatibility and failure behavior

- Old Mobile ignores the additive fields and keeps path-based grouping.
- New Mobile with an old Bridge receives no complete grouping metadata and
  keeps the legacy path behavior.
- If Desktop global state is missing, malformed, too large, or changes format,
  the Bridge either retains its last good bounded projection or fails open to
  legacy path grouping instead of blocking directory synchronization.
- The Bridge never writes `.codex-global-state.json`; project creation, rename,
  deletion, and assignment remain owned by Codex Desktop.
- This file is Desktop host state rather than an app-server protocol contract.
  Future Desktop format changes must be re-verified against live state before
  changing the parser.

## Known bounded-history limitation

The existing recent-thread adapter scans at most 1,000 Codex threads per
request. Project identity is correct for every returned row, but a manual
global page beyond that scan window cannot yet advance because the legacy
request contains an offset rather than an app-server cursor. Solving that
requires a separate additive cursor/continuation protocol; this change avoids
the former repeated expansion loop but does not pretend the older catalog is
complete.

Detached daemon/private title clear behavior is covered through the Bridge
handler and provider-path/empty-marker tests. A full live-runtime
clear-and-reload smoke remains a release verification item; it is not evidence
of a production deployment in this source-only task.

Source implementation and tests do not authorize Bridge deployment, OTA, IPA
construction, device installation, Cloud changes, or stable promotion.
