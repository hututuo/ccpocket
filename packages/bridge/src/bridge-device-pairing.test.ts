import { generateKeyPairSync, sign } from "node:crypto";
import { lstat, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { BridgeIdentityStore } from "./bridge-identity.js";
import {
  BridgeDevicePairing,
  DEVICE_AUTH_TIMEOUT_MS,
  canonicalDeviceChallengePayload,
} from "./bridge-device-pairing.js";

function mobileKey(): {
  publicKey: string;
  privateKey: ReturnType<typeof generateKeyPairSync>["privateKey"];
} {
  const keys = generateKeyPairSync("ed25519");
  return {
    publicKey: keys.publicKey
      .export({ format: "der", type: "spki" })
      .toString("base64url"),
    privateKey: keys.privateKey,
  };
}

describe("Bridge device pairing", () => {
  const roots: string[] = [];
  afterEach(async () => {
    await Promise.all(
      roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  async function fixture() {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-pairing-"));
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
    return { root, identity, pairing };
  }

  it("uses one-time 256-bit QR tokens and caps token state", async () => {
    const { pairing } = await fixture();
    const qr = await pairing.createPairingToken({
      bridgeUrl: "ws://127.0.0.1:8765",
    });
    expect(qr.token.length).toBeGreaterThanOrEqual(43);
    expect(qr.deepLink).toContain("ccpocket://pair?");
    const key = mobileKey();
    const paired = await pairing.requestPairing({
      deviceId: "phone-1",
      publicKey: key.publicKey,
      token: qr.token,
    });
    expect(paired.status).toBe("paired");
    await expect(
      pairing.requestPairing({
        deviceId: "phone-2",
        publicKey: mobileKey().publicKey,
        token: qr.token,
      }),
    ).rejects.toThrow(/invalid or expired/);
    const stats = await lstat(
      join(pairing.stateDir, "trusted-mobile-devices-v1.json"),
    );
    expect(stats.mode & 0o777).toBe(0o600);
    const persisted = JSON.parse(
      await readFile(join(pairing.stateDir, "pairing-state-v1.json"), "utf8"),
    ) as Record<string, unknown>;
    expect(JSON.stringify(persisted)).not.toContain(qr.token);
  });

  it("supports Mac approval and revocation through the same trust table", async () => {
    const { pairing } = await fixture();
    const key = mobileKey();
    const pending = await pairing.requestPairing({
      deviceId: "phone-approve",
      publicKey: key.publicKey,
      label: "My phone",
    });
    expect(pending.status).toBe("pending");
    if (pending.status !== "pending") throw new Error("expected pending");
    const approved = await pairing.approve(pending.request.confirmationCode);
    expect(approved.label).toBe("My phone");
    const polled = await pairing.requestPairing({
      deviceId: "phone-approve",
      publicKey: key.publicKey,
      label: "My phone",
    });
    expect(polled.status).toBe("paired");
    expect(
      (await pairing.snapshot()).devices.map((device) => device.deviceId),
    ).toContain("phone-approve");
    expect(await pairing.revoke("phone-approve")).toBe(true);
    expect(await pairing.trustedDevice("phone-approve")).toBeUndefined();
    expect(await pairing.reject(pending.request.confirmationCode)).toBe(false);
  });

  it("keeps an explicit rejection stable until the request expires", async () => {
    const { pairing } = await fixture();
    const key = mobileKey();
    const pending = await pairing.requestPairing({
      deviceId: "phone-reject",
      publicKey: key.publicKey,
    });
    if (pending.status !== "pending") throw new Error("expected pending");
    expect(await pairing.reject(pending.request.confirmationCode)).toBe(true);
    const polled = await pairing.requestPairing({
      deviceId: "phone-reject",
      publicKey: key.publicKey,
    });
    expect(polled.status).toBe("rejected");
  });

  it("fails closed when trusted-device state is malformed", async () => {
    const { pairing } = await fixture();
    await writeFile(pairing.trustedFile, "{broken", { mode: 0o600 });
    await expect(pairing.trustedDevice("phone-1")).rejects.toThrow(
      /unreadable or malformed/,
    );
    await expect(pairing.init()).rejects.toThrow(/unreadable or malformed/);
  });

  it("verifies challenge bindings, expiry, key identity, and single-use replay", async () => {
    const { pairing, identity } = await fixture();
    const key = mobileKey();
    await pairing.enroll({ deviceId: "phone-auth", publicKey: key.publicKey });
    const challenge = pairing.createChallenge();
    const payload = canonicalDeviceChallengePayload({
      challengeId: challenge.challengeId,
      nonce: challenge.nonce,
      expiresAt: challenge.expiresAt,
      bridgeIdentityId: identity.bridgeIdentityId,
      bridgeInstanceId: "bridge-instance",
      deviceId: "phone-auth",
    });
    const request = {
      ...challenge,
      deviceId: "phone-auth",
      publicKey: key.publicKey,
      signature: sign(null, Buffer.from(payload), key.privateKey).toString(
        "base64url",
      ),
    };
    const authenticated = await pairing.authenticate(request);
    expect(authenticated.deviceId).toBe("phone-auth");
    await expect(pairing.authenticate(request)).rejects.toThrow(
      /invalid or expired/,
    );
    const wrong = pairing.createChallenge();
    await expect(
      pairing.authenticate({
        ...request,
        ...wrong,
        signature: request.signature,
      }),
    ).rejects.toThrow(/binding|invalid/);
  });

  it("does not accept expired challenge records", async () => {
    let now = Date.now();
    const root = await mkdtemp(join(tmpdir(), "ccpocket-pairing-expiry-"));
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
      now: () => now,
    });
    await pairing.init();
    const key = mobileKey();
    await pairing.enroll({
      deviceId: "phone-expiry",
      publicKey: key.publicKey,
    });
    const challenge = pairing.createChallenge();
    now += DEVICE_AUTH_TIMEOUT_MS + 1;
    await expect(
      pairing.authenticate({
        ...challenge,
        deviceId: "phone-expiry",
        publicKey: key.publicKey,
        signature: "A".repeat(86),
      }),
    ).rejects.toThrow(/expired/);
  });
});
