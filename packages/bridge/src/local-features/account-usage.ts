import type {
  SessionUsageInfoPayload,
  SessionUsageLimitCardPayload,
  SessionUsageResetCreditPayload,
  SessionUsageWindowPayload,
} from "./protocol.js";
const MAX_SHORT_TERM_WINDOW_MINUTES = 6 * 60;
const MIN_LONG_TERM_WINDOW_MINUTES = 24 * 60;
const MILLISECOND_TIMESTAMP_THRESHOLD = 100_000_000_000;
type WindowKind = "fiveHour" | "sevenDay";
/** Normalize the stable app-server account quota response for old and new clients. */
export function parseCodexAccountRateLimits(
  response: unknown,
): SessionUsageInfoPayload {
  const root = asRecord(response);
  if (!root) {
    throw new Error("account/rateLimits/read returned an invalid response");
  }

  const fallback = asRecord(root.rateLimits);
  const byLimit = asRecord(root.rateLimitsByLimitId);
  const cards = new Map<string, SessionUsageLimitCardPayload>();
  if (byLimit) {
    for (const [rawId, value] of Object.entries(byLimit)) {
      const id = normalizeLimitId(rawId);
      if (!id || cards.has(id)) continue;
      const card = parseLimitCard(value, id);
      if (card) cards.set(id, card);
    }
  }
  if (cards.size === 0 && fallback) {
    const id = fallbackLimitId(fallback);
    if (id) {
      const card = parseLimitCard(fallback, id);
      if (card) cards.set(id, card);
    }
  }

  const limitCards = [...cards.values()].sort((left, right) => {
    if (left.id === "codex") return -1;
    if (right.id === "codex") return 1;
    return (left.limitName ?? left.name ?? left.id).localeCompare(
      right.limitName ?? right.name ?? right.id,
    );
  });
  const primary =
    cards.get("codex") ??
    [...cards.entries()].sort(([left], [right]) =>
      left.localeCompare(right),
    )[0]?.[1] ??
    null;

  return {
    provider: "codex",
    fiveHour: primary?.fiveHour ?? null,
    sevenDay: primary?.sevenDay ?? null,
    limitCards,
    resetCredits: parseResetCredits(root.rateLimitResetCredits),
    source: "app_server",
  };
}

function parseLimitCard(
  value: unknown,
  id: string,
): SessionUsageLimitCardPayload | null {
  const record = asRecord(value);
  if (!record) return null;
  const windows = mapCurrentRateLimitWindows(record);
  const limitName = nonEmptyString(record.limitName);
  const planType = nonEmptyString(record.planType);
  const rateLimitReachedType = nonEmptyString(record.rateLimitReachedType);
  const individualLimit = parseIndividualLimit(record.individualLimit);
  const hasPayload =
    windows.fiveHour !== null ||
    windows.sevenDay !== null ||
    limitName !== undefined ||
    planType !== undefined ||
    rateLimitReachedType !== undefined ||
    typeof record.spendControlReached === "boolean" ||
    individualLimit !== undefined;
  if (!hasPayload) return null;

  return {
    id,
    ...(limitName ? { name: limitName, limitName } : {}),
    ...(planType ? { planType } : {}),
    ...windows,
    ...(rateLimitReachedType ? { rateLimitReachedType } : {}),
    ...(typeof record.spendControlReached === "boolean"
      ? { spendControlReached: record.spendControlReached }
      : {}),
    ...(individualLimit ? { individualLimit } : {}),
  };
}

function mapCurrentRateLimitWindows(
  record: Record<string, unknown>,
): Pick<SessionUsageLimitCardPayload, "fiveHour" | "sevenDay"> {
  let fiveHour: SessionUsageWindowPayload | null = null;
  let sevenDay: SessionUsageWindowPayload | null = null;
  const entries: Array<[unknown, WindowKind]> = [
    [record.primary, "fiveHour"],
    [record.secondary, "sevenDay"],
  ];
  for (const [raw, positionalKind] of entries) {
    const window = asRecord(raw);
    if (!window) continue;
    const duration = finiteNumber(
      window.windowDurationMins ?? window.window_minutes,
    );
    const parsed = parseCurrentWindow(window, duration);
    if (!parsed) continue;
    const kind = classifyWindow(duration, positionalKind);
    if (kind === "fiveHour") fiveHour ??= parsed;
    if (kind === "sevenDay") sevenDay ??= parsed;
  }
  return { fiveHour, sevenDay };
}

