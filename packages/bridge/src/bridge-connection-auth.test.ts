import { describe, expect, it } from "vitest";
import {
  parseBridgeAuthMode,
  parseBridgeRequireApiKey,
  resolveBridgeConnectionAuthentication,
} from "./bridge-connection-auth.js";

describe("Bridge connection authentication configuration", () => {
  it("preserves the legacy key-presence behavior when the toggle is absent", () => {
    expect(
      resolveBridgeConnectionAuthentication({ apiKey: "owner-key" }),
    ).toMatchObject({
      mode: "key",
      required: true,
      effectiveApiKey: "owner-key",
      explicitlyConfigured: false,
    });
    expect(resolveBridgeConnectionAuthentication({})).toMatchObject({
      mode: "open",
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
      mode: "key",
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
    expect(() =>
      resolveBridgeConnectionAuthentication({ authMode: "key" }),
    ).toThrow(/BRIDGE_API_KEY is empty/);
    expect(() =>
      resolveBridgeConnectionAuthentication({
        authMode: "key",
        apiKey: "owner-key",
        requireApiKey: false,
      }),
    ).toThrow(/conflicts/);
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

  it("supports paired-or-key and explicit open modes without changing legacy key semantics", () => {
    expect(resolveBridgeConnectionAuthentication({ authMode: "paired_or_key" })).toMatchObject({
      mode: "paired_or_key",
      required: true,
      effectiveApiKey: undefined,
    });
    expect(resolveBridgeConnectionAuthentication({ authMode: "open", apiKey: "legacy" })).toMatchObject({
      mode: "open",
      required: false,
      effectiveApiKey: undefined,
    });
    expect(parseBridgeAuthMode("PAIRed_or_key")).toBe("paired_or_key");
    expect(() => parseBridgeAuthMode("maybe")).toThrow(/BRIDGE_AUTH_MODE/);
  });
});
