import type {
  ProviderThreadSnapshot,
  ThreadRef,
} from "../domain/conversation.js";

/**
 * Provider transport seam. Implementations return one isolated snapshot; the
 * receive core never invents provider cursors or performs durable writes.
 */
export interface ProviderHistoryReader {
  readThread(thread: ThreadRef): Promise<ProviderThreadSnapshot>;
}

export class ProviderHistoryReadError extends Error {
  readonly code: string;

  constructor(code: string, message = code) {
    super(message);
    this.name = "ProviderHistoryReadError";
    this.code = code;
  }
}

export class ProviderHistoryTimeoutError extends ProviderHistoryReadError {
  constructor(message = "provider history read timed out") {
    super("provider_history_timeout", message);
    this.name = "ProviderHistoryTimeoutError";
  }
}
