import { request } from "node:http";
import { validateFileTransferBaseUrl } from "./file-transfer-utils.js";
import {
  FILE_TRANSFER_ID_PATTERN,
  FILE_TRANSFER_MAX_FILE_SIZE_BYTES,
} from "./file-transfer-constants.js";

export interface SendFileRequest {
  filePath: string;
  projectPath: string;
  port: number;
  ttlSeconds?: number;
  baseUrl?: string;
  /** Internal/test seam; CLI callers use the bounded defaults. */
  connectTimeoutMs?: number;
  /** Internal/test seam; closing the request also cancels the Bridge offer. */
  responseTimeoutMs?: number;
}

export interface SendFileResult {
  status: "offered";
  transferId: string;
  recipientCount: 1;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  expiresAt: string;
}

interface SendControlResponse extends Partial<SendFileResult> {
  error?: string;
  errorCode?: string;
}

export function parseFileTransferTtl(rawValue?: string): number | undefined {
  if (rawValue === undefined) return undefined;
  if (!/^\d+$/.test(rawValue)) {
    throw new Error("--ttl must be an integer number of seconds");
  }
  const value = Number(rawValue);
  if (!Number.isSafeInteger(value) || value < 60 || value > 86_400) {
    throw new Error("--ttl must be between 60 and 86400 seconds");
  }
  return value;
}

export async function sendFileViaBridge(
  input: SendFileRequest,
): Promise<SendFileResult> {
  if (input.baseUrl && !validateFileTransferBaseUrl(input.baseUrl)) {
    throw new Error(
      "--base-url must be a mobile-reachable http:// or https:// URL",
    );
  }
  const payload = Buffer.from(
    JSON.stringify({
      filePath: input.filePath,
      projectPath: input.projectPath,
      ttlSeconds: input.ttlSeconds,
      baseUrl: input.baseUrl,
    }),
  );
  const connectTimeoutMs = boundedTimeout(
    input.connectTimeoutMs,
    5_000,
    "connectTimeoutMs",
  );
  const responseTimeoutMs = boundedTimeout(
    input.responseTimeoutMs,
    30_000,
    "responseTimeoutMs",
  );

  return new Promise((resolve, reject) => {
    let connected = false;
    let settled = false;
    let connectTimer: NodeJS.Timeout | undefined;
    let responseTimer: NodeJS.Timeout | undefined;
    const clearTimers = (): void => {
      if (connectTimer) clearTimeout(connectTimer);
      if (responseTimer) clearTimeout(responseTimer);
    };
    const rejectOnce = (error: Error): void => {
      if (settled) return;
      settled = true;
      clearTimers();
      reject(error);
    };
    const resolveOnce = (result: SendFileResult): void => {
      if (settled) return;
      settled = true;
      clearTimers();
      resolve(result);
    };
    const req = request(
      {
        hostname: "127.0.0.1",
        port: input.port,
        path: "/api/file-transfers/send",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": payload.length,
          "X-CCPocket-Control": "1",
        },
      },
      (res) => {
        let responseEnded = false;
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (chunk: string) => {
          if (body.length < 64 * 1024) body += chunk;
        });
        res.once("aborted", () => {
          rejectOnce(new Error("The local Bridge response ended before completion"));
        });
        res.once("error", (error) => {
          rejectOnce(
            new Error(`The local Bridge response failed: ${error.message}`),
          );
        });
        res.once("close", () => {
          if (!responseEnded) {
            rejectOnce(
              new Error("The local Bridge response ended before completion"),
            );
          }
        });
        res.on("end", () => {
          responseEnded = true;
          let parsed: SendControlResponse;
          try {
            parsed = JSON.parse(body) as SendControlResponse;
          } catch {
            rejectOnce(
              new Error(`Bridge returned HTTP ${res.statusCode ?? 0}`),
            );
            return;
          }
          if (res.statusCode !== 202 || !validSendResult(parsed)) {
            rejectOnce(
              new Error(
                parsed.error ?? `Bridge returned HTTP ${res.statusCode ?? 0}`,
              ),
            );
            return;
          }
          resolveOnce(parsed);
        });
      },
    );
    connectTimer = setTimeout(() => {
      if (!connected) {
        req.destroy(new Error("Timed out connecting to the local Bridge"));
      }
    }, connectTimeoutMs);
    connectTimer.unref();
    req.once("socket", (socket) => {
      const didConnect = (): void => {
        if (connected) return;
        connected = true;
        if (connectTimer) clearTimeout(connectTimer);
        responseTimer = setTimeout(() => {
          req.destroy(new Error("Timed out waiting for the local Bridge response"));
        }, responseTimeoutMs);
        responseTimer.unref();
      };
      if (socket.connecting) socket.once("connect", didConnect);
      else didConnect();
    });
    req.once("close", () => {
      if (connectTimer) clearTimeout(connectTimer);
    });
    req.on("error", (error) => {
      if (error.message.startsWith("Timed out ")) {
        rejectOnce(error);
        return;
      }
      rejectOnce(
        new Error(
          `Unable to reach the local Bridge on 127.0.0.1:${input.port}: ${error.message}`,
        ),
      );
    });
    req.end(payload);
  });
}

function boundedTimeout(
  value: number | undefined,
  fallback: number,
  field: string,
): number {
  const timeout = value ?? fallback;
  if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 120_000) {
    throw new Error(`${field} must be between 1 and 120000 milliseconds`);
  }
  return timeout;
}

function validSendResult(value: SendControlResponse): value is SendFileResult {
  return (
    value.status === "offered" &&
    typeof value.transferId === "string" && FILE_TRANSFER_ID_PATTERN.test(value.transferId) &&
    value.recipientCount === 1 &&
    typeof value.filename === "string" && value.filename.length > 0 && Buffer.byteLength(value.filename, "utf8") <= 240 &&
    typeof value.mimeType === "string" && value.mimeType.length > 0 &&
    typeof value.sizeBytes === "number" && Number.isSafeInteger(value.sizeBytes) &&
      value.sizeBytes >= 0 && value.sizeBytes <= FILE_TRANSFER_MAX_FILE_SIZE_BYTES &&
    typeof value.expiresAt === "string" &&
      Number.isFinite(Date.parse(value.expiresAt)) &&
      Date.parse(value.expiresAt) > Date.now()
  );
}
