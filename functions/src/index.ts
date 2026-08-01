import { createHash } from "node:crypto";
import { initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import * as logger from "firebase-functions/logger";
import { onRequest } from "firebase-functions/v2/https";

initializeApp();

type PushPlatform = "ios" | "android" | "web";

type RegisterBody = {
  op: "register";
  bridgeId: string;
  token: string;
  platform: PushPlatform;
  locale?: string;
  enabledEventTypes?: string[];
  approvalActionsSupported?: boolean;
  approvalActionsVersion?: 1 | 2;
};

type UnregisterBody = {
  op: "unregister";
  bridgeId: string;
  token: string;
};

type NotifyBody = {
  op: "notify";
  bridgeId: string;
  eventType: string;
  title: string;
  body: string;
  /** When set, only tokens with this locale receive the notification. */
  locale?: string;
  data?: Record<string, string>;
  /** Tokens that already displayed this event through live local delivery. */
  excludedTokens?: string[];
};

type RelayBody = RegisterBody | UnregisterBody | NotifyBody;

const OPT_IN_ONLY_EVENT_TYPES = new Set(["session_progress"]);
const MAX_FCM_TOKEN_LENGTH = 4096;
const MAX_LOCALE_BYTES = 32;
const MAX_EVENT_TYPE_BYTES = 64;
const MAX_NOTIFICATION_TITLE_BYTES = 256;
const MAX_NOTIFICATION_BODY_BYTES = 2048;
const MAX_NOTIFICATION_DATA_ENTRIES = 16;
const MAX_NOTIFICATION_DATA_KEY_BYTES = 64;
const MAX_NOTIFICATION_DATA_VALUE_BYTES = 512;
const MAX_NOTIFICATION_PAYLOAD_BYTES = 3072;
const MAX_EXCLUDED_TOKENS = 20;

class RelayHttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
    this.name = "RelayHttpError";
  }
}

const db = getFirestore();
const messaging = getMessaging();
const auth = getAuth();
const appCheck = getAppCheck();

/**
 * Verify Firebase App Check token from the X-Firebase-AppCheck header.
 * Returns true if valid or if App Check enforcement is not yet enabled
 * (controlled by the ENFORCE_APP_CHECK env var).
 */
async function verifyAppCheck(req: {
  header: (name: string) => string | undefined;
}): Promise<boolean> {
  const appCheckToken = req.header("x-firebase-appcheck");
  if (!appCheckToken) {
    return false;
  }
  try {
    await appCheck.verifyToken(appCheckToken);
    return true;
  } catch {
    return false;
  }
}

/** Whether to enforce App Check. Set to "true" after all clients are updated. */
const ENFORCE_APP_CHECK = process.env.ENFORCE_APP_CHECK === "true";

// ---------- Rate limiting ----------

/** Max notify calls per bridge per window. */
const RATE_LIMIT_NOTIFY_MAX = 30;
/** Rate limit window in milliseconds (1 minute). */
const RATE_LIMIT_WINDOW_MS = 60_000;

/** Max register/unregister calls per bridge per window. */
const RATE_LIMIT_TOKEN_MAX = 20;

/**
 * Firestore-backed sliding-window rate limiter.
 * Uses a single document per bridge+op to track request timestamps.
 * Returns true if the request is allowed, false if rate-limited.
 */
async function checkRateLimit(
  bridgeId: string,
  op: "notify" | "token",
  limit: number,
): Promise<boolean> {
  const ref = db.doc(`rate_limits/${bridgeId}_${op}`);
  const now = Date.now();
  const windowStart = now - RATE_LIMIT_WINDOW_MS;

  return db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const data = doc.data() as { timestamps?: number[] } | undefined;
    const timestamps = (data?.timestamps ?? []).filter((t) => t > windowStart);

    if (timestamps.length >= limit) {
      return false;
    }

    timestamps.push(now);
    // expireAt enables Firestore TTL policy to auto-delete stale rate limit docs
    const expireAt = new Date(now + RATE_LIMIT_WINDOW_MS * 2);
    tx.set(ref, {
      timestamps,
      updatedAt: FieldValue.serverTimestamp(),
      expireAt,
    });
    return true;
  });
}

// ---------- Helpers ----------

function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

