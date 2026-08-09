export interface BridgeConnectionAuthenticationConfig {
  mode: BridgeAuthMode;
  required: boolean;
  configuredApiKey?: string;
  effectiveApiKey?: string;
  explicitlyConfigured: boolean;
}

export type BridgeAuthMode = "key" | "paired_or_key" | "open";

const TRUE_VALUES = new Set(["1", "true", "yes", "on"]);
const FALSE_VALUES = new Set(["0", "false", "no", "off"]);

export function parseBridgeRequireApiKey(
  value: string | boolean | undefined,
): boolean | undefined {
  if (typeof value === "boolean" || value === undefined) return value;
  const normalized = value.trim().toLowerCase();
  if (TRUE_VALUES.has(normalized)) return true;
  if (FALSE_VALUES.has(normalized)) return false;
  throw new Error(
    `Invalid BRIDGE_REQUIRE_API_KEY value ${JSON.stringify(value)}; expected 1/0, true/false, yes/no, or on/off`,
  );
}

export function parseBridgeAuthMode(value: string | undefined): BridgeAuthMode | undefined {
  if (value === undefined || value.trim() === "") return undefined;
  const normalized = value.trim().toLowerCase();
  if (normalized === "key" || normalized === "paired_or_key" || normalized === "open") {
    return normalized;
  }
  throw new Error(
    `Invalid BRIDGE_AUTH_MODE value ${JSON.stringify(value)}; expected key, paired_or_key, or open`,
  );
}

export function resolveBridgeConnectionAuthentication(input: {
  apiKey?: string;
  requireApiKey?: string | boolean;
  authMode?: string;
}): BridgeConnectionAuthenticationConfig {
  const configuredApiKey = input.apiKey?.trim()
    ? input.apiKey
    : undefined;
  const explicitRequired = parseBridgeRequireApiKey(input.requireApiKey);
  const explicitMode = parseBridgeAuthMode(input.authMode);
  const mode = explicitMode ??
    (explicitRequired === true || configuredApiKey !== undefined ? "key" : "open");
  const required = mode === "paired_or_key"
    ? true
    : mode === "open"
      ? false
      : explicitRequired ?? (configuredApiKey !== undefined);
  if (required && configuredApiKey === undefined) {
    if (mode === "key") {
      throw new Error(
        "BRIDGE_REQUIRE_API_KEY is enabled but BRIDGE_API_KEY is empty",
      );
    }
  }
  return {
    mode,
    required,
    configuredApiKey,
    effectiveApiKey:
      mode === "open"
        ? undefined
        : mode === "key"
          ? required
            ? configuredApiKey
            : undefined
          : configuredApiKey,
    explicitlyConfigured: explicitRequired !== undefined || explicitMode !== undefined,
  };
}
