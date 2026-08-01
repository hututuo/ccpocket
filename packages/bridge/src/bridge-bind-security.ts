import { isLoopbackAddress } from "./bridge-http-auth.js";

export const DEFAULT_BRIDGE_HOST = "127.0.0.1";

export function assertSecureBridgeBinding(input: {
  host: string;
  apiKey?: string;
  allowUnauthenticatedRemote?: boolean;
}): void {
  const host = normalizeHost(input.host);
  if (isLoopbackHost(host)) return;
  if (input.apiKey?.trim()) return;
  if (input.allowUnauthenticatedRemote === true) return;
  throw new Error(
    "Refusing to expose CC Pocket Bridge beyond loopback without BRIDGE_API_KEY. Set an API key, bind BRIDGE_HOST=127.0.0.1, or explicitly opt into legacy insecure exposure with BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE=1.",
  );
}

function normalizeHost(value: string): string {
  const trimmed = value.trim().toLowerCase();
  return trimmed.startsWith("[") && trimmed.endsWith("]")
    ? trimmed.slice(1, -1)
    : trimmed;
}

function isLoopbackHost(host: string): boolean {
  return host === "localhost" || isLoopbackAddress(host);
}
