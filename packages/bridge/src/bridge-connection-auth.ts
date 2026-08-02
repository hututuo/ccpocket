export interface BridgeConnectionAuthenticationConfig {
  required: boolean;
  configuredApiKey?: string;
  effectiveApiKey?: string;
  explicitlyConfigured: boolean;
}

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

export function resolveBridgeConnectionAuthentication(input: {
  apiKey?: string;
  requireApiKey?: string | boolean;
}): BridgeConnectionAuthenticationConfig {
  const configuredApiKey = input.apiKey?.trim()
    ? input.apiKey
    : undefined;
  const explicitRequired = parseBridgeRequireApiKey(input.requireApiKey);
  const required = explicitRequired ?? (configuredApiKey !== undefined);
  if (required && configuredApiKey === undefined) {
    throw new Error(
      "BRIDGE_REQUIRE_API_KEY is enabled but BRIDGE_API_KEY is empty",
    );
  }
  return {
    required,
    configuredApiKey,
    effectiveApiKey: required ? configuredApiKey : undefined,
    explicitlyConfigured: explicitRequired !== undefined,
  };
}
