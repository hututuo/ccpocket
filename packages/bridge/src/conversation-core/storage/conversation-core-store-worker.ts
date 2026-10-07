import { parentPort, workerData } from "node:worker_threads";

import { ConversationCoreStore } from "./conversation-core-store.js";
import type { StoreOpenOptions } from "./types.js";

interface WorkerRequest {
  id: number;
  method: string;
  args: unknown[];
}

interface WorkerOpenData {
  filePath: string;
  writerLeaseTtlMs?: number;
}

const port = parentPort;
if (!port) throw new Error("conversation core store worker requires a parent port");

const data = workerData as WorkerOpenData;
let store: ConversationCoreStore | undefined;
let heartbeat: NodeJS.Timeout | undefined;

try {
  const options: StoreOpenOptions = {
    filePath: data.filePath,
    ...(data.writerLeaseTtlMs ? { writerLeaseTtlMs: data.writerLeaseTtlMs } : {}),
  };
  store = ConversationCoreStore.open(options);
  const heartbeatMs = Math.max(100, Math.floor((data.writerLeaseTtlMs ?? 30_000) / 3));
  heartbeat = setInterval(() => {
    try {
      store?.renewWriterLease();
    } catch (error) {
      port.postMessage({ type: "fatal", error: serializeError(error) });
      process.exitCode = 1;
      port.close();
    }
  }, heartbeatMs);
  heartbeat.unref();
  port.postMessage({ type: "ready" });
} catch (error) {
  port.postMessage({ type: "fatal", error: serializeError(error) });
  port.close();
}

port.on("message", (request: WorkerRequest) => {
  if (request.method === "__testCrash") {
    process.exit(86);
  }
  if (!store || !ALLOWED_METHODS.has(request.method)) {
    port.postMessage({
      type: "response",
      id: request.id,
      error: serializeError(new Error(`unsupported store worker method ${request.method}`)),
    });
    return;
  }
  try {
    const method = (store as unknown as Record<string, (...args: unknown[]) => unknown>)[request.method];
    const result = method.apply(store, request.args);
    port.postMessage({ type: "response", id: request.id, result });
    if (request.method === "close") {
      if (heartbeat) clearInterval(heartbeat);
      port.close();
    }
  } catch (error) {
    port.postMessage({ type: "response", id: request.id, error: serializeError(error) });
  }
});

const ALLOWED_METHODS = new Set([
  "diagnostics",
  "beginTimelineMaterialization",
  "appendTimelinePage",
  "sealTimelineMaterialization",
  "readTimeline",
  "recordTimelineReadAttempt",
  "admitOperation",
  "beginIdleDispatch",
  "transitionOperation",
  "getOperation",
  "listOperationEvents",
  "listOperationsRequiringReconcile",
  "recordReconcileFact",
  "listReconcileResolutions",
  "openQueueLane",
  "admitAndQueue",
  "controlQueueEntry",
  "beginQueuedDispatch",
  "readQueueLane",
  "listQueueEntries",
  "openInteraction",
  "claimInteraction",
  "respondInteraction",
  "renewInteractionClaim",
  "releaseInteractionClaim",
  "resolveInteraction",
  "getInteraction",
  "getActiveClaim",
  "close",
]);

function serializeError(error: unknown): { name: string; message: string; code?: string; stack?: string } {
  const candidate = error instanceof Error ? error : new Error(String(error));
  const code = "code" in candidate && typeof candidate.code === "string" ? candidate.code : undefined;
  return {
    name: candidate.name,
    message: candidate.message,
    ...(code ? { code } : {}),
    ...(candidate.stack ? { stack: candidate.stack } : {}),
  };
}
