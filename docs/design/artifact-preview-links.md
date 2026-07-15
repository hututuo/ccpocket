# Temporary Artifact Preview Links

Status: active design for `compat/artifact-download`

## Goal

Let an agent running through CC Pocket publish a file from the Bridge machine
and reply with an ordinary absolute Markdown link. Tapping the link opens a
responsive browser preview page with an explicit download fallback.

The first implementation must not change the Flutter app, WebSocket protocol,
session history, provider transcript, GalleryStore, or ImageStore.

## User flow

```text
ccpocket-bridge share /absolute/path/report.docx
  -> loopback-only POST to the running Bridge
  -> in-memory capability token with a short TTL
  -> [Preview report.docx](http://bridge:8765/artifacts/<token>)
  -> mobile Markdown opens the system browser
  -> preview page renders the file or offers system-open and download actions
```

## Compatibility boundary

- Reuse the existing Bridge HTTP/WebSocket port.
- Return plain Markdown `TextContent`; add no artifact protocol message.
- Do not rewrite assistant text or streaming deltas. Explicit publication keeps
  Bridge history identical to provider output and avoids ambiguous path regexes.
- Keep the implementation in new artifact modules plus small delegations from
  `index.ts` and `cli.ts` so upstream rebases have a narrow conflict surface.

## Routes

- `POST /api/artifacts` publishes a path. It is a local control route.
- `GET /artifacts/:token` returns the preview shell.
- `GET|HEAD /artifacts/:token/content` returns inline file content.
- `GET|HEAD /artifacts/:token/download` returns attachment content.
- No list, delete, directory, or path-based public endpoint is exposed.

Artifact routes are dispatched before the existing global CORS headers. They
must never inherit `Access-Control-Allow-Origin: *`.

## Local publish trust boundary

The control request must satisfy all of the following:

- source address is IPv4, IPv6, or IPv4-mapped loopback;
- no `Origin` header;
- `X-CCPocket-Control: 1` is present;
- `Content-Type` is `application/json`;
- body is at most 16 KiB.

The caller may provide `filePath`, `projectPath`, `ttlSeconds`, and an optional
HTTP(S) preview base URL. The response never contains the source path.

## Artifact security

- Token: 32 random bytes encoded as Base64URL.
- Default TTL: one hour; allowed range: 60 seconds to 24 hours.
- Maximum active entries: 100, with expired entries removed first.
- Maximum file size: 2 GiB.
- Store is memory-only. Restarting Bridge invalidates all links.
- Registration opens the file, resolves its canonical path, canonicalizes the
  allowed roots, and verifies the opened descriptor belongs to that path.
- Only regular files inside `BRIDGE_ALLOWED_DIRS` are accepted.
- Registration records device, inode, size, and modification time. A deleted
  file returns 410; a changed/replaced file returns 409 and must be republished.
- Public URLs contain only a capability token, never a path or filename.
- Tokens, full URLs, and source paths are not written to normal logs.

Previewing PDFs can create many range requests, so TTL is the primary lifetime
control. The first version intentionally does not use a fragile per-request
download counter.

## Content serving

- Stream through an opened file descriptor; never load a general file fully
  into memory.
- Support one byte range (`start-end`, `start-`, or `-suffix`).
- Return 206 with exact `Content-Range`; invalid/multiple ranges return 416.
- `HEAD` returns full metadata without a body and ignores Range.
- Send `Content-Length`, `Accept-Ranges: bytes`, `Cache-Control: private,
  no-store, max-age=0`, `X-Content-Type-Options: nosniff`, and
  `Referrer-Policy: no-referrer`.
- `/content` uses `Content-Disposition: inline`; `/download` uses `attachment`.
- Both ASCII `filename` and UTF-8 RFC 5987 `filename*` are sanitized.

## Preview strategy

The preview page is a self-contained responsive HTML shell with file metadata,
expiry information, system-open, and download actions.

- Images: responsive native image preview.
- PDF: native browser PDF frame. PDF.js is not bundled because Safari already
  provides a mature viewer and the PDF.js viewer/worker would add substantial
  package weight.
- Text, source, Markdown, JSON, CSV, and logs: escaped, size-limited text
  preview with line numbers; the full file remains available through download.
- Audio and video: native media controls.
- DOCX: render client-side with the Apache-2.0 `docx-preview` package.
- XLSX/PPTX and unknown formats: polished metadata fallback with a direct
  system-open action and download. iOS Quick Look supports Microsoft Office
  documents; heavy document-server stacks are intentionally out of scope.

The page ships no remote CDN code and sends a restrictive Content Security
Policy. An artifact token is never disclosed to third-party viewers.

## Base URL selection

The preview URL must be absolute. Resolution order:

1. `ccpocket-bridge share --base-url http(s)://...`
2. `BRIDGE_ARTIFACT_BASE_URL`
3. HTTP(S) origin derived from `BRIDGE_PUBLIC_WS_URL`
4. the same LAN-first address selection used by official startup output

Loopback, wildcard, or relative URLs are not suitable for mobile delivery.

## Verification gates

- Unit tests for tokens, TTL, allowed roots, symlink escape, file identity,
  headers, filename encoding, preview kinds, and range parsing.
- HTTP tests for loopback publish, remote rejection, CORS absence, preview,
  inline content, attachment download, HEAD, 206, 409, 410, 413, 415, and 416.
- CLI tests for argument parsing, JSON/Markdown output, spaces/Unicode, invalid
  base URLs, and Bridge-unavailable failure.
- Regression checks for health, version, Gallery, images, and WebSocket startup.
- Full Bridge Vitest, TypeScript check, production build, and a LAN curl
  round-trip whose SHA-256 matches the source.
- Final manual iPhone click test for the preview page and download action.
