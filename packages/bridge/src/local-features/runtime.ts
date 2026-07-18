import type { CodexProcess } from "../codex-process.js";
import type { ClientMessage } from "../parser.js";
import type {
  LocalFeatureClientMessage,
  LocalFeatureServerMessage,
} from "./protocol.js";

export interface LocalFeatureSession {
  id: string;
  provider: string;
  process: unknown;
}

export interface LocalFeatureRuntime {
  /** Stable installation identity; persisted by the Bridge host when available. */
  readonly bridgeInstanceId?: string;
  getSession(sessionId: string): LocalFeatureSession | undefined;
  getCodexThreadId(session: LocalFeatureSession): string | undefined;
  getActiveCodexProcess(): CodexProcess | null;
  createStandaloneCodexProcess(
    timeoutMs?: number,
    projectPath?: string,
  ): Promise<CodexProcess>;
  createDedicatedCodexProcess?(): CodexProcess;
  /** Host-owned authorization seam for optional features that accept a cwd. */
  isProjectPathAllowed?(projectPath: string): boolean;
  send(client: object, message: LocalFeatureServerMessage | {
    type: "error";
    message: string;
    errorCode?: string;
  }): void;
  supports(client: object, serverMessageType: string): boolean;
}

export interface LocalFeatureHandleContext {
  client: object;
  signal: AbortSignal;
  runtime: LocalFeatureRuntime;
}

export interface LocalFeatureHandler {
  readonly messageTypes: readonly LocalFeatureClientMessage["type"][];
  handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void>;
  capabilitiesChanged?(client: object): void;
  disconnect?(client: object): void;
  close?(): void;
}

export function asLocalFeatureMessage(
  message: ClientMessage,
  expected: LocalFeatureClientMessage["type"],
): LocalFeatureClientMessage | null {
  return message.type === expected
    ? (message as LocalFeatureClientMessage)
    : null;
}