function tokenDocPath(bridgeId: string, token: string): string {
  return `bridges/${bridgeId}/tokens/${sha256(token)}`;
}

function readBearerToken(authHeader: string | undefined): string | null {
  if (!authHeader) return null;
  const [scheme, token] = authHeader.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) return null;
  return token.trim();
}

/**
 * Verify Firebase ID token and return the UID.
 * Returns null if the token is invalid or expired.
 */
async function verifyFirebaseToken(
  authHeader: string | undefined,
): Promise<string | null> {
  const bearer = readBearerToken(authHeader);
  if (!bearer) return null;
  try {
    const decoded = await auth.verifyIdToken(bearer);
    return decoded.uid;
  } catch {
    return null;
  }
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : null;
}

function utf8Length(value: string): number {
  return Buffer.byteLength(value, "utf8");
}

function boundedString(value: unknown, maximumBytes: number): string | null {
  const normalized = asNonEmptyString(value);
  if (!normalized || utf8Length(normalized) > maximumBytes) return null;
  return normalized;
}

function parseNotificationData(
  value: unknown,
): Record<string, string> | undefined | null {
  if (value === undefined) return undefined;
  if (typeof value !== "object" || value == null || Array.isArray(value)) {
    return null;
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length > MAX_NOTIFICATION_DATA_ENTRIES) return null;

  const data: Record<string, string> = {};
  for (const [key, rawValue] of entries) {
    if (
      !key ||
      utf8Length(key) > MAX_NOTIFICATION_DATA_KEY_BYTES ||
      typeof rawValue !== "string" ||
      utf8Length(rawValue) > MAX_NOTIFICATION_DATA_VALUE_BYTES
    ) {
      return null;
    }
    data[key] = rawValue;
  }
  return data;
}

function parseRelayBody(payload: unknown): RelayBody | null {
  if (typeof payload !== "object" || payload == null) return null;
  const body = payload as Record<string, unknown>;
  const op = asNonEmptyString(body.op);
  if (!op) return null;

  // bridgeId from request body is ignored; the authenticated UID is used instead.
  // We still parse it for backward compatibility but it will be overridden.

  if (op === "register") {
    const token = asNonEmptyString(body.token);
    const platform = body.platform;
    if (!token || token.length > MAX_FCM_TOKEN_LENGTH) return null;
    if (platform !== "ios" && platform !== "android" && platform !== "web") {
      return null;
    }
    const locale =
      body.locale === undefined
        ? undefined
        : (boundedString(body.locale, MAX_LOCALE_BYTES) ?? null);
    if (locale === null) return null;
    let enabledEventTypes: string[] | undefined;
    if (body.enabledEventTypes !== undefined) {
      if (
        !Array.isArray(body.enabledEventTypes) ||
        body.enabledEventTypes.length > 16
      ) {
        return null;
      }
      enabledEventTypes = [];
      for (const rawEventType of body.enabledEventTypes) {
        const eventType = asNonEmptyString(rawEventType);
        if (!eventType || eventType.length > 64) return null;
        if (!enabledEventTypes.includes(eventType)) {
          enabledEventTypes.push(eventType);
        }
      }
    }
    const approvalActionsSupported = body.approvalActionsSupported;
    if (
      approvalActionsSupported !== undefined &&
      typeof approvalActionsSupported !== "boolean"
    ) {
      return null;
    }
    const approvalActionsVersion = body.approvalActionsVersion;
    if (
      approvalActionsVersion !== undefined &&
      approvalActionsVersion !== 1 &&
      approvalActionsVersion !== 2
    ) {
      return null;
    }
    return {
      op,
      bridgeId: "",
      token,
      platform,
      locale,
      enabledEventTypes,
      approvalActionsSupported,
      approvalActionsVersion,
    };
  }

  if (op === "unregister") {
    const token = asNonEmptyString(body.token);
    if (!token || token.length > MAX_FCM_TOKEN_LENGTH) return null;
    return { op, bridgeId: "", token };
  }

  if (op === "notify") {
    const eventType = boundedString(body.eventType, MAX_EVENT_TYPE_BYTES);
    const title = boundedString(body.title, MAX_NOTIFICATION_TITLE_BYTES);
    const bodyText = boundedString(body.body, MAX_NOTIFICATION_BODY_BYTES);
    if (!eventType || !title || !bodyText) return null;
    const locale =
      body.locale === undefined
        ? undefined
        : (boundedString(body.locale, MAX_LOCALE_BYTES) ?? null);
    if (locale === null) return null;
    const data = parseNotificationData(body.data);
    if (data === null) return null;
    let excludedTokens: string[] | undefined;
    if (body.excludedTokens !== undefined) {
      if (
        !Array.isArray(body.excludedTokens) ||
        body.excludedTokens.length > MAX_EXCLUDED_TOKENS
      ) {
        return null;
      }
      excludedTokens = [];
      for (const rawToken of body.excludedTokens) {
        const token = asNonEmptyString(rawToken);
        if (!token || !isValidFcmToken(token)) return null;
        if (!excludedTokens.includes(token)) excludedTokens.push(token);
      }
    }
    const dataBytes = Object.entries(data ?? {}).reduce(
      (total, [key, value]) => total + utf8Length(key) + utf8Length(value),
      0,
    );
    if (
      utf8Length(eventType) +
        utf8Length(title) +
        utf8Length(bodyText) +
        utf8Length(locale ?? "") +
        dataBytes >
      MAX_NOTIFICATION_PAYLOAD_BYTES
    ) {
      return null;
    }
    return {
      op,
      bridgeId: "",
      eventType,
      title,
      body: bodyText,
      locale,
      data,
      excludedTokens,
    };
  }

  return null;
}

