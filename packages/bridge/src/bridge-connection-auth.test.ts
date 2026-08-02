import { describe, expect, it } from "vitest";
import {
  parseBridgeRequireApiKey,
  resolveBridgeConnectionAuthentication,
} from "./bridge-connection-auth.js";

describe("Bridge connection authentication configuration", () => {
  it("preserves the legacy key-presence behavior when the toggle is absent", () => {
    expect(
      resolveBridgeConnectionAuthentication({ apiKey: "owner-key" }),
    ).toMatchObject({
      required: true,
      effectiveApiKey: "owner-key",
      explicitlyConfigured: false,
    });
    expect(resolveBridgeConnectionAuthentication({})).toMatchObject({
      required: false,
      effectiveApiKey: undefined,
      explicitlyConfigured: false,
    });
  });

  it("can retain a configured key while explicitly disabling authentication", () => {
    expect(
      resolveBridgeConnectionAuthentication({
        apiKey: "owner-key",
        requireApiKey: false,
      }),
    ).toEqual({
      required: false,
      configuredApiKey: "owner-key",
      effectiveApiKey: undefined,
      explicitlyConfigured: true,
    });
  });

  it("fails closed when authentication is enabled without a key", () => {
    expect(() =>
      resolveBridgeConnectionAuthentication({ requireApiKey: true }),
    ).toThrow(/BRIDGE_API_KEY is empty/);
  });

  it.each([
    ["1", true],
    ["true", true],
    ["ON", true],
    ["0", false],
    ["false", false],
    ["off", false],
  ])("parses %j as %s", (value, expected) => {
    expect(parseBridgeRequireApiKey(value)).toBe(expected);
  });

  it("rejects ambiguous toggle values", () => {
    expect(() => parseBridgeRequireApiKey("sometimes")).toThrow(
      /Invalid BRIDGE_REQUIRE_API_KEY/,
    );
  });
});
