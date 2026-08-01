import { readCodexAppServerMode } from "./codex-app-server-config.js";

export type SharedRuntimeAttachMode = "observer" | "adoption";

export interface SharedRuntimePilotGates {
  enabled: true;
  codexSourceId: string;
  allowThreadStart: boolean;
  allowTurnStart: boolean;
}

interface SharedRuntimeAttachmentRecord {
  owner: object;
  mode: SharedRuntimeAttachMode;
  codexSourceId: string;
  threadId: string;
  onYield?: () => void;
}

type FormalAttachmentReleasedListener = (
  codexSourceId: string,
  threadId: string,
) => void;

const attachmentOwners = new Map<string, SharedRuntimeAttachmentRecord>();
const formalAttachmentReleasedListeners =
  new Set<FormalAttachmentReleasedListener>();

function readBinaryGate(
  env: NodeJS.ProcessEnv,
  name:
    | "BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START"
    | "BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START",
): boolean {
  const raw = env[name]?.trim();
  if (raw === undefined || raw === "" || raw === "0") return false;
  if (raw === "1") return true;
  throw new Error(`${name} must be exactly 0 or 1`);
}

export function readSharedRuntimePilotGates(
  env: NodeJS.ProcessEnv = process.env,
): SharedRuntimePilotGates {
  if (env.BRIDGE_CODEX_SHARED_PILOT?.trim() !== "1") {
    throw new Error(
      "Codex daemon mode is pilot-only; BRIDGE_CODEX_SHARED_PILOT=1 is required",
    );
  }
  const codexSourceId = env.BRIDGE_CODEX_SOURCE_ID?.trim();
  if (!codexSourceId) {
    throw new Error(
      "BRIDGE_CODEX_SOURCE_ID is required for shared-runtime attachment identity",
    );
  }
  return {
    enabled: true,
    codexSourceId,
    allowThreadStart: readBinaryGate(
      env,
      "BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START",
    ),
    allowTurnStart: readBinaryGate(
      env,
      "BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START",
    ),
  };
}

export function snapshotSharedRuntimePilotGates(
  env: NodeJS.ProcessEnv = process.env,
): SharedRuntimePilotGates | null {
  return readCodexAppServerMode(env) === "daemon"
    ? readSharedRuntimePilotGates(env)
    : null;
}

function isReadOnlyPilotRpc(method: string): boolean {
  return (
    method === "initialize" ||
    method === "thread/goal/get" ||
    method.endsWith("/read") ||
    method.endsWith("/list")
  );
}

/**
 * Stage 1 is deliberately not a general shared writer. Every daemon RPC goes
 * through this narrow allowlist until the later Action Broker owns mutation
 * serialization and recovery.
 */
export function assertSharedRuntimePilotRpcAllowed(
  method: string,
  attachMode: SharedRuntimeAttachMode | null,
  gates: SharedRuntimePilotGates | null,
): void {
  if (gates === null) return;
  if (isReadOnlyPilotRpc(method)) return;

  if (method === "thread/resume") {
    if (attachMode === null) {
      throw new Error(
        "Daemon thread/resume requires a settings-neutral shared runtime attach",
      );
    }
    return;
  }
  if (
    method === "thread/start" ||
    method === "thread/name/set" ||
    method === "thread/archive" ||
    method === "thread/unarchive" ||
    method === "thread/delete"
  ) {
    if (gates.allowThreadStart) return;
    throw new Error(
      `${method} is disabled; set BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START=1 for the isolated canary`,
    );
  }
  if (method === "thread/fork") {
    if (attachMode !== "observer" && gates.allowThreadStart) return;
    throw new Error(
      "thread/fork is disabled; the shared writer and thread-start pilot gate are required",
    );
  }
  if (method === "thread/settings/update") {
    if (attachMode === "adoption" && gates.allowTurnStart) return;
    throw new Error(
      "thread/settings/update is disabled; a formal shared writer and the turn-start pilot gate are required",
    );
  }
  if (method === "turn/start" || method === "turn/interrupt") {
    if (attachMode !== "observer" && gates.allowTurnStart) return;
    throw new Error(
      `${method} is disabled; set BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START=1 for the isolated canary`,
    );
  }
  if (
    method === "thread/goal/set" ||
    method === "thread/goal/clear" ||
    method === "thread/compact/start" ||
    method === "thread/rollback" ||
    method === "review/start"
  ) {
    if (attachMode === "adoption" && gates.allowTurnStart) return;
    throw new Error(
      `${method} is disabled; a formal shared writer and the turn-start pilot gate are required`,
    );
  }

  throw new Error(
    `${method} is not allowed by the Stage 1 shared-runtime pilot`,
  );
}

export function claimSharedRuntimePilotAttachment(
  owner: object,
  threadId: string,
  gates: SharedRuntimePilotGates | null,
  mode: SharedRuntimeAttachMode = "adoption",
  onYield?: () => void,
): string | null {
  if (gates === null) return null;
  const key = `${gates.codexSourceId}\u0000${threadId}`;
  const current = attachmentOwners.get(key);
  if (current?.owner === owner) return key;

  if (current && mode === "observer") {
    throw new Error(
      current.mode === "adoption"
        ? "A formal shared-runtime attachment is pending or active for this Codex thread"
        : "A shared-runtime observer attachment already exists for this Codex thread",
    );
  }

  if (current?.mode === "adoption") {
    throw new Error(
      "A formal shared-runtime attachment already exists for this Codex thread",
    );
  }

  // Formal adoption/recovery wins atomically. Install its reservation before
  // asking the read-only observer to yield so a synchronous observer retry
  // cannot reclaim the slot in the handoff window.
  const next: SharedRuntimeAttachmentRecord = {
    owner,
    mode,
    codexSourceId: gates.codexSourceId,
    threadId,
    ...(mode === "observer" && onYield ? { onYield } : {}),
  };
  attachmentOwners.set(key, next);
  if (current?.mode === "observer") {
    try {
      current.onYield?.();
    } catch {
      // The formal reservation remains authoritative even if an observer's
      // best-effort shutdown callback fails. It is read-only and cannot
      // become a second writer.
    }
  }
  return key;
}

export function releaseSharedRuntimePilotAttachment(
  owner: object,
  key: string | null,
): void {
  if (!key) return;
  const current = attachmentOwners.get(key);
  if (current?.owner !== owner) return;
  attachmentOwners.delete(key);
  if (current.mode !== "adoption") return;
  for (const listener of formalAttachmentReleasedListeners) {
    try {
      listener(current.codexSourceId, current.threadId);
    } catch {
      // One observer coordinator must not prevent other sources/clients from
      // seeing the formal-release boundary.
    }
  }
}

/**
 * Prevent observer churn while a formal adoption/recovery owns the exact
 * source/thread slot. Production passes the authenticated source identity;
 * direct callers may fall back to the already-validated pilot environment.
 */
export function isSharedRuntimePilotObserverBlocked(
  threadId: string,
  codexSourceId?: string,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  const sourceId =
    codexSourceId ?? snapshotSharedRuntimePilotGates(env)?.codexSourceId;
  if (!sourceId) return false;
  const key = `${sourceId}\u0000${threadId}`;
  return attachmentOwners.get(key)?.mode === "adoption";
}

export function subscribeSharedRuntimePilotFormalAttachmentReleased(
  listener: FormalAttachmentReleasedListener,
): () => void {
  formalAttachmentReleasedListeners.add(listener);
  return () => formalAttachmentReleasedListeners.delete(listener);
}

/** Test-only visibility without exposing source identity or thread ids. */
export function sharedRuntimePilotAttachmentCount(): number {
  return attachmentOwners.size;
}