/**
 * Validate FCM token format.
 * Real FCM tokens are 100-300+ characters, alphanumeric with colons and hyphens.
 */
function isValidFcmToken(token: string): boolean {
  if (token.length < 32 || token.length > 4096) return false;
  // FCM tokens consist of base64-like chars, colons, hyphens, and underscores
  return /^[A-Za-z0-9_:+/=-]+$/.test(token);
}

async function handleRegister(body: RegisterBody): Promise<void> {
  if (!isValidFcmToken(body.token)) {
    throw new RelayHttpError(400, "invalid_fcm_token");
  }

  const ref = db.doc(tokenDocPath(body.bridgeId, body.token));
  const snapshot = await ref.get();
  if (snapshot.exists) {
    const updateData: Record<string, unknown> = {
      token: body.token,
      platform: body.platform,
      enabledEventTypes: body.enabledEventTypes ?? FieldValue.delete(),
      approvalActionsSupported:
        body.approvalActionsSupported ?? FieldValue.delete(),
      approvalActionsVersion:
        body.approvalActionsVersion ?? FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (body.locale) updateData.locale = body.locale;
    await ref.update(updateData);
    return;
  }

  // Limit new tokens per bridge to prevent abuse. Existing tokens may still
  // refresh their platform or locale after the bridge reaches this limit.
  const existingTokens = await db
    .collection(`bridges/${body.bridgeId}/tokens`)
    .count()
    .get();
  if (existingTokens.data().count >= 20) {
    throw new RelayHttpError(409, "token_limit_exceeded");
  }

  await ref.set({
    token: body.token,
    platform: body.platform,
    ...(body.locale ? { locale: body.locale } : {}),
    ...(body.enabledEventTypes !== undefined
      ? { enabledEventTypes: body.enabledEventTypes }
      : {}),
    ...(body.approvalActionsSupported !== undefined
      ? { approvalActionsSupported: body.approvalActionsSupported }
      : {}),
    ...(body.approvalActionsVersion !== undefined
      ? { approvalActionsVersion: body.approvalActionsVersion }
      : {}),
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
}

async function handleUnregister(body: UnregisterBody): Promise<void> {
  const ref = db.doc(tokenDocPath(body.bridgeId, body.token));
  await ref.delete();
}

function isDeleteTargetError(code: string | undefined): boolean {
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token"
  );
}

function approvalActionPayloadVersion(
  data: Record<string, string> | undefined,
): 1 | 2 | undefined {
  if (!data) return undefined;
  const sessionId = asNonEmptyString(data.sessionId);
  const provider = asNonEmptyString(data.provider);
  const occurredAt = asNonEmptyString(data.occurredAt);
  if (
    sessionId == null ||
    sessionId.length > 256 ||
    (provider !== "claude" && provider !== "codex") ||
    occurredAt == null ||
    occurredAt.length > 64 ||
    !Number.isFinite(Date.parse(occurredAt))
  ) {
    return undefined;
  }
  if (data.actionPayloadVersion === "2") {
    const opaqueRequestId = asNonEmptyString(data.opaqueRequestId);
    const codexSourceId = asNonEmptyString(data.codexSourceId);
    const threadId = asNonEmptyString(data.threadId);
    const turnId = asNonEmptyString(data.turnId);
    const authorityGeneration = asNonEmptyString(data.authorityGeneration);
    const allowedActions = asNonEmptyString(data.allowedActions);
    const actions = new Set(allowedActions?.split(",") ?? []);
    return provider === "codex" &&
      opaqueRequestId != null &&
      opaqueRequestId.length <= 256 &&
      codexSourceId != null &&
      codexSourceId.length <= 128 &&
      threadId != null &&
      threadId.length <= 256 &&
      turnId != null &&
      turnId.length <= 256 &&
      authorityGeneration != null &&
      authorityGeneration.length <= 64 &&
      allowedActions != null &&
      allowedActions.length <= 128 &&
      [...actions].every((action) =>
        ["approve", "approve_always", "reject", "answer"].includes(action),
      ) &&
      (actions.has("approve") || actions.has("reject"))
      ? 2
      : undefined;
  }
  const permissionId = asNonEmptyString(data.permissionId);
  return permissionId != null && permissionId.length <= 256 ? 1 : undefined;
}

async function handleNotify(body: NotifyBody): Promise<{
  tokenCount: number;
  successCount: number;
  failureCount: number;
  deletedInvalidTokens: number;
}> {
  const snapshot = await db.collection(`bridges/${body.bridgeId}/tokens`).get();
  const excludedTokens = new Set(body.excludedTokens ?? []);
  const registrations = snapshot.docs
    .filter((d) => {
      const token = asNonEmptyString(d.get("token"));
      if (token != null && excludedTokens.has(token)) return false;

      // When locale is specified, only send to tokens with matching locale.
      // Legacy tokens without a locale receive only the English fallback, so
      // one old device cannot receive every localized copy.
      if (body.locale) {
        const tokenLocale = asNonEmptyString(d.get("locale"));
        if (tokenLocale == null) return body.locale === "en";
        if (tokenLocale !== body.locale) return false;
      }

      const enabledEventTypes = d.get("enabledEventTypes");
      if (Array.isArray(enabledEventTypes)) {
        return enabledEventTypes.includes(body.eventType);
      }
      // Older clients did not register preferences. Preserve their established
      // approval/completion notifications, but never opt them into a new noisy
      // category such as progress.
      return !OPT_IN_ONLY_EVENT_TYPES.has(body.eventType);
    })
    .map((d) => ({
      token: asNonEmptyString(d.get("token")),
      approvalActionsVersion:
        d.get("approvalActionsVersion") === 2
          ? (2 as const)
          : d.get("approvalActionsVersion") === 1 ||
              d.get("approvalActionsSupported") === true
            ? (1 as const)
            : (0 as const),
    }))
    .filter(
      (
        registration,
      ): registration is {
        token: string;
        approvalActionsVersion: 0 | 1 | 2;
      } => registration.token != null,
    );
  if (registrations.length === 0) {
    return {
      tokenCount: 0,
      successCount: 0,
      failureCount: 0,
      deletedInvalidTokens: 0,
    };
  }

  let successCount = 0;
  let failureCount = 0;
  const invalidTokens = new Set<string>();

  const requiredApprovalActionVersion =
    body.eventType === "approval_required"
      ? approvalActionPayloadVersion(body.data)
      : undefined;
  const deliveryGroups =
    body.eventType === "approval_required" &&
    requiredApprovalActionVersion !== undefined
      ? [
          {
            approvalActionsVersion: requiredApprovalActionVersion,
            tokens: registrations
              .filter(
                (registration) =>
                  registration.approvalActionsVersion >=
                  requiredApprovalActionVersion,
              )
              .map((registration) => registration.token),
          },
          {
            approvalActionsVersion: 0 as const,
            tokens: registrations
              .filter(
                (registration) =>
                  registration.approvalActionsVersion <
                  requiredApprovalActionVersion,
              )
              .map((registration) => registration.token),
          },
        ]
      : [
          {
            approvalActionsVersion: 0 as const,
            tokens: registrations.map((registration) => registration.token),
          },
        ];

  for (const group of deliveryGroups) {
    for (let i = 0; i < group.tokens.length; i += 500) {
      const chunk = group.tokens.slice(i, i + 500);
      const response = await messaging.sendEachForMulticast({
        tokens: chunk,
        notification: { title: body.title, body: body.body },
        data: { ...body.data, eventType: body.eventType },
        android: {
          priority: "high",
          notification: {
            channelId: "ccpocket_channel",
            priority: "high",
            sound: "default",
            defaultVibrateTimings: true,
          },
        },
        apns: {
          payload: {
            aps: {
              sound: "default",
              ...(group.approvalActionsVersion > 0
                ? {
                    category:
                      group.approvalActionsVersion === 2
                        ? "ccpocket_approval_v2"
                        : "ccpocket_approval_v1",
                  }
                : {}),
            },
          },
        },
      });

      successCount += response.successCount;
      failureCount += response.failureCount;
      for (let j = 0; j < response.responses.length; j++) {
        const result = response.responses[j];
        if (!result.success && isDeleteTargetError(result.error?.code)) {
          invalidTokens.add(chunk[j]);
        }
      }
    }
  }

  if (invalidTokens.size > 0) {
    await Promise.all(
      Array.from(invalidTokens).map((token) =>
        db.doc(tokenDocPath(body.bridgeId, token)).delete(),
      ),
    );
  }

  return {
    tokenCount: registrations.length,
    successCount,
    failureCount,
    deletedInvalidTokens: invalidTokens.size,
  };
}

export const relay = onRequest(
  { cors: true, maxInstances: 10 },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Method Not Allowed" });
      return;
    }

    // Verify Firebase ID token
    const uid = await verifyFirebaseToken(req.header("authorization"));
    if (!uid) {
      res.status(401).json({ error: "Unauthorized" });
      return;
    }
    const logBridgeId = sha256(uid).slice(0, 12);

    // Verify App Check token (soft-enforce until ENFORCE_APP_CHECK=true)
    const appCheckValid = await verifyAppCheck(req);
    if (!appCheckValid) {
      if (ENFORCE_APP_CHECK) {
        res.status(401).json({ error: "App Check verification failed" });
        return;
      }
      logger.warn("App Check token missing or invalid (not enforced yet)", {
        bridgeIdHash: logBridgeId,
      });
    }

    const parsed = parseRelayBody(req.body);
    if (!parsed) {
      res.status(400).json({ error: "Invalid request body" });
      return;
    }

    // Override bridgeId with authenticated UID for security.
    // This prevents a client from accessing another bridge's tokens.
    parsed.bridgeId = uid;

    try {
      // Rate limit check
      const rateLimitOp =
        parsed.op === "notify" ? ("notify" as const) : ("token" as const);
      const rateLimitMax =
        parsed.op === "notify" ? RATE_LIMIT_NOTIFY_MAX : RATE_LIMIT_TOKEN_MAX;
      const allowed = await checkRateLimit(uid, rateLimitOp, rateLimitMax);
      if (!allowed) {
        logger.warn("Rate limit exceeded", {
          bridgeIdHash: logBridgeId,
          op: parsed.op,
        });
        res
          .status(429)
          .json({ error: "Rate limit exceeded. Try again later." });
        return;
      }

      switch (parsed.op) {
        case "register":
          await handleRegister(parsed);
          res.status(200).json({ ok: true, op: parsed.op });
          return;
        case "unregister":
          await handleUnregister(parsed);
          res.status(200).json({ ok: true, op: parsed.op });
          return;
        case "notify": {
          const result = await handleNotify(parsed);
          logger.info("Push notification relay sent", {
            bridgeIdHash: logBridgeId,
            eventType: parsed.eventType,
            ...result,
          });
          res.status(200).json({ ok: true, op: parsed.op, ...result });
          return;
        }
      }
    } catch (error) {
      if (error instanceof RelayHttpError) {
        logger.warn("Relay operation rejected", {
          op: parsed.op,
          status: error.status,
          code: error.code,
        });
        res.status(error.status).json({ error: error.code });
        return;
      }

      logger.error("Relay operation failed", {
        op: parsed.op,
        message: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
      });
      res.status(500).json({ error: "internal_error" });
    }
  },
);
