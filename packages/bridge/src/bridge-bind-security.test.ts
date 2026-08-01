import { describe, expect, it } from "vitest";
import {
  assertSecureBridgeBinding,
  DEFAULT_BRIDGE_HOST,
} from "./bridge-bind-security.js";

describe("Bridge bind security", () => {
  it("defaults to loopback", () => {
    expect(DEFAULT_BRIDGE_HOST).toBe("127.0.0.1");
    expect(() =>
      assertSecureBridgeBinding({ host: DEFAULT_BRIDGE_HOST }),
    ).not.toThrow();
  });

  it.each(["127.0.0.2", "::1", "[::1]", "localhost"])(
    "allows unauthenticated loopback host %s",
    (host) => {
      expect(() => assertSecureBridgeBinding({ host })).not.toThrow();
    },
  );

  it.each(["0.0.0.0", "::", "192.168.1.10", "bridge.example.test"])(
    "rejects unauthenticated non-loopback host %s",
    (host) => {
      expect(() => assertSecureBridgeBinding({ host })).toThrow(
        /BRIDGE_API_KEY/,
      );
    },
  );

  it("allows authenticated or explicitly opted-in remote binding", () => {
    expect(() =>
      assertSecureBridgeBinding({ host: "0.0.0.0", apiKey: "secret" }),
    ).not.toThrow();
    expect(() =>
      assertSecureBridgeBinding({
        host: "0.0.0.0",
        allowUnauthenticatedRemote: true,
      }),
    ).not.toThrow();
  });
});
