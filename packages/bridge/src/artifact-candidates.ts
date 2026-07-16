import { marked, type Token } from "marked";
import { MAX_ARTIFACTS_PER_MESSAGE } from "./artifact-types.js";
import type {
  ArtifactCandidate,
  ArtifactLinkKind,
  ArtifactSource,
} from "./artifact-types.js";

export interface ExtractArtifactCandidateOptions {
  source?: ArtifactSource;
  textContentIndex?: number;
  platform?: NodeJS.Platform;
}

const URI_SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*:/;
const URI_WITH_AUTHORITY = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//;
const NON_FILE_SCHEMES = new Set([
  "app",
  "data",
  "ftp",
  "http",
  "https",
  "javascript",
  "mailto",
  "sandbox",
  "tel",
  "vscode",
  "ws",
  "wss",
]);
const WINDOWS_DRIVE_PATH = /^[A-Za-z]:[\\/]/;
const WINDOWS_UNC_PATH = /^\\\\[^\\]/;
const ENCODED_PATH_ESCAPE = /%(?:2f|5c|00)/i;
/** Bound full-message AST work; oversized messages are still forwarded intact. */
export const MAX_ARTIFACT_MARKDOWN_CHARS = 1024 * 1024;

function stripAngleBrackets(input: string): string {
  const trimmed = input.trim();
  if (trimmed.startsWith("<") && trimmed.endsWith(">")) {
    return trimmed.slice(1, -1).trim();
  }
  return trimmed;
}

function safeDecodePath(input: string): string | undefined {
  // Decoding encoded separators makes URL parsing and path authorization
  // disagree. Ordinary percent-encoded spaces and Unicode remain supported.
  if (ENCODED_PATH_ESCAPE.test(input)) return undefined;
  try {
    const decoded = decodeURIComponent(input);
    return decoded.includes("\0") || ENCODED_PATH_ESCAPE.test(decoded)
      ? undefined
      : decoded;
  } catch {
    return undefined;
  }
}

function fileUrlPath(
  input: string,
  platform: NodeJS.Platform,
): string | undefined {
  let parsed: URL;
  try {
    parsed = new URL(input);
  } catch {
    return undefined;
  }
  if (
    parsed.protocol !== "file:" ||
    parsed.username ||
    parsed.password ||
    parsed.search
  ) {
    return undefined;
  }

  const host = parsed.hostname;
  if (platform !== "win32" && host && host.toLowerCase() !== "localhost") {
    return undefined;
  }
  const decoded = safeDecodePath(parsed.pathname);
  if (!decoded) return undefined;

  if (platform !== "win32") return decoded;
  const windowsPath = decoded.replace(/\//g, "\\");
  if (host && host.toLowerCase() !== "localhost") {
    return `\\\\${host}${windowsPath}`;
  }
  return /^\\[A-Za-z]:\\/.test(windowsPath)
    ? windowsPath.slice(1)
    : windowsPath;
}

/**
 * Decode a Markdown href only when it denotes a local path. Web URLs,
 * sandbox/data URLs, fragments, and unknown URI schemes are intentionally
 * ignored.
 */
export function localPathFromArtifactHref(
  href: string,
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  const value = stripAngleBrackets(href);
  if (!value || value.startsWith("#") || value.includes("\0")) return undefined;

  if (WINDOWS_DRIVE_PATH.test(value) || WINDOWS_UNC_PATH.test(value)) {
    return safeDecodePath(value);
  }
  if (value.toLowerCase().startsWith("file:")) {
    return fileUrlPath(value, platform);
  }
  if (URI_SCHEME.test(value)) {
    const scheme = value.slice(0, value.indexOf(":")).toLowerCase();
    if (URI_WITH_AUTHORITY.test(value) || NON_FILE_SCHEMES.has(scheme)) {
      return undefined;
    }
    // A relative POSIX filename such as `notes:12` is indistinguishable from
    // a URI scheme until the filesystem is inspected. Keep only the numeric
    // location-shaped ambiguity; reject all other unknown schemes.
    if (!/^[^:]+:[0-9]+(?::[0-9]+)?$/.test(value)) return undefined;
  }
  return safeDecodePath(value);
}

function isLinkToken(token: Token): token is Token & {
  type: "link" | "image";
  href: string;
  text: string;
} {
  return (
    (token.type === "link" || token.type === "image") &&
    typeof (token as { href?: unknown }).href === "string"
  );
}

function uncTargetBeforeMarkdownUnescape(
  token: Token & { href: string },
  platform: NodeJS.Platform,
): string | undefined {
  if (
    platform !== "win32" ||
    !token.href.startsWith("\\") ||
    token.href.startsWith("\\\\")
  ) {
    return undefined;
  }
  const raw = (token as { raw?: unknown }).raw;
  if (typeof raw !== "string" || !raw.endsWith(")")) return undefined;
  const targetStart = raw.lastIndexOf("](");
  if (targetStart < 0) return undefined;
  let target = raw.slice(targetStart + 2, -1).trim();
  if (target.startsWith("<")) {
    const end = target.indexOf(">");
    if (end < 0) return undefined;
    target = target.slice(1, end);
  } else {
    // Unwrapped UNC paths cannot contain literal spaces in Markdown targets.
    target = target.split(/\s/, 1)[0];
  }
  return target.startsWith("\\\\") ? target : undefined;
}

/**
 * Extract explicit local link/image targets from a complete Markdown message.
 * Marked's AST never exposes links nested inside fenced or inline code as link
 * nodes, which is the security boundary this extractor relies on.
 */
export function extractArtifactCandidates(
  markdown: string,
  options: ExtractArtifactCandidateOptions = {},
): ArtifactCandidate[] {
  if (markdown.length > MAX_ARTIFACT_MARKDOWN_CHARS || !markdown.trim()) {
    return [];
  }

  const source = options.source ?? "assistant_markdown";
  const platform = options.platform ?? process.platform;
  const candidates: ArtifactCandidate[] = [];
  const seen = new Set<string>();
  const tokens = marked.lexer(markdown, { gfm: true });

  marked.walkTokens(tokens, (token) => {
    if (candidates.length >= MAX_ARTIFACTS_PER_MESSAGE) return;
    if (!isLinkToken(token)) return;
    const localPath = localPathFromArtifactHref(
      uncTargetBeforeMarkdownUnescape(token, platform) ?? token.href,
      platform,
    );
    if (!localPath) return;

    const linkKind: ArtifactLinkKind =
      token.type === "image" ? "image" : "link";
    const key = `${linkKind}\0${token.href}\0${localPath}\0${options.textContentIndex ?? ""}`;
    if (seen.has(key)) return;
    seen.add(key);
    candidates.push({
      source,
      linkKind,
      localPath,
      originalHref: token.href,
      label: token.text || undefined,
      textContentIndex: options.textContentIndex,
    });
  });

  return candidates;
}

export function createPathArtifactCandidate(
  localPath: string,
  options: {
    source: ArtifactSource;
    linkKind?: ArtifactLinkKind;
    label?: string;
    textContentIndex?: number;
  },
): ArtifactCandidate {
  return {
    source: options.source,
    linkKind: options.linkKind ?? "generated",
    localPath,
    label: options.label,
    textContentIndex: options.textContentIndex,
  };
}
