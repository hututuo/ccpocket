import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  BRIDGE_IDENTITY_FILE,
  BRIDGE_IDENTITY_VERSION,
  BridgeIdentityStore,
  canonicalBridgeIdentityPayload,
  deriveBridgeIdentityId,
  verifyBridgeIdentityProof,
} from "./index.js";

describe("BridgeIdentityStore", () => {
  const roots: string[] = [];

  afterEach(async () => {
    await Promise.all(
      roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  async function root(): Promise<string> {
    const value = await mkdtemp(join(tmpdir(), "ccpocket-v4-identity-"));
    roots.push(value);
    return value;
  }

  it("persists one Ed25519 identity with private permissions only after explicit load", async () => {
    const parent = await root();
    const stateDir = join(parent, "state");
    expect(existsSync(stateDir)).toBe(false);

    const first = await BridgeIdentityStore.load({ stateDir });
    const second = await BridgeIdentityStore.load({ stateDir });

    expect(second.bridgeIdentityId).toBe(first.bridgeIdentityId);
    expect(second.publicKey).toBe(first.publicKey);
    expect(first.publicKey).toHaveLength(43);
    expect(first.bridgeIdentityId).toBe(deriveBridgeIdentityId(first.publicKey));
    expect((await lstat(stateDir)).mode & 0o777).toBe(0o700);
    expect((await lstat(join(stateDir, BRIDGE_IDENTITY_FILE))).mode & 0o777).toBe(
      0o600,
    );
  });

  it("signs and verifies the canonical nonce proof with every authority field bound", async () => {
    const stateDir = join(await root(), "state");
    const store = await BridgeIdentityStore.load({ stateDir });
    const proof = store.createNonceProof({
      bridgeInstanceId: "bridge_instance_fixture",
      nonce: "nonce_0123456789abcdef",
      authMode: "paired_or_key",
      methods: ["key", "device_signature", "key"],
    });

    expect(proof.version).toBe(BRIDGE_IDENTITY_VERSION);
    expect(proof.methods).toEqual(["device_signature", "key"]);
    expect(proof.signedPayload).toBe(canonicalBridgeIdentityPayload(proof));
    expect(store.verify(proof.signedPayload, proof.signature)).toBe(true);
    expect(verifyBridgeIdentityProof(proof)).toBe(true);

    for (const tampered of [
      { ...proof, bridgeIdentityId: `${proof.bridgeIdentityId}x` },
      { ...proof, bridgeInstanceId: "bridge_instance_other" },
      { ...proof, nonce: "nonce_fedcba9876543210" },
      { ...proof, authMode: "open" },
      { ...proof, methods: ["key"] },
      {
        ...proof,
        signature: `${proof.signature[0] === "A" ? "B" : "A"}${proof.signature.slice(1)}`,
      },
    ]) {
      expect(verifyBridgeIdentityProof(tampered)).toBe(false);
    }
    expect(store.verify(`${proof.signedPayload}x`, proof.signature)).toBe(false);
  });

  it("repairs private modes without changing a valid persisted identity", async () => {
    const stateDir = join(await root(), "state");
    const first = await BridgeIdentityStore.load({ stateDir });
    const identityFile = join(stateDir, BRIDGE_IDENTITY_FILE);
    await chmod(stateDir, 0o755);
    await chmod(identityFile, 0o644);

    const second = await BridgeIdentityStore.load({ stateDir });

    expect(second.bridgeIdentityId).toBe(first.bridgeIdentityId);
    expect((await lstat(stateDir)).mode & 0o777).toBe(0o700);
    expect((await lstat(identityFile)).mode & 0o777).toBe(0o600);
  });

  it("fails closed for malformed and mismatched key material", async () => {
    const malformedDir = join(await root(), "malformed");
    await mkdir(malformedDir, { mode: 0o700 });
    await writeFile(join(malformedDir, BRIDGE_IDENTITY_FILE), "{broken", {
      mode: 0o600,
    });
    await expect(BridgeIdentityStore.load({ stateDir: malformedDir })).rejects.toThrow(
      /malformed/,
    );

    const mismatchDir = join(await root(), "mismatch");
    await BridgeIdentityStore.load({ stateDir: mismatchDir });
    const mismatchFile = join(mismatchDir, BRIDGE_IDENTITY_FILE);
    const document = JSON.parse(await readFile(mismatchFile, "utf8")) as Record<
      string,
      unknown
    >;
    document.publicKey = randomBytes(32).toString("base64url");
    await writeFile(mismatchFile, `${JSON.stringify(document)}\n`, { mode: 0o600 });
    await expect(BridgeIdentityStore.load({ stateDir: mismatchDir })).rejects.toThrow(
      /key material is invalid/,
    );
  });

  it("rejects symlinked state directories and identity files", async () => {
    const parent = await root();
    const realDirectory = join(parent, "real");
    const linkedDirectory = join(parent, "linked");
    await mkdir(realDirectory, { mode: 0o700 });
    await symlink(realDirectory, linkedDirectory);
    await expect(BridgeIdentityStore.load({ stateDir: linkedDirectory })).rejects.toThrow(
      /real directory/,
    );

    const stateDir = join(await root(), "state");
    await mkdir(stateDir, { mode: 0o700 });
    const target = join(await root(), "identity-target");
    await writeFile(target, "{}", { mode: 0o600 });
    await symlink(target, join(stateDir, BRIDGE_IDENTITY_FILE));
    await expect(BridgeIdentityStore.load({ stateDir })).rejects.toThrow(
      /private regular file/,
    );
  });

  it("rejects non-files and oversized identity state without replacement", async () => {
    const directoryState = join(await root(), "directory-state");
    await mkdir(join(directoryState, BRIDGE_IDENTITY_FILE), {
      recursive: true,
      mode: 0o700,
    });
    await expect(BridgeIdentityStore.load({ stateDir: directoryState })).rejects.toThrow(
      /private regular file/,
    );

    const oversizedState = join(await root(), "oversized-state");
    await mkdir(oversizedState, { mode: 0o700 });
    const oversizedFile = join(oversizedState, BRIDGE_IDENTITY_FILE);
    await writeFile(oversizedFile, Buffer.alloc(64 * 1024 + 1), { mode: 0o600 });
    await expect(BridgeIdentityStore.load({ stateDir: oversizedState })).rejects.toThrow(
      /size limit/,
    );
    expect((await lstat(oversizedFile)).size).toBe(64 * 1024 + 1);
  });
});
