# @ccpocket/bridge

Bridge server that connects Claude sessions powered by the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk) and [Codex CLI](https://github.com/openai/codex) to mobile devices via WebSocket.

This is the server component of [ccpocket](https://github.com/K9i-0/ccpocket) — a mobile client for Claude and Codex.

## Quick Start

```bash
npx @ccpocket/bridge@latest
```

A QR code will appear in your terminal. Scan it with the ccpocket mobile app to connect.

> Warning
> Versions older than `1.25.0` are deprecated and should not be used for new installs because current Anthropic Claude Agent SDK docs do not permit third-party products to use Claude subscription login.
> Upgrade to `>=1.25.0` and use `ANTHROPIC_API_KEY` instead of OAuth.

## Installation

```bash
# Recommended: run the latest Bridge directly
npx @ccpocket/bridge@latest

# Optional: install globally
npm install -g @ccpocket/bridge
ccpocket-bridge

# Show CLI help or version
ccpocket-bridge --help
ccpocket-bridge --version
```

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `BRIDGE_PORT` | `8765` | WebSocket port |
| `BRIDGE_HOST` | `0.0.0.0` | Bind address |
| `BRIDGE_API_KEY` | (none) | API key authentication (enabled when set) |
| `BRIDGE_ALLOWED_DIRS` | `$HOME` | Comma-separated list of project directories the Bridge may access; set exactly to `*` to allow any directory |
| `BRIDGE_PUBLIC_WS_URL` | (none) | Public `ws://` / `wss://` URL used for startup deep link and QR code |
| `BRIDGE_ARTIFACT_BASE_URL` | auto-detected | Mobile-reachable `http://` / `https://` base URL used by temporary file preview links |
| `BRIDGE_AUTO_ARTIFACTS` | enabled | Set to `0`, `false`, or `off` to disable automatic Codex file references without disabling explicit `share` links |
| `BRIDGE_ARTIFACT_REGISTRY_FILE` | `$HOME/.ccpocket/artifact-registry-v1[-<port>].json` | Advanced override for the private automatic-artifact descriptor registry; the file is written with mode `0600` |
| `BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR` | `$HOME/Downloads` | Destination for files uploaded by the phone; an existing stable Downloads symlink is pinned and revalidated |
| `BRIDGE_FILE_TRANSFER_PARTIAL_DIR` | `$HOME/.ccpocket/file-transfer-parts` | Private `0700` same-volume directory for resumable upload partials; a cross-volume explicit override is rejected |
| `BRIDGE_FILE_TRANSFER_STATE_FILE` | `$HOME/.ccpocket/file-transfers-v2-<bridge-id>.json` | Advanced override for private resumable transfer metadata and completion tombstones |
| `BRIDGE_CODEX_APP_SERVER_MODE` | `private` | Experimental Codex app-server mode: `private`, `managed`, or `external` |
| `BRIDGE_CODEX_SHARED_APP_SERVER_URL` | `ws://127.0.0.1:8767` in `managed` mode | Experimental shared Codex app-server URL for Codex CLI co-presence |
| `BRIDGE_CODEX_ASSIST_MODEL` | `gpt-5.4-mini` | Codex model used for auto-rename and commit-message assist calls |
| `BRIDGE_CODEX_ASSIST_REASONING_EFFORT` | `none` | Reasoning effort used for Codex assist calls |
| `BRIDGE_DEMO_MODE` | (none) | Demo mode: hide Tailscale IPs and API key from QR code / logs |
| `BRIDGE_RECORDING` | (none) | Enable session recording for debugging (enabled when set) |
| `BRIDGE_DISABLE_MDNS` | (none) | Disable mDNS auto-discovery advertisement (macOS disables it automatically) |
| `BRIDGE_PROMPT_HISTORY_FILE` | `$HOME/.ccpocket/prompt-history-v2.json` | Custom prompt history store path |
| `BRIDGE_RECENT_SESSIONS_PROFILE` | (none) | Log recent-session index timing when set to `1` or `true` |
| `BRIDGE_FILE_LIST_MAX_ENTRIES` | `5000` | Maximum file and directory entries returned to a client; non-positive or invalid values use the default |
| `BRIDGE_FILE_LIST_MAX_BYTES` | `524288` | Maximum serialized path bytes returned in a client file list; non-positive or invalid values use the default |
| `BRIDGE_DELTA_BATCH_MS` | `100` | Milliseconds to batch streaming deltas per connected client; set to `0` to disable batching |
| `BRIDGE_DELTA_BATCH_MAX_CHARS` | `4096` | Maximum Unicode characters per batched streaming payload; non-positive or invalid values use the default |
| `DIFF_IMAGE_AUTO_DISPLAY_KB` | `1024` (1 MB) | Auto-display diff images up to this size, in KB |
| `DIFF_IMAGE_MAX_SIZE_MB` | `5` (5 MB) | Maximum diff image size available for on-demand loading, in MB |
| `ANTHROPIC_API_KEY` | (none) | Claude Agent SDK API key used for Claude sessions |
| `ANTHROPIC_AUTH_TOKEN` | (none) | Advanced Claude SDK auth token; prefer `ANTHROPIC_API_KEY` |
| `OPENAI_API_KEY` | (none) | Codex API key; Codex can also use `~/.codex/auth.json` |
| `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` | (none) | Proxy for outgoing fetch requests (`http://`, `https://`, `socks4://`, `socks5://`) |

Lowercase proxy variables (`https_proxy`, `http_proxy`, `all_proxy`) are also
supported. When `BRIDGE_PROMPT_HISTORY_FILE` is not set and `BRIDGE_PORT` is not
`8765`, prompt history is stored in
`$HOME/.ccpocket/prompt-history-v2-<port>.json`.

Push relay uses Firebase Anonymous Auth automatically; no FCM environment
variables are required.

```bash
# Example: custom port with API key
BRIDGE_PORT=9000 BRIDGE_API_KEY=my-secret npx @ccpocket/bridge@latest

# Example: allow projects outside $HOME
BRIDGE_ALLOWED_DIRS="$HOME,/scratch/$USER" npx @ccpocket/bridge@latest

# Example: expose Bridge through a reverse proxy / ngrok
BRIDGE_PUBLIC_WS_URL=wss://example.ngrok-free.app npx @ccpocket/bridge@latest

# Example: same setting via CLI flag
ccpocket-bridge --public-ws-url wss://example.ngrok-free.app

# Example: disable mDNS advertisement
BRIDGE_DISABLE_MDNS=1 npx @ccpocket/bridge@latest
# or via CLI flag
ccpocket-bridge --no-mdns

# Example: use an assist model provided by a custom Codex gateway
BRIDGE_CODEX_ASSIST_MODEL=gpt-oss:20b-cloud \
BRIDGE_CODEX_ASSIST_REASONING_EFFORT=none \
npx @ccpocket/bridge@latest
```

When `BRIDGE_PUBLIC_WS_URL` is set, the startup deep link and terminal QR code
use that public URL instead of the LAN address. This is useful when the Bridge
is reachable through a reverse proxy, tunnel, or public domain.

Without it, the printed QR code is LAN-oriented by default and typically encodes
something like `ws://192.168.x.x:8765`.

## Temporary file preview links

Publish a file through the running Bridge and print a Markdown link that can be
sent in an existing CC Pocket chat:

```bash
ccpocket-bridge share "/absolute/path/report.pdf"
```

The link opens a responsive preview page in the phone's browser. Images, PDFs,
text/code, audio, video, and DOCX files render in the page; other Office formats
offer system-open and download fallbacks. The mobile app and WebSocket protocol
do not require an update. DOCX files above 25 MiB use the fallback instead of
browser rendering to avoid excessive mobile memory use.

Useful options:

```bash
# Keep the link for two hours
ccpocket-bridge share report.docx --ttl 7200

# Override the address embedded in the phone link
ccpocket-bridge share report.docx \
  --base-url http://192.168.1.20:8765

# Machine-readable output
ccpocket-bridge share report.docx --json
```

`--base-url` must be an HTTP(S) origin without a path, query, or fragment.

Links use a random capability token, expire after one hour by default, and are
stored only in Bridge memory. Restarting Bridge invalidates them. The source
file must remain unchanged and inside `BRIDGE_ALLOWED_DIRS`; changed files must
be shared again.

The publish control endpoint accepts loopback requests only. Public artifact
routes do not expose source paths, support no directory listing, and do not
inherit the Bridge's permissive Flutter Web CORS policy.

## Resumable phone file transfer

With one compatible phone connected, offer a file from the Mac/Linux CLI:

```bash
ccpocket-bridge send "/absolute/path/archive.zip"
ccpocket-bridge send archive.zip --ttl 3600 --json
```

`--base-url` is accepted only when it normalizes to the HTTP origin derived
from the authenticated phone's current WebSocket handshake. This prevents an
offer from reporting success with a LAN address while the phone is connected
through Tailscale (or vice versa); the peer's actual origin takes priority over
the Bridge's global auto-detected preview address. When the phone connects
through an SSH local forward, the authenticated handshake's exact
`localhost`, `127.0.0.1`, or `[::1]` origin is preserved because that loopback
endpoint belongs to the phone. Configured and CLI override URLs still reject
loopback and wildcard hosts.

A successful command reports `status: "offered"`: the Bridge delivered a
download capability to the one live compatible phone, but the phone has not
yet confirmed saving the file. Zero or multiple compatible phones fail closed;
the command never broadcasts a file capability. Source files must remain
inside the existing `BRIDGE_ALLOWED_DIRS` policy.

Protocol `file_transfer_v2` supports resumable transfer in both directions,
pause by stopping the current HTTP request, explicit authenticated cancel, and
persistent recovery after a Bridge restart. Pure transfer files may be up to
15 GiB; this does not raise the separate preview/rendering limit. HTTP chunks
may be any exact length from 1 byte through the advertised maximum (currently
16 MiB). The maximum is an upper bound, not a fixed chunk size: clients can
send a 1–10 MiB file in one request and adapt larger transfers based on measured
throughput. Upload publication never overwrites an existing file.

Transfer tokens never appear in CLI output or persistent state. The local send
control endpoint is loopback-only, rejects browser origins, and requires its
private control header. Phone byte routes require per-transfer random tokens,
exact offsets/ranges, and source/destination identity checks. The active HTTP
lease defaults to 24 hours; retained resumable metadata is bounded to seven
days and can renew the lease through the authenticated WebSocket protocol.

The transfer state has an exclusive process lock. Lock or state corruption
disables only `file_transfer_v2`; normal Bridge chat continues. Diagnose an
unclean-exit lock without modifying it:

```bash
ccpocket-bridge file-transfer status
```

Only if that command reports complete owner metadata and confirms the recorded
owner PID is dead, recover with:

```bash
ccpocket-bridge file-transfer unlock
```

`unlock` refuses a live owner and refuses missing/invalid owner metadata. The
Bridge never automatically removes a stale lock, avoiding a two-owner race.
`status` also reports an orphaned `.lock-recovery` claim explicitly instead of
mislabeling that state as an ordinary unlocked store.

## Automatic Codex file references

For Codex sessions, Bridge recognizes high-confidence local files without
requiring a system-prompt convention. It processes only:

- local targets in Markdown links or images in a completed assistant message;
- the structured `imageGeneration.savedPath` emitted by Codex.

Bridge does not scan command output, diffs, stack traces, fenced examples, bare
paths, directories, or arbitrary MCP JSON. It preserves the original message
text and adds at most 64 opaque artifact references per message. Messages above
1 Mi characters skip automatic Markdown parsing while still being delivered
unchanged. Every Markdown-derived file is limited to the session
worktree/project and its explicit additional writable roots. Generated images
from Codex's private temporary image directory are copied to CC Pocket-managed
storage before registration; Bridge never opens all of `/tmp` for artifact
access.

An artifact reference is not a public URL. Preview artifacts send their opaque
id back with the owning session and message ids only when the user taps them.
Bridge then rechecks the current session roots and the file's device, inode,
size, and modification time before issuing a short-lived relative
`/artifacts/<token>` URL. The client resolves that URL against the HTTP origin
corresponding to its current WebSocket connection, so LAN/Tailscale address
changes do not get baked into history.

Project-local source references use a separate `read_artifact_source` request
instead of minting an unused download URL. The request is bound to the session,
message, artifact id, and Bridge-provided project-relative path. Bridge obtains
the current worktree roots from the live session, revalidates registry identity,
and reads at most 8 MiB from the same verified file handle. This prevents an old
Bridge from silently treating an identity-bound source click as an ordinary
path read and prevents a path or symlink swap between validation and File Peek.

Descriptors survive Bridge restarts for up to 180 days; the private generated
image cache follows the same retention window and is bounded to 5,000 managed
entries. Public tokens remain memory-only and expire after one hour by default.
A changed, removed, or newly out-of-scope file fails closed instead of silently
opening different content. New Gallery entries also retain the stable provider
session id internally, so resuming the same thread under a new runtime session
does not hide or repeatedly copy its generated drawings.
Clients that do not advertise `artifact_resolved` support ignore the optional
metadata and keep rendering the original message. Artifact resolve and source
read requests are one-shot RPCs: clients must not persist, queue, or replay them
after a reconnect.

To roll the feature back while retaining the existing manual `share` command:

```bash
BRIDGE_AUTO_ARTIFACTS=0 ccpocket-bridge setup
```

The launchd/systemd setup command persists this switch. Remove it or set it to
an enabling value and run setup again to re-enable automatic references.

## Persistent service setup

Register the Bridge as a user-level background service:

```bash
ccpocket-bridge setup
```

When working from this compatibility branch, build and register that exact
local CLI so service restarts cannot silently fall back to the official npm
package:

```bash
npm run bridge:build
node packages/bridge/dist/cli.js setup
```

Setup supports macOS launchd and Linux systemd. It persists the Bridge settings
that affect startup:

- `BRIDGE_PORT` / `--port`
- `BRIDGE_HOST` / `--host`
- `BRIDGE_API_KEY` / `--api-key`
- `BRIDGE_ALLOWED_DIRS`
- `BRIDGE_PUBLIC_WS_URL` / `--public-ws-url`
- `BRIDGE_ARTIFACT_BASE_URL` / `--artifact-base-url`
- `BRIDGE_AUTO_ARTIFACTS`
- `BRIDGE_ARTIFACT_REGISTRY_FILE`
- `BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR`
- `BRIDGE_FILE_TRANSFER_PARTIAL_DIR`
- `BRIDGE_FILE_TRANSFER_STATE_FILE`
- `BRIDGE_DISABLE_MDNS` / `--no-mdns`
- `BRIDGE_CODEX_APP_SERVER_MODE` / `--codex-app-server-mode`
- `BRIDGE_CODEX_SHARED_APP_SERVER_URL` / `--codex-shared-app-server-url`
- `BRIDGE_CODEX_ASSIST_MODEL`
- `BRIDGE_CODEX_ASSIST_REASONING_EFFORT`

Example:

```bash
BRIDGE_ALLOWED_DIRS="$HOME,/scratch/$USER" \
BRIDGE_API_KEY=my-secret \
node packages/bridge/dist/cli.js setup
```

Custom gateway users can persist assist overrides in the same way:

```bash
BRIDGE_CODEX_ASSIST_MODEL=gpt-oss:20b-cloud \
BRIDGE_CODEX_ASSIST_REASONING_EFFORT=none \
npx @ccpocket/bridge@latest setup
```

On Linux, setup gives standalone Codex installs priority by including
`$HOME/.local/bin` before npm-managed Node paths in the service `PATH`.

## Experimental: Join a CC Pocket Codex Session from Codex CLI

By default, each Codex session uses a private app-server. To let Codex CLI join
the same live thread that CC Pocket started, run the Bridge with shared
app-server mode:

```bash
BRIDGE_CODEX_APP_SERVER_MODE=managed \
BRIDGE_CODEX_SHARED_APP_SERVER_URL=ws://127.0.0.1:8767 \
npx @ccpocket/bridge@latest
```

Then start or resume a Codex session from CC Pocket. When the session is ready,
the session screen can copy a session-specific command like:

```bash
codex resume <thread-id> --remote ws://127.0.0.1:8767
```

Run that command in a terminal on the same machine as the Bridge. The
`127.0.0.1` address is for the Mac/Linux machine running the Bridge and Codex
CLI, not for the phone.

Modes:

- `private`: default behavior. No Codex CLI co-presence.
- `managed`: Bridge starts one local WebSocket Codex app-server and shares it
  with Codex CLI.
- `external`: Bridge connects to an already-running app-server. In this mode,
  `BRIDGE_CODEX_SHARED_APP_SERVER_URL` is required.

This is experimental and currently targets Codex CLI co-presence only. Codex App
compatibility is not guaranteed and may use a different integration model in the
future.

## Requirements

- Node.js v20.18.1+
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) and/or [Codex CLI](https://github.com/openai/codex)

Current Codex CLI docs recommend the standalone installer for macOS/Linux:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

## Health Check

Run the built-in doctor command to verify your environment:

```bash
npx @ccpocket/bridge@latest doctor
```

It checks Node.js, Git, CLI providers, macOS permissions (Screen Recording, Keychain), network connectivity, and more.

## Architecture

```
Mobile App ←WebSocket→ Bridge Server ←stdio→ Claude Code CLI
```

The bridge server spawns and manages Claude Code CLI processes, translating WebSocket messages to/from the CLI's stdio interface. It supports multiple concurrent sessions.

## License

This package is GPL-2.0-only as part of this CC Pocket compatibility fork. See
[LICENSE](./LICENSE), the repository root [LICENSE](../../LICENSE), and the
retained upstream notices in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