function parseCurrentWindow(
  record: Record<string, unknown>,
  duration: number | undefined,
): SessionUsageWindowPayload | null {
  const utilization = finiteNumber(record.usedPercent ?? record.used_percent);
  if (utilization === undefined) return null;
  const resetsAt = safeIsoTimestamp(record.resetsAt ?? record.resets_at);
  return {
    utilization,
    ...(resetsAt ? { resetsAt } : {}),
    ...(duration !== undefined ? { windowDurationMins: duration } : {}),
  };
}

function parseIndividualLimit(
  value: unknown,
): SessionUsageLimitCardPayload["individualLimit"] | undefined {
  const record = asRecord(value);
  if (!record) return undefined;
  const limit = nonEmptyString(record.limit);
  const used = nonEmptyString(record.used);
  const remainingPercent = finiteNumber(
    record.remainingPercent ?? record.remaining_percent,
  );
  if (!limit || !used || remainingPercent === undefined) {
    return undefined;
  }
  const resetsAt = safeIsoTimestamp(record.resetsAt ?? record.resets_at);
  return {
    limit,
    used,
    remainingPercent,
    ...(resetsAt ? { resetsAt } : {}),
  };
}

function parseResetCredits(
  value: unknown,
): SessionUsageInfoPayload["resetCredits"] | undefined {
  const record = asRecord(value);
  if (!record) return undefined;
  const availableCount = nonNegativeInteger(record.availableCount) ?? 0;
  const rawCredits = Array.isArray(record.credits) ? record.credits : null;
  const credits = rawCredits
    ?.map(parseResetCredit)
    .filter(
      (credit): credit is SessionUsageResetCreditPayload => credit !== null,
    );
  return {
    availableCount,
    ...(credits ? { credits } : {}),
  };
}

function parseResetCredit(
  value: unknown,
): SessionUsageResetCreditPayload | null {
  const record = asRecord(value);
  if (!record) return null;
  const id = nonEmptyString(record.id);
  const resetType = nonEmptyString(record.resetType);
  const status = nonEmptyString(record.status);
  if (!id || !resetType || !status) return null;
  const grantedAt = safeIsoTimestamp(record.grantedAt);
  const expiresAt = safeIsoTimestamp(record.expiresAt);
  const title = nonEmptyString(record.title);
  const description = nonEmptyString(record.description);
  return {
    id,
    resetType,
    status,
    ...(grantedAt ? { grantedAt } : {}),
    ...(record.expiresAt === null
      ? { expiresAt: null }
      : expiresAt
        ? { expiresAt }
        : {}),
    ...(title ? { title } : {}),
    ...(description ? { description } : {}),
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : null;
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function nonNegativeInteger(value: unknown): number | undefined {
  const number = finiteNumber(value);
  return number !== undefined && number >= 0 ? Math.floor(number) : undefined;
}

function nonEmptyString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed || undefined;
}

function normalizeLimitId(value: unknown): string | undefined {
  const id = nonEmptyString(value);
  if (!id) return undefined;
  return id.toLocaleLowerCase() === "codex" ? "codex" : id;
}

function fallbackLimitId(record: Record<string, unknown>): string | undefined {
  return Object.prototype.hasOwnProperty.call(record, "limitId")
    ? normalizeLimitId(record.limitId)
    : "codex";
}

function classifyWindow(
  durationMinutes: number | undefined,
  positionalKind: WindowKind,
): WindowKind | null {
  if (durationMinutes === undefined) return positionalKind;
  if (durationMinutes > 0 && durationMinutes <= MAX_SHORT_TERM_WINDOW_MINUTES) {
    return "fiveHour";
  }
  if (durationMinutes >= MIN_LONG_TERM_WINDOW_MINUTES) {
    return "sevenDay";
  }
  return null;
}

function safeIsoTimestamp(value: unknown): string | undefined {
  const timestamp = finiteNumber(value);
  if (timestamp === undefined) return undefined;
  const milliseconds =
    Math.abs(timestamp) >= MILLISECOND_TIMESTAMP_THRESHOLD
      ? timestamp
      : timestamp * 1000;
  if (!Number.isFinite(milliseconds)) return undefined;
  const date = new Date(milliseconds);
  return Number.isFinite(date.getTime()) ? date.toISOString() : undefined;
}
