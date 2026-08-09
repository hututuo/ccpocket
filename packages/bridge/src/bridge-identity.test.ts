import { createHash } from "node:crypto";
import { lstat, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  BridgeIdentityStore,
  BRIDGE_IDENTITY_VERSION,
  canonicalBridgeIdentityPayload,
  isValidIdentityNonce,
  normalizeBridgeDisplayName,
  readBridgeComputerName,
} from "./bridge-identity.js";

describe("Bridge Ed25519 identity", () => {
  const roots: string[] = [];
  afterEach(async () => {
    await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  });

  it("persists one key across reloads with private permissions and signs canonical proofs", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-identity-"));
    roots.push(root);
    const first = await BridgeIdentityStore.load({
      stateDir: root,
      platform: "linux",
      hostnameValue: "host-one",
      displayName: "ignored",
    });
    const second = await BridgeIdentityStore.load({ stateDir: root, platform: "linux", hostnameValue: "host-two" });
    expect(second.bridgeIdentityId).toBe(first.bridgeIdentityId);
    expect(second.publicKey).toBe(first.publicKey);
    expect(first.publicKey.length).toBe(43);
    expect(first.bridgeIdentityId).toBe(
      `bridge_${createHash("sha256").update(Buffer.from(first.publicKey, "base64url")).digest("base64url")}`,
    );
    const stats = await lstat(join(root, "bridge-identity-v1.json"));
    expect(stats.mode & 0o777).toBe(0o600);
    const proof = first.response({
      nonce: "nonce_1234567890",
      bridgeInstanceId: "bridge-instance",
      authMode: "paired_or_key",
      methods: ["device_signature"],
    });
    const payload = canonicalBridgeIdentityPayload(proof);
    expect(proof.signedPayload).toBe(payload);
    expect(first.verify(payload, proof.signature)).toBe(true);
    expect(first.verify(`${payload}x`, proof.signature)).toBe(false);
    expect(proof.version).toBe(BRIDGE_IDENTITY_VERSION);
  });

  it("recovers atomically from corrupt identity state without exposing private data", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-identity-recovery-"));
    roots.push(root);
    const path = join(root, "bridge-identity-v1.json");
    await import("node:fs/promises").then(({ writeFile }) => writeFile(path, "{broken", { mode: 0o600 }));
    const identity = await BridgeIdentityStore.load({ stateDir: root, platform: "linux", hostnameValue: "fallback" });
    const persisted = JSON.parse(await readFile(path, "utf8")) as Record<string, unknown>;
    expect(persisted.version).toBe(1);
    expect(typeof persisted.publicKey).toBe("string");
    expect(typeof persisted.privateKey).toBe("string");
    expect(persisted.privateKey).not.toContain(identity.bridgeIdentityId);
  });

  it("normalizes display names and uses hostname fallback off macOS", () => {
    expect(normalizeBridgeDisplayName("  a\u0000\n b ")).toBe("a b");
    expect(normalizeBridgeDisplayName("x".repeat(120))).toHaveLength(80);
    expect(readBridgeComputerName({ platform: "linux", hostnameValue: "linux-host" })).toBe("linux-host");
    expect(readBridgeComputerName({ platform: "linux", hostnameValue: "\u0000" })).toBe("Bridge");
    expect(isValidIdentityNonce("A_b-123456789012")).toBe(true);
    expect(isValidIdentityNonce("short")).toBe(false);
  });
});
