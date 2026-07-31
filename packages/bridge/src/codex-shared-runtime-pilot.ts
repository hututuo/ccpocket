import { readCodexAppServerMode } from "./codex-app-server-config.js";

export type SharedRuntimeAttachMode = "observer" | "adoption";

export interface SharedRuntimePilotGates {
  enabled: true;
  codexSourceId: string;
  allowThreadStart: boolean;
  allowTurnStart: boolean;
}

const attachmentOwners = new Map<string, object>();

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
  if (method === "thread/start" || method === "thread/name/set") {
    if (gates.allowThreadStart) return;
    throw new Error(
      `${method} is disabled; set BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START=1 for the isolated canary`,
    );
  }
  if (method === "turn/start" || method === "turn/interrupt") {
    if (attachMode !== "observer" && gates.allowTurnStart) return;
    throw new Error(
      `${method} is disabled; set BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START=1 for the isolated canary`,
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
): string | null {
  if (gates === null) return null;
  const key = `${gates.codexSourceId}\u0000${threadId}`;
  const current = attachmentOwners.get(key);
  if (current && current !== owner) {
    throw new Error(
      "A shared-runtime attachment already exists for this Codex thread",
    );
  }
  attachmentOwners.set(key, owner);
  return key;
}

export function releaseSharedRuntimePilotAttachment(
  owner: object,
  key: string | null,
): void {
  if (!key) return;
  if (attachmentOwners.get(key) === owner) attachmentOwners.delete(key);
}

/** Test-only visibility without exposing source identity or thread ids. */
export function sharedRuntimePilotAttachmentCount(): number {
  return attachmentOwners.size;
}
