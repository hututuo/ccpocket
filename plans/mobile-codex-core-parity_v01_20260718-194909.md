# Mobile Codex Core Parity v01

Status: accepted

Date: 2026-07-18

## Objective

Expose the Codex capabilities that are used routinely on desktop through
CC Pocket without inventing a second session model. Each addition must remain
independently reviewable and directly revertible after future upstream merges.

The authoritative runtime remains Codex app-server. Mobile-only queues,
mirrors, panels, and shortcuts must be labelled as client behavior and must not
be presented as native app-server state.

## Evidence baseline

- Fresh official Codex app-server manual downloaded on 2026-07-18.
- Stable and experimental protocol schemas generated locally from Codex
  `0.145.0-alpha.18`.
- Existing CC Pocket implementation and regression tests at `40ec2a5`.
- Conversation Mirror and Core Actions use neutral disabled protocol and
  registration slots plus a documented, feature-owned host-hook whitelist.
  Their behavior commits remove both implementation and hooks through a direct
  revert; the selected baseline composition roots are not claimed to remain
  byte-for-byte frozen while a feature is installed.

## Already implemented

- Start, steer, queue, edit queued input, cancel, and interrupt.
- Text, image, local file mention, Skill, App, and Plugin composer entities.
- Model directory, GPT-5.6 effort values, Standard/Fast service tier.
- Next-turn permission changes and explicit restart-now behavior.
- Context-window usage, account usage, reset time, and reset credit.
- Goal create, edit, pause, resume, budget changes, and clear.
- Approval, user question, MCP elicitation, and phone-owned auto approval.
- Read-only subagent browser, selected-text actions, Side Chat.
- Rename, archive, rewind/fork, Git and worktree tools, artifact preview.
- Recent-first history plus opt-in full mobile mirror and incremental sync.

## This implementation batch

### 1. Session correctness

Keep this separate from feature UI:

- correlate recent-session generations per client/request;
- include Codex `exec` source sessions;
- normalize Codex thread and rollout worktree paths consistently;
- preserve per-project "show more" limits across offset-zero refreshes;
- prevent duplicate resume runtimes for the same provider thread where the
  existing ownership model can do so safely.

### 2. Codex Core Actions module

Use a removable Bridge/mobile local-feature slot named
`codex_core_actions`:

- `thread/compact/start`;
- `review/start`, inline delivery only in v1, with uncommitted/base/commit/
  custom targets;
- read-only `mcpServerStatus/list`;
- exact request correlation, bounded output, live connection only;
- method-not-found becomes a feature-local unsupported state, never success.

Compact and Review are disabled while a turn is active because app-server does
not accept them as steerable input.

### 3. Native command router

Codex commands shown by the composer must route to real actions:

- `/goal` -> Goal manager;
- `/permissions` -> existing permission UI;
- `/plan` -> capability-aware Plan toggle;
- `/skills` -> existing Skill entities/picker;
- `/compact` -> native compact confirmation/action;
- `/review` -> native review target UI;
- `/mcp` -> read-only MCP server status;
- `/model` and `/context` -> existing model/context surfaces when exposed.

An unimplemented reserved Codex command must not silently become an ordinary
user turn. Unknown non-reserved commands remain normal input for project-level
workflows.

### 4. Plan compatibility adapter

`collaborationMode/list` and `turn/start.collaborationMode` are experimental.
The Bridge must positively probe this exact app-server process before sending
the field. Default turns omit it when support is unknown or absent.

Native Plan is used only after a successful probe. A definite method-not-found
or a valid mode directory without Plan is cached as unsupported; timeout,
transport, abort, internal-error, or malformed responses remain unknown and
retryable. Older app-server versions receive a visible unsupported/retry state,
never a locally invented planning turn labelled as native Plan. Stable
`turn/plan/updated` rendering remains available independently.

### 5. Authoritative lifecycle

Archive browser, unarchive, and destructive delete remain a distinct Bridge/
Mobile pair. Delete requires typed `DELETE` confirmation explaining that
spawned descendants may also be removed. Official RPC success precedes local
archive bookkeeping. Resume admission and lifecycle mutation share the same
provider-thread lock, and the Bridge rechecks inactivity immediately before the
official RPC to close cross-socket races.

## Explicit exclusions from the default core surface

- Guardian override inferred from warning text. A future implementation may
  use `thread/approveGuardianDeniedAction` only when the unstable structured
  review event is complete and validates fail-closed.
- Detached Review until child runtime ownership and routing are specified.
- Deprecated `thread/rollback` as a file undo operation.
- Background terminals, realtime voice, remote control, memory mode, process
  spawn, direct filesystem mutation, or unsandboxed shell buttons.
- Plugin marketplace install/uninstall management. The upstream README still
  marks this production surface under development.
