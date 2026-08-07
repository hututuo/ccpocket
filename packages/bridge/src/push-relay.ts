import { createHash } from "node:crypto";
import type { FirebaseAuthClient } from "./firebase-auth.js";

export type PushPlatform = "ios" | "android" | "web";

export interface PushNotifyPayload {
  eventType: string;
  title: string;
  body: string;
  /** When set, only tokens registered with this locale receive the notification. */
  locale?: string;
  data?: Record<string, string>;
  /** Tokens that already displayed the same event through live local delivery. */
  excludedTokens?: string[];
}

export interface PushRelayClientOptions {
  relayUrl?: string;
  firebaseAuth?: FirebaseAuthClient | null;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
  tokenOperationMaxAttempts?: number;
  retryDelay?: (delayMs: number) => Promise<void>;
}

type PushRelayOpPayload =
  | {
      op: "register";
      token: string;
      platform: PushPlatform;
      locale?: string;
      enabledEventTypes?: string[];
      approvalActionsSupported?: boolean;
      approvalActionsVersion?: 1 | 2;
    }
  | { op: "unregister"; token: string }
  | {
      op: "notify";
      eventType: string;
      title: string;
      body: string;
      locale?: string;
      data?: Record<string, string>;
      excludedTokens?: string[];
    };

type PushRelayRequestPayload = PushRelayOpPayload & { bridgeId: string };

const DEFAULT_RELAY_URL =
  "https://us-central1-ccpocket-ca33b.cloudfunctions.net/relay";
const DEFAULT_TOKEN_OPERATION_MAX_ATTEMPTS = 3;
const DEFAULT_RETRY_BASE_DELAY_MS = 250;

class PushRelayHttpError extends Error {
  constructor(readonly status: number) {
    super(`Push relay returned ${status}`);
    this.name = "PushRelayHttpError";
  }
}

export class PushRelayClient {
  private readonly relayUrl: string;
  private readonly firebaseAuth: FirebaseAuthClient | null;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;
  private readonly tokenOperationMaxAttempts: number;
  private readonly retryDelay: (delayMs: number) => Promise<void>;

  constructor(options: PushRelayClientOptions = {}) {
    this.relayUrl = options.relayUrl ?? DEFAULT_RELAY_URL;
    this.firebaseAuth = options.firebaseAuth ?? null;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
    const configuredAttempts = options.tokenOperationMaxAttempts;
    this.tokenOperationMaxAttempts =
      typeof configuredAttempts === "number" &&
      Number.isFinite(configuredAttempts)
        ? Math.min(5, Math.max(1, Math.floor(configuredAttempts)))
        : DEFAULT_TOKEN_OPERATION_MAX_ATTEMPTS;
    this.retryDelay =
      options.retryDelay ??
      ((delayMs) =>
        new Promise((resolve) => {
          const timer = setTimeout(resolve, delayMs);
          timer.unref?.();
        }));
  }

  get isConfigured(): boolean {
    return this.firebaseAuth != null;
  }

  private get bridgeId(): string {
    return this.firebaseAuth!.uid;
  }

  async registerToken(
    token: string,
    platform: PushPlatform,
    locale?: string,
    enabledEventTypes?: string[],
    approvalActionsSupported?: boolean,
    approvalActionsVersion?: 1 | 2,
  ): Promise<void> {
    if (!this.isConfigured) return;
    await this.post({
      op: "register",
      token,
      platform,
      locale,
      enabledEventTypes,
      approvalActionsSupported,
      approvalActionsVersion,
    });
  }

  async unregisterToken(token: string): Promise<void> {
    if (!this.isConfigured) return;
    await this.post({ op: "unregister", token });
  }

  async notify(payload: PushNotifyPayload): Promise<void> {
    if (!this.isConfigured) return;
    await this.post({
      op: "notify",
      eventType: payload.eventType,
      title: payload.title,
      body: payload.body,
      locale: payload.locale,
      data: payload.data,
      excludedTokens: payload.excludedTokens,
    });
  }

  private async post(payload: PushRelayOpPayload): Promise<void> {
    if (!this.isConfigured || !this.firebaseAuth) return;

    const idToken = await this.firebaseAuth.getIdToken();
    const requestPayload: PushRelayRequestPayload = {
      ...payload,
      bridgeId: this.bridgeId,
    };
    const logBridgeId = createHash("sha256")
      .update(requestPayload.bridgeId, "utf8")
      .digest("hex")
      .slice(0, 12);
    console.log(
      `[push-relay] ${payload.op} → ${this.relayUrl} (bridge: ${logBridgeId})`,
    );
    // Registration and unregistration are idempotent Cloud writes, so a
    // bounded retry is safe. Notification delivery is deliberately
    // at-most-once until the relay has server-side deliveryId deduplication;
    // retrying an ambiguous response could otherwise alert the user twice.
    const maxAttempts =
      payload.op === "notify" ? 1 : this.tokenOperationMaxAttempts;
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        await this.postOnce(requestPayload, idToken);
        console.log(`[push-relay] ${payload.op} OK`);
        return;
      } catch (error) {
        if (attempt >= maxAttempts || !isRetryableRelayFailure(error)) {
          throw error;
        }
        const delayMs = DEFAULT_RETRY_BASE_DELAY_MS * 2 ** (attempt - 1);
        console.warn(
          `[push-relay] ${payload.op} transient failure; retrying ` +
            `(attempt ${attempt + 1}/${maxAttempts})`,
        );
        await this.retryDelay(delayMs);
      }
    }
  }

  private async postOnce(
    requestPayload: PushRelayRequestPayload,
    idToken: string,
  ): Promise<void> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    timer.unref?.();
    try {
      const response = await this.fetchImpl(this.relayUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${idToken}`,
        },
        body: JSON.stringify(requestPayload),
        signal: controller.signal,
      });

      await response.text();
      if (!response.ok) throw new PushRelayHttpError(response.status);
    } finally {
      clearTimeout(timer);
    }
  }
}

function isRetryableRelayFailure(error: unknown): boolean {
  if (error instanceof PushRelayHttpError) {
    return (
      error.status === 408 ||
      error.status === 425 ||
      error.status === 429 ||
      error.status >= 500
    );
  }
  // Fetch rejects for transport and timeout failures. Token operations are
  // idempotent, so an ambiguous network result is safe to retry.
  return error instanceof Error;
}
