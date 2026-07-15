import { getReachableAddresses, validatePublicWsUrl } from "./startup-info.js";

interface ReachableAddress {
  ip: string;
  label: string;
}

export interface ArtifactBaseUrlOptions {
  port: number;
  host: string;
  explicitBaseUrl?: string;
  publicWsUrl?: string;
  addresses?: ReachableAddress[];
}

function isLoopbackOrWildcardHost(hostname: string): boolean {
  const lower = hostname.toLowerCase();
  const normalized =
    lower.startsWith("[") && lower.endsWith("]")
      ? lower.slice(1, -1)
      : lower;
  return (
    normalized === "localhost" ||
    normalized === "0.0.0.0" ||
    normalized === "::" ||
    normalized === "::1" ||
    normalized.startsWith("::ffff:7f") ||
    normalized.startsWith("127.")
  );
}

function formatHost(host: string): string {
  return host.includes(":") && !host.startsWith("[") ? `[${host}]` : host;
}

export function validateArtifactBaseUrl(rawUrl?: string): string | undefined {
  const trimmed = rawUrl?.trim();
  if (!trimmed) return undefined;

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return undefined;
  }

  if (
    (parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
    !parsed.hostname ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash ||
    (parsed.pathname !== "" && parsed.pathname !== "/") ||
    isLoopbackOrWildcardHost(parsed.hostname)
  ) {
    return undefined;
  }

  return parsed.toString().replace(/\/$/, "");
}

export function httpBaseUrlFromPublicWsUrl(
  rawUrl?: string,
): string | undefined {
  const validWsUrl = validatePublicWsUrl(rawUrl);
  if (!validWsUrl) return undefined;

  const parsed = new URL(validWsUrl);
  if (
    parsed.username ||
    parsed.password ||
    isLoopbackOrWildcardHost(parsed.hostname)
  ) {
    return undefined;
  }

  parsed.protocol = parsed.protocol === "wss:" ? "https:" : "http:";
  parsed.pathname = "";
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString().replace(/\/$/, "");
}

export function resolveArtifactBaseUrl(
  options: ArtifactBaseUrlOptions,
): string | undefined {
  if (options.explicitBaseUrl?.trim()) {
    const explicit = validateArtifactBaseUrl(options.explicitBaseUrl);
    if (!explicit) {
      throw new Error(
        `Invalid BRIDGE_ARTIFACT_BASE_URL "${options.explicitBaseUrl}"`,
      );
    }
    return explicit;
  }

  const publicOrigin = httpBaseUrlFromPublicWsUrl(options.publicWsUrl);
  if (publicOrigin) return publicOrigin;

  if (!isLoopbackOrWildcardHost(options.host)) {
    return `http://${formatHost(options.host)}:${options.port}`;
  }

  const addresses = options.addresses ?? getReachableAddresses();
  const address =
    addresses.find((candidate) => candidate.label === "LAN") ?? addresses[0];
  if (!address) return undefined;
  return `http://${formatHost(address.ip)}:${options.port}`;
}

export function buildArtifactPreviewUrl(
  baseUrl: string,
  token: string,
): string {
  return `${baseUrl.replace(/\/+$/, "")}/artifacts/${token}`;
}

export function escapeMarkdownLabel(label: string): string {
  return label.replace(/([\\\[\]])/g, "\\$1").replace(/[\r\n]+/g, " ");
}

export function buildArtifactMarkdown(
  filename: string,
  previewUrl: string,
): string {
  return `[预览并下载 ${escapeMarkdownLabel(filename)}](${previewUrl})`;
}