- Fake direct subagent control. Buttons may only send clearly labelled natural
  language requests to Codex.

## Compatibility matrix

| Mobile | Bridge | app-server | Behavior |
|---|---|---|---|
| old | new | new | additive messages are ignored; existing sessions continue |
| new | old | any | feature request is correlated as unsupported; canonical chat remains usable |
| new | new | old | each RPC downgrades independently; ordinary turns omit unsupported experimental fields |
| new | new | new | compact, inline review, MCP status, native Plan, and mirror are enabled per capability |
| any | any | future | unknown messages/items retain a fallback renderer and do not erase canonical content |

No single global version flag may enable or disable this table. Capability is
negotiated per feature and per live app-server process.

## Commit and revert order

Implementation commits remain behavior-owned:

1. Neutral Bridge and Mobile compatibility foundations with disabled Mirror/
   Core slots.
2. Session-correctness fixes.
3. Bridge and Mobile native Plan capability adapters.
4. Bridge and Mobile authoritative lifecycle modules.
5. Bridge Mirror, then Mobile Mirror.
6. Bridge Core Actions, then Mobile Core tools and native-command router.
7. Documentation and compatibility gates.

The final four optional behavior commits are ordered `MIRROR_BRIDGE` →
`MIRROR_MOBILE` → `CORE_BRIDGE` → `CORE_MOBILE`. Core and Mirror can each be
removed as a pair; either Bridge or Mobile side also has a tested old-peer
fallback. Removing the whole extension stack in dependency-reverse order must
reproduce the selected `40ec2a5` baseline tree exactly.

### Host-hook whitelist

Independence here follows the user's Git-level definition: a module's complete
behavior and its integration hooks are owned by a bounded commit set that can
be reverted after an upstream merge. It does not mean that an installed module
may never touch an existing host file.

- Bridge Mirror is limited to its protocol/registration slots and feature
  files.
- Mobile Mirror additionally owns narrow bootstrap, Bridge message routing,
  canonical-history publication, session-list action, and runtime-store hooks
  in `main.dart`, `BridgeService`, `SessionRuntimeStore`, `ChatSessionCubit`,
  the session-list screen, and the session card.
- Bridge Core additionally owns the native app-server action surface in
  `CodexProcess` and its WebSocket admission hook.
- Mobile Core additionally owns the Codex screen/Cubit command routing, slash
  command entries, and session-insight host hook.

These paths are expected conflict-review hotspots on an upstream merge. A
future port must rerun both the final-HEAD direct feature reverts and the full
reverse-tree equality gate; slot presence alone is not sufficient evidence of
independence.

## Verification gates

- Targeted Bridge protocol, CodexProcess, WebSocket, and local-feature tests.
- Full Bridge build and test suite.
- Targeted mobile protocol/controller/widget/Cubit tests.
- Full Flutter analyze and test suite.
- iOS simulator build without signing.
- Direct feature reverts and complete reverse-stack tree equality.
- Independent code review focused on protocol truth, version fallback,
  session isolation, bounded reads, destructive actions, and update/revert risk.

Deployment, LaunchAgent restart, and installation on a phone are deliberately
outside this batch and require a separate explicit decision after verification.

## Acceptance results

The verified code head is `135ed32` on
`feature/mobile-codex-parity-modular`. The implementation is deliberately kept
out of the stable branch and out of the running Bridge and installed apps.

- Bridge TypeScript build and the complete Bridge suite passed: 58 files,
  1212 tests, 0 failures.
- Flutter analysis completed with 0 errors and 0 warnings; the 38 reported
  infos already existed in the selected baseline.
- The complete Flutter suite passed: 1671 tests, 4 environment-dependent
  skips, 0 failures.
- An unsigned iOS Simulator build completed successfully at
  `apps/mobile/build/ios/iphonesimulator/Runner.app`. It was not installed or
  launched.
- The four top-level optional commits can each be reverted directly from the
  completed code head without conflicts. Pairwise Bridge/Mobile removal and
  complete Core/Mirror removal also passed their remaining build, analysis,
  and focused-test gates.
- Reverse-reverting all 18 extension commits from `135ed32` required no manual
  edits and reproduced `40ec2a5^{tree}` exactly at
  `66f359c08e83534e26d1d4c2c7ba0c478e5461ad`.
- Lifecycle review found and fixed a pre-RPC cross-socket inactivity race. The
  final Bridge shares one provider-thread lock between resume and lifecycle
  mutation and rechecks inactivity immediately before the official RPC.
- No Bridge process, LaunchAgent, Simulator installation, physical-phone app,
  session source, or global configuration was changed during this batch.

The final independent code review completed after the corrective passes with
P0 = 0, P1 = 0, and P2 = 0. Its frozen result is recorded by the documentation
commit without changing the already verified code tree.
