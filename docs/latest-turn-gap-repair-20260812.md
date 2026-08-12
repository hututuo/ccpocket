# Latest-turn gap repair (2026-08-12)

## Scope

This note records the production-shaped failure behind one Codex conversation
showing a stale tail and an incomplete process stream on Mobile. It is an
implementation and regression reference, not evidence that a Bridge or IPA has
been deployed.

Affected development sample:

- thread: `019fe552-2d01-7730-aaf6-87ae94a777f7`
- turn: `019ff31a-a0fe-7420-8cbb-7c7eaab6b573`
- local rollout size during diagnosis: about 890 MiB and still growing

## Confirmed failure chain

1. The normal `conversation_sync_v2` window was valid but incomplete. It
   committed 97 visible entries and advertised an `items_page` repair for the
   newest turn.
2. Mobile only exposed Retry when the visible entry list was empty. A non-empty
   partial window therefore had neither automatic repair nor a usable manual
   recovery action.
3. A direct production-wire read confirmed that Mobile never sent
   `conversation_items_page` for the affected gap.
4. Even when requested manually, the production Bridge failed with
   `Conversation item exceeds the frame byte budget` because one compacted
   rollout record was about 7.95 MiB.
5. The installed Codex app-server (`0.146.0`) explicitly reports that
   `thread/items/list` is not supported. The previous headless fixture
   implemented that method, so tests bypassed the actual fallback path.
6. The old fallback converted the entire turn and attempted to place it in one
   64 KiB response. A single oversized tool/compaction payload blocked all
   later commentary and the final answer behind the same request.
7. Mobile merged successful repair pages directly into the readable hot
   window. Earlier recovered items could therefore be appended after already
   visible later fragments, causing ordering jumps even when every page
   eventually arrived.

This was not one UI rendering bug. It was a Provider capability mismatch, a
Bridge framing failure, a missing Mobile repair trigger, and a non-atomic cache
merge on the same path.

## Implemented semantics

### Bridge

- Try the official bounded item RPC when available.
- When the method is unsupported, locate the requested turn through bounded
  `thread/turns/list(itemsView=full)` pages and paginate its raw items locally.
- Bind the local cursor to `turnId + offset + snapshot hash`; a changed turn is
  rejected instead of mixing two snapshots.
- Cache the bounded fallback turn briefly so later pages do not rescan the
  entire thread.
- Preserve user, thinking/commentary, and final text exactly. Oversized tool
  bodies become stable `historyToolDetailGaps` and remain available through the
  existing explicit by-id detail path.
- Keep every physical response under the existing 64 KiB frame budget.
- Do not read the Desktop rollout timeline during an ordinary content repair;
  that extra scan is reserved for explicit tool-detail requests.

### Mobile

- A focused cache with an explicit `items_page` gap automatically requests the
  repair page when either payload omission or a positive missing-entry count is
  reported, whether the gap commits before or after the route gains focus.
- Keep the last committed window visible while repair is in flight.
- Stage repair pages in dedicated SQLite tables. The terminal page atomically
  replaces only entries belonging to the affected provider turn, preserving
  older cached turns and provider page order.
- Persist the repair cursor and staging rows across process interruption.
- Fence staging by source generation, content revision, turn identity and
  entry ID/hash. A newer live fragment invalidates an obsolete repair instead
  of allowing it to overwrite the readable tail.
- Reject repeated or out-of-range cursors instead of treating them as a
  successful terminal page.
- Coalesce duplicate repair triggers and attempt transient repairs at most four
  times with bounded backoff. Focus changes, transport loss, scoped reset and
  disposal cancel obsolete retry state.
- A scoped reset, legacy authoritative patch or cache deletion removes the
  corresponding staging rows and cursor.
- Manual Retry remains visible for an explicit omitted payload even when other
  cached entries are already visible, but normal live generation does not show
  a spurious Retry banner.

## Regression strategy

The core automated closure is intentionally not a fake Bridge:

```text
fake Provider/app-server
  -> real Bridge normalization and WebSocket framing
  -> real Mobile BridgeService
  -> real conversation sync service
  -> real SQLite repository
  -> real StreamingStateCubit / ChatSessionCubit / process layout projection
```

The fake Provider explicitly rejects `thread/items/list`. Its newest turn
contains a 100 KiB tool result followed by commentary and a final answer. The
test requires the two visible messages exactly once through both SQLite and the
actual chat/process projection, a stable tool-detail gap, no message at or
above 64 KiB, and terminal `latestTurnComplete=true`.

Separate repository tests assert that the first page does not modify the
readable cache and that the final page replaces the old partial turn in provider
order in one transaction. Existing full Bridge and Mobile tests remain general
regression gates; their raw pass count is not treated as proof of this business
chain.

The existing unredacted rollout manifest remains intentionally frozen at an
older immutable prefix and does **not** represent this incident. The affected
real turn was instead validated read-only against the live development source:

- provider items: 29
- visible reasoning/commentary/final items: 19
- missing visible IDs: 0
- duplicated visible IDs: 0
- response pages: 1
- response bytes: 17,822
- final text bytes: 2,266
- final text SHA-256:
  `b4662402f20c1516c4bae53022261e5bca2b2b612aea92c151d3089970c546af`

## Release boundary

The change includes both Bridge and Dart/SQLite behavior. Source validation
does not update the production Bridge, publish OTA, build an IPA, or prove the
physical phone is running the candidate. Those are separate release and device
acceptance steps.
