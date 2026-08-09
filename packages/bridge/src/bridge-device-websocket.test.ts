import { createServer } from "node:http";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocket as WsClient } from "ws";
import { BridgeWebSocketServer } from "./websocket.js";
import { BridgeApiKeyAuthenticator } from "./bridge-http-auth.js";
import { BridgeIdentityStore } from "./bridge-identity.js";
import {
  BridgeDevicePairing,
  canonicalDeviceChallengePayload,
} from "./bridge-device-pairing.js";

describe("paired Bridge WebSocket admission", () => {
  const roots: string[] = [];
  afterEach(async () => {
    await Promise.all(
      roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  it("sends only a challenge before authentication and activates legacy data after proof", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-ws-pair-"));
    roots.push(root);
    const identity = await BridgeIdentityStore.load({
      stateDir: root,
      platform: "linux",
      hostnameValue: "test-host",
    });
    const pairing = new BridgeDevicePairing({
      stateDir: root,
      bridgeIdentity: identity,
      bridgeInstanceId: "bridge-instance",
    });
    await pairing.init();
    const keys = generateKeyPairSync("ed25519");
    const publicKey = keys.publicKey
      .export({ format: "der", type: "spki" })
      .toString("base64url");
    await pairing.enroll({ deviceId: "phone-ws", publicKey });

    const httpServer = createServer();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      authMode: "paired_or_key",
      bridgeIdentity: identity,
      devicePairing: pairing,
      apiKeyAuthenticator: new BridgeApiKeyAuthenticator(),
    });
    await new Promise<void>((resolve) =>
      httpServer.listen(0, "127.0.0.1", resolve),
    );
    const port = (httpServer.address() as { port: number }).port;
    const messages: Array<Record<string, unknown>> = [];
    const client = new WsClient(`ws://127.0.0.1:${port}`);
    const authenticated = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("authentication timeout")),
        3000,
      );
      client.on("message", (data) => {
        const msg = JSON.parse(data.toString()) as Record<string, unknown>;
        messages.push(msg);
        if (msg.type === "bridge_device_challenge") {
          const payload = canonicalDeviceChallengePayload({
            challengeId: String(msg.challengeId),
            nonce: String(msg.nonce),
            expiresAt: String(msg.expiresAt),
            bridgeIdentityId: String(msg.bridgeIdentityId),
            bridgeInstanceId: String(msg.bridgeInstanceId),
            deviceId: "phone-ws",
          });
          client.send(
            JSON.stringify({
              type: "device_auth",
              challengeId: msg.challengeId,
              nonce: msg.nonce,
              expiresAt: msg.expiresAt,
              bridgeIdentityId: msg.bridgeIdentityId,
              bridgeInstanceId: msg.bridgeInstanceId,
              deviceId: "phone-ws",
              publicKey,
              signature: sign(
                null,
                Buffer.from(payload),
                keys.privateKey,
              ).toString("base64url"),
            }),
          );
        }
        if (msg.type === "session_list") {
          clearTimeout(timer);
          resolve();
        }
      });
      client.on("error", reject);
    });
    try {
      await authenticated;
      expect(messages[0]?.type).toBe("bridge_device_challenge");
      expect(
        messages.some(
          (message) => message.type === "bridge_device_authenticated",
        ),
      ).toBe(true);
      expect(messages.some((message) => message.type === "session_list")).toBe(
        true,
      );
      expect(
        messages.some((message) => message.type === "project_history"),
      ).toBe(true);
    } finally {
      client.close();
      await bridge.close();
      await new Promise<void>((resolve) => httpServer.close(() => resolve()));
    }
  });

  it("keeps a Mac-approval socket pending and re-challenges after approval", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-ws-approve-"));
    roots.push(root);
    const identity = await BridgeIdentityStore.load({
      stateDir: root,
      platform: "linux",
      hostnameValue: "test-host",
    });
    const pairing = new BridgeDevicePairing({
      stateDir: root,
      bridgeIdentity: identity,
      bridgeInstanceId: "bridge-instance",
    });
    await pairing.init();
    const keys = generateKeyPairSync("ed25519");
    const publicKey = keys.publicKey
      .export({ format: "der", type: "spki" })
      .toString("base64url");
    const httpServer = createServer();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      authMode: "paired_or_key",
      bridgeIdentity: identity,
      devicePairing: pairing,
      apiKeyAuthenticator: new BridgeApiKeyAuthenticator(),
    });
    await new Promise<void>((resolve) =>
      httpServer.listen(0, "127.0.0.1", resolve),
    );
    const port = (httpServer.address() as { port: number }).port;
    const client = new WsClient(`ws://127.0.0.1:${port}`);
    let pairingRequest: Record<string, unknown> | undefined;
    let approved = false;
    const complete = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("Mac approval handshake timeout")),
        4_000,
      );
      client.on("message", (data) => {
        void (async () => {
          const msg = JSON.parse(data.toString()) as Record<string, unknown>;
          if (msg.type === "bridge_device_challenge") {
            if (!approved) {
              pairingRequest = {
                type: "device_pairing_request",
                deviceId: "phone-approve",
                publicKey,
                label: "Approval phone",
              };
              client.send(JSON.stringify(pairingRequest));
              return;
            }
            const payload = canonicalDeviceChallengePayload({
              challengeId: String(msg.challengeId),
              nonce: String(msg.nonce),
              expiresAt: String(msg.expiresAt),
              bridgeIdentityId: String(msg.bridgeIdentityId),
              bridgeInstanceId: String(msg.bridgeInstanceId),
              deviceId: "phone-approve",
            });
            client.send(
              JSON.stringify({
                type: "device_auth",
                challengeId: msg.challengeId,
                nonce: msg.nonce,
                expiresAt: msg.expiresAt,
                bridgeIdentityId: msg.bridgeIdentityId,
                bridgeInstanceId: msg.bridgeInstanceId,
                deviceId: "phone-approve",
                publicKey,
                signature: sign(
                  null,
                  Buffer.from(payload),
                  keys.privateKey,
                ).toString("base64url"),
              }),
            );
            return;
          }
          if (
            msg.type === "bridge_pairing_pending" &&
            msg.status === "pending"
          ) {
            await pairing.approve(String(msg.confirmationCode));
            approved = true;
            client.send(JSON.stringify(pairingRequest));
            return;
          }
          if (msg.type === "session_list") {
            clearTimeout(timer);
            resolve();
          }
        })().catch(reject);
      });
      client.on("error", reject);
    });
    try {
      await complete;
    } finally {
      client.close();
      await bridge.close();
      await new Promise<void>((resolve) => httpServer.close(() => resolve()));
    }
  });
});
