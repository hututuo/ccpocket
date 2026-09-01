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
import type { StateMutationLockOptions } from "./private-state.js";

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
  const stores: BridgeIdentityStore[] = [];

  afterEach(async () => {
    await Promise.all(stores.splice(0).map((store) => store.close()));
    await Promise.all(
      roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  async function root(): Promise<string> {
    const value = await mkdtemp(join(tmpdir(), "ccpocket-v4-identity-"));
    roots.push(value);
    return value;
  }

  async function load(
    stateDir: string,
    options: { lockOptions?: StateMutationLockOptions } = {},
  ): Promise<BridgeIdentityStore> {
    const store = await BridgeIdentityStore.load({ stateDir, ...options });
    stores.push(store);
    return store;
  }

  async function close(store: BridgeIdentityStore): Promise<void> {
    await store.close();
    const index = stores.indexOf(store);
    if (index >= 0) stores.splice(index, 1);
  }

  it("persists one Ed25519 identity with private permissions only after explicit load", async () => {
    const parent = await root();
    const stateDir = join(parent, "state");
    expect(existsSync(stateDir)).toBe(false);

    const first = await load(stateDir);
    const firstIdentity = first.bridgeIdentityId;
    await close(first);
    const second = await load(stateDir);

    expect(second.bridgeIdentityId).toBe(firstIdentity);
    expect(second.publicKey).toBe(first.publicKey);
    expect(first.publicKey).toHaveLength(43);
    expect(first.bridgeIdentityId).toBe(
      deriveBridgeIdentityId(first.publicKey),
    );
    expect((await lstat(stateDir)).mode & 0o777).toBe(0o700);
    expect(
      (await lstat(join(stateDir, BRIDGE_IDENTITY_FILE))).mode & 0o777,
    ).toBe(0o600);
  });

  it("signs and verifies the canonical nonce proof with every authority field bound", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const challenge = {
      bridgeInstanceId: "bridge_instance_fixture",
      nonce: "bm9uY2VfMDEyMzQ1Njc4OWFiY2RlZg",
      authMode: "paired_or_key",
      methods: ["key", "device_signature", "key"],
    } as const;
    const proof = store.createNonceProof(challenge);

    expect(proof.version).toBe(BRIDGE_IDENTITY_VERSION);
    expect(proof.methods).toEqual(["device_signature", "key"]);
    expect(proof.signedPayload).toBe(canonicalBridgeIdentityPayload(proof));
    expect(store.verify(proof.signedPayload, proof.signature)).toBe(true);
    expect(verifyBridgeIdentityProof(proof, challenge)).toBe(true);

    for (const tampered of [
      { ...proof, bridgeIdentityId: `${proof.bridgeIdentityId}x` },
      { ...proof, bridgeInstanceId: "bridge_instance_other" },
      { ...proof, nonce: "bm9uY2VfZmVkY2JhOTg3NjU0MzIxMA" },
      { ...proof, authMode: "open" },
      { ...proof, methods: ["key"] },
      {
        ...proof,
        signature: `${proof.signature[0] === "A" ? "B" : "A"}${proof.signature.slice(1)}`,
      },
    ]) {
      expect(verifyBridgeIdentityProof(tampered, challenge)).toBe(false);
    }
    expect(
      verifyBridgeIdentityProof(proof, {
        ...challenge,
        nonce: "bm9uY2VfZmVkY2JhOTg3NjU0MzIxMA",
      }),
    ).toBe(false);
    expect(
      verifyBridgeIdentityProof({ ...proof, unsignedClaim: "admin" }, challenge),
    ).toBe(false);
    expect(
      verifyBridgeIdentityProof(
        { ...proof, methods: [null] },
        challenge,
      ),
    ).toBe(false);
    expect(store.verify(`${proof.signedPayload}x`, proof.signature)).toBe(
      false,
    );
  });

  it("repairs private modes without changing a valid persisted identity", async () => {
    const stateDir = join(await root(), "state");
    const first = await load(stateDir);
    const identityFile = join(stateDir, BRIDGE_IDENTITY_FILE);
    const firstIdentity = first.bridgeIdentityId;
    await close(first);
    await chmod(stateDir, 0o755);
    await chmod(identityFile, 0o644);

    const second = await load(stateDir);

    expect(second.bridgeIdentityId).toBe(firstIdentity);
    expect((await lstat(stateDir)).mode & 0o777).toBe(0o700);
    expect((await lstat(identityFile)).mode & 0o777).toBe(0o600);
  });

  it("fails closed for malformed and mismatched key material", async () => {
    const malformedDir = join(await root(), "malformed");
    await mkdir(malformedDir, { mode: 0o700 });
    await writeFile(join(malformedDir, BRIDGE_IDENTITY_FILE), "{broken", {
      mode: 0o600,
    });
    await expect(
      BridgeIdentityStore.load({ stateDir: malformedDir }),
    ).rejects.toThrow(/malformed/);

    const mismatchDir = join(await root(), "mismatch");
    const mismatchStore = await load(mismatchDir);
    await close(mismatchStore);
    const mismatchFile = join(mismatchDir, BRIDGE_IDENTITY_FILE);
    const document = JSON.parse(await readFile(mismatchFile, "utf8")) as Record<
      string,
      unknown
    >;
    document.publicKey = randomBytes(32).toString("base64url");
    await writeFile(mismatchFile, `${JSON.stringify(document)}\n`, {
      mode: 0o600,
    });
    await expect(
      BridgeIdentityStore.load({ stateDir: mismatchDir }),
    ).rejects.toThrow(/key material is invalid/);
  });

  it("rejects an outer methods order or duplicate mismatch", async () => {
    const stateDir = join(await root(), "state");
    const store = await load(stateDir);
    const challenge = {
      bridgeInstanceId: "bridge_instance_fixture",
      nonce: "bm9uY2VfMDEyMzQ1Njc4OWFiY2RlZg",
      authMode: "paired_or_key",
      methods: ["key", "device_signature"],
    } as const;
    const proof = store.createNonceProof(challenge);

    expect(
      verifyBridgeIdentityProof(
        { ...proof, methods: proof.methods },
        challenge,
      ),
    ).toBe(true);
    expect(
      verifyBridgeIdentityProof({
        ...proof,
        methods: ["key", "device_signature", "key"],
      }, challenge),
    ).toBe(false);
    expect(
      verifyBridgeIdentityProof({
        ...proof,
        methods: ["key", "device_signature"],
      }, challenge),
    ).toBe(false);
  });

  it("holds a cross-process writer lease until close", async () => {
    const stateDir = join(await root(), "state");
    const first = await load(stateDir, {
      lockOptions: { attempts: 2, retryMs: 0 },
    });
    await expect(
      BridgeIdentityStore.load({
        stateDir,
        lockOptions: { attempts: 2, retryMs: 0 },
      }),
    ).rejects.toThrow(/writer lease is busy/);
    await close(first);

    const reopened = await load(stateDir, {
      lockOptions: { attempts: 2, retryMs: 0 },
    });
    expect(reopened.bridgeIdentityId).toBe(first.bridgeIdentityId);
  });

  it("rejects symlinked state directories and identity files", async () => {
    const parent = await root();
    const realDirectory = join(parent, "real");
    const linkedDirectory = join(parent, "linked");
    await mkdir(realDirectory, { mode: 0o700 });
    await symlink(realDirectory, linkedDirectory);
    await expect(
      BridgeIdentityStore.load({ stateDir: linkedDirectory }),
    ).rejects.toThrow(/real directory/);

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
    await expect(
      BridgeIdentityStore.load({ stateDir: directoryState }),
    ).rejects.toThrow(/private regular file/);

    const oversizedState = join(await root(), "oversized-state");
    await mkdir(oversizedState, { mode: 0o700 });
    const oversizedFile = join(oversizedState, BRIDGE_IDENTITY_FILE);
    await writeFile(oversizedFile, Buffer.alloc(64 * 1024 + 1), {
      mode: 0o600,
    });
    await expect(
      BridgeIdentityStore.load({ stateDir: oversizedState }),
    ).rejects.toThrow(/size limit/);
    expect((await lstat(oversizedFile)).size).toBe(64 * 1024 + 1);
  });
});
