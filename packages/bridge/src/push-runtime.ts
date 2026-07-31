import type { FirebaseAuthClient } from "./firebase-auth.js";

const EXPLICIT_FALSE_VALUES = new Set(["0", "false", "no", "off"]);

/**
 * A push kill switch is deliberately fail-closed: once the variable is set,
 * only an explicit false value keeps the historical default enabled. This
 * prevents a misspelling in an isolation environment from contacting Firebase
 * or the Cloud relay.
 */
export function pushInitializationDisabled(
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  const raw = env.BRIDGE_DISABLE_PUSH;
  if (raw === undefined) return false;
  return !EXPLICIT_FALSE_VALUES.has(raw.trim().toLowerCase());
}

export interface InitializePushRuntimeOptions {
  env?: NodeJS.ProcessEnv;
  createClient: () => FirebaseAuthClient;
  log?: (message: string) => void;
  warn?: (message: string, error?: unknown) => void;
}

/**
 * Create and initialize Firebase only when push is enabled. Keeping the
 * factory behind the kill switch is important: the isolated pilot must not
 * even construct an auth/token client, let alone read credentials or perform
 * a network request.
 */
export async function initializePushRuntime(
  options: InitializePushRuntimeOptions,
): Promise<FirebaseAuthClient | undefined> {
  const log = options.log ?? ((message: string) => console.log(message));
  const warn =
    options.warn ??
    ((message: string, error?: unknown) => console.warn(message, error));

  if (pushInitializationDisabled(options.env)) {
    log("[bridge] Push relay disabled by configuration");
    return undefined;
  }

  try {
    const client = options.createClient();
    await client.initialize();
    log("[bridge] Push relay enabled (Firebase Anonymous Auth)");
    return client;
  } catch (error) {
    warn("[bridge] Push relay disabled: Firebase auth failed:", error);
    return undefined;
  }
}
