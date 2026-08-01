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

export class PushRelayClient {
  private readonly relayUrl: string;
  private readonly firebaseAuth: FirebaseAuthClient | null;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: PushRelayClientOptions = {}) {
    this.relayUrl = options.relayUrl ?? DEFAULT_RELAY_URL;
    this.firebaseAuth = options.firebaseAuth ?? null;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
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
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
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
      if (!response.ok) {
        throw new Error(`Push relay returned ${response.status}`);
      }
      console.log(`[push-relay] ${payload.op} OK`);
    } finally {
      clearTimeout(timer);
    }
  }
}
