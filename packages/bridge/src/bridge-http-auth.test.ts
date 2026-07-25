import type { IncomingMessage } from "node:http";
import { describe, expect, it } from "vitest";
import {
  BridgeApiKeyAuthenticator,
  isLoopbackAddress,
  requiresPrivateHttpAuthorization,
} from "./bridge-http-auth.js";

function request(options: {
  url?: string;
  remoteAddress?: string;
  authorization?: string;
}): IncomingMessage {
  return {
    url: options.url,
    headers: {
      ...(options.authorization
        ? { authorization: options.authorization }
        : {}),
    },
    socket: {
      remoteAddress: options.remoteAddress,
    },
  } as IncomingMessage;
}

describe("BridgeApiKeyAuthenticator", () => {
  it("accepts the exact WebSocket query credential", () => {
    const auth = new BridgeApiKeyAuthenticator("owner-key");

    expect(
      auth.acceptsWebSocketRequest(request({ url: "/?token=owner-key" })),
    ).toBe(true);
    expect(
      auth.acceptsWebSocketRequest(request({ url: "/?token=other-key" })),
    ).toBe(false);
    expect(auth.acceptsWebSocketRequest(request({ url: "/%" }))).toBe(false);
  });

  it("keeps WebSocket compatibility when no API key is configured", () => {
    const auth = new BridgeApiKeyAuthenticator();
    expect(auth.acceptsWebSocketRequest(request({ url: "/" }))).toBe(true);
  });

  it("allows loopback private HTTP requests without copying the API key", () => {
    const auth = new BridgeApiKeyAuthenticator("owner-key");
    expect(
      auth.acceptsPrivateHttpRequest(
        request({ remoteAddress: "::ffff:127.0.0.1" }),
      ),
    ).toBe(true);
  });

  it("requires the exact bearer credential for remote private HTTP requests", () => {
    const auth = new BridgeApiKeyAuthenticator("owner-key");
    expect(
      auth.acceptsPrivateHttpRequest(
        request({
          remoteAddress: "100.64.0.2",
          authorization: "Bearer owner-key",
        }),
      ),
    ).toBe(true);
    expect(
      auth.acceptsPrivateHttpRequest(
        request({
          remoteAddress: "100.64.0.2",
          authorization: "Bearer other-key",
        }),
      ),
    ).toBe(false);
  });

  it("keeps old Mobile HTTP controls working only beside its authenticated socket", () => {
    const auth = new BridgeApiKeyAuthenticator("owner-key");
    const peer = request({
      url: "/?token=owner-key",
      remoteAddress: "100.64.0.2",
    });
    expect(auth.acceptsWebSocketRequest(peer)).toBe(true);
    const release = auth.trackAuthenticatedWebSocketPeer(peer);

    expect(
      auth.acceptsPrivateHttpRequest(request({ remoteAddress: "100.64.0.2" })),
    ).toBe(true);
    expect(
      auth.acceptsPrivateHttpRequest(
        request({
          remoteAddress: "100.64.0.2",
          authorization: "Bearer wrong-key",
        }),
      ),
    ).toBe(false);
    expect(
      auth.acceptsPrivateHttpRequest(
        request({
          remoteAddress: "100.64.0.2",
          authorization: undefined,
        }),
      ),
    ).toBe(true);

    release();
    expect(
      auth.acceptsPrivateHttpRequest(request({ remoteAddress: "100.64.0.2" })),
    ).toBe(false);
  });

  it("does not trust forwarded loopback or browser-origin legacy requests", () => {
    const auth = new BridgeApiKeyAuthenticator("owner-key");
    const forwardedPeer = request({
      url: "/?token=owner-key",
      remoteAddress: "127.0.0.1",
    });
    forwardedPeer.headers["x-forwarded-for"] = "100.64.0.2";
    const release = auth.trackAuthenticatedWebSocketPeer(forwardedPeer);
    const forwardedHttp = request({ remoteAddress: "127.0.0.1" });
    forwardedHttp.headers["x-forwarded-for"] = "100.64.0.2";
    expect(auth.acceptsPrivateHttpRequest(forwardedHttp)).toBe(false);
    release();

    const directPeer = request({
      url: "/?token=owner-key",
      remoteAddress: "100.64.0.2",
    });
    const releaseDirect = auth.trackAuthenticatedWebSocketPeer(directPeer);
    const browserRequest = request({ remoteAddress: "100.64.0.2" });
    browserRequest.headers.origin = "https://example.com";
    expect(auth.acceptsPrivateHttpRequest(browserRequest)).toBe(false);
    releaseDirect();
  });

  it("fails remote private HTTP closed when no API key is configured", () => {
    const auth = new BridgeApiKeyAuthenticator();
    expect(
      auth.acceptsPrivateHttpRequest(request({ remoteAddress: "100.64.0.2" })),
    ).toBe(false);
  });
});

describe("Bridge private HTTP route classification", () => {
  it.each([
    ["GET", "/usage"],
    ["GET", "/doctor"],
    ["GET", "/api/gallery?project=/tmp"],
    ["POST", "/api/gallery/upload"],
    ["DELETE", "/api/gallery/123e4567-e89b-12d3-a456-426614174000"],
  ])("protects %s %s", (method, url) => {
    expect(requiresPrivateHttpAuthorization(method, url)).toBe(true);
  });

  it.each([
    ["GET", "/health"],
    ["GET", "/version"],
    ["GET", "/images/opaque-id"],
    ["GET", "/api/gallery/123e4567-e89b-12d3-a456-426614174000"],
  ])("keeps capability-style read route %s %s public", (method, url) => {
    expect(requiresPrivateHttpAuthorization(method, url)).toBe(false);
  });
});

describe("isLoopbackAddress", () => {
  it.each(["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1"])(
    "accepts %s",
    (address) => expect(isLoopbackAddress(address)).toBe(true),
  );

  it.each(["192.168.1.20", "100.64.0.2", "::ffff:192.168.1.20"])(
    "rejects %s",
    (address) => expect(isLoopbackAddress(address)).toBe(false),
  );
});
