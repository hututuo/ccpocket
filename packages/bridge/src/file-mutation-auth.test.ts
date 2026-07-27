import {
  generateKeyPairSync,
  randomBytes,
  scrypt as nodeScrypt,
  sign,
  type KeyObject,
} from "node:crypto";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  FileMutationAuthError,
  FileMutationAuthorizer,
  FileMutationAuthStore,
  type FileMutationOperation,
} from "./file-mutation-auth.js";

const temporaryDirectories: string[] = [];
const testCredential = ["correct", "horse", "battery"].join("-");
const replacementCredential = ["different", "bridge", "credential"].join("-");
const incorrectCredential = ["incorrect", "bridge", "credential"].join("-");
const operation: FileMutationOperation = {
  kind: "upload",
  transferId: "transfer_1234567890",
  filename: "report.json",
  sizeBytes: 42,
};

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

describe("FileMutationAuthorizer", () => {
  it("stores only a private Argon2id verifier and revokes devices on password change", async () => {
    const fixture = await createFixture();
    await fixture.store.setPassword(testCredential);
    await fixture.authorizer.enrollDevice(fixture.client, {
      deviceId: "ios:test-device",
      publicKey: fixture.publicKey,
      password: testCredential,
    });
    expect(await fixture.store.status("ios:test-device")).toEqual({
      passwordConfigured: true,
      biometricEnrolled: true,
    });

    const persisted = await readFile(fixture.filePath, "utf8");
    expect(persisted).not.toContain(testCredential);
    expect(JSON.parse(persisted).password).toMatchObject({
      algorithm: "argon2id",
      memoryCostKiB: 19 * 1024,
      timeCost: 2,
      parallelism: 1,
      outputLength: 32,
      version: 19,
    });
    expect((await stat(fixture.filePath)).mode & 0o077).toBe(0);

    await fixture.store.setPassword(replacementCredential);
    expect(await fixture.store.status("ios:test-device")).toEqual({
      passwordConfigured: true,
      biometricEnrolled: false,
    });
  });

  it("accepts the configured password and rejects an incorrect password", async () => {
    const fixture = await createFixture();
    await fixture.store.setPassword(testCredential);
    await expect(
      fixture.authorizer.authorize(fixture.client, operation, {
        method: "password",
        password: testCredential,
      }),
    ).resolves.toBeUndefined();
    await expect(
      fixture.authorizer.authorize(fixture.client, operation, {
        method: "password",
        password: incorrectCredential,
      }),
    ).rejects.toMatchObject<FileMutationAuthError>({
      code: "invalid_password",
    });
  });

  it("reloads a password changed by the standalone Bridge command", async () => {
    const fixture = await createFixture();
    await fixture.store.setPassword(testCredential);
    await expect(fixture.store.verifyPassword(testCredential)).resolves.toBe(
      true,
    );

    const commandStore = new FileMutationAuthStore({
      filePath: fixture.filePath,
    });
    await commandStore.setPassword(replacementCredential);

    await expect(fixture.store.verifyPassword(testCredential)).resolves.toBe(
      false,
    );
    await expect(
      fixture.store.verifyPassword(replacementCredential),
    ).resolves.toBe(true);
  });

  it("keeps early scrypt password stores readable without writing new scrypt verifiers", async () => {
    const fixture = await createFixture();
    await writeLegacyScryptStore(fixture.filePath, testCredential);
    await expect(fixture.store.verifyPassword(testCredential)).resolves.toBe(
      true,
    );
    await expect(
      fixture.store.verifyPassword(incorrectCredential),
    ).resolves.toBe(false);

    await fixture.store.setPassword(replacementCredential);
    const persisted = JSON.parse(await readFile(fixture.filePath, "utf8"));
    expect(persisted.password.algorithm).toBe("argon2id");
    await expect(
      fixture.store.verifyPassword(replacementCredential),
    ).resolves.toBe(true);
  });

  it("binds a biometric signature to one client, operation, and one-time challenge", async () => {
    const fixture = await createFixture();
    await fixture.store.setPassword(testCredential);
    await fixture.authorizer.enrollDevice(fixture.client, {
      deviceId: "ios:test-device",
      publicKey: fixture.publicKey,
      password: testCredential,
    });
    const challenge = await fixture.authorizer.issueChallenge(
      fixture.client,
      "ios:test-device",
      operation,
    );
    const signature = signPayload(fixture.privateKey, challenge.payload);
    const proof = {
      method: "biometric" as const,
      challengeId: challenge.challengeId,
      deviceId: "ios:test-device",
      signature,
    };
    await expect(
      fixture.authorizer.authorize(fixture.client, operation, proof),
    ).resolves.toBeUndefined();
    await expect(
      fixture.authorizer.authorize(fixture.client, operation, proof),
    ).rejects.toMatchObject<FileMutationAuthError>({
      code: "challenge_invalid_or_expired",
    });
  });

  it("consumes a challenge when a different operation or client tries to use it", async () => {
    const fixture = await createFixture();
    await fixture.store.setPassword(testCredential);
    await fixture.authorizer.enrollDevice(fixture.client, {
      deviceId: "ios:test-device",
      publicKey: fixture.publicKey,
      password: testCredential,
    });
    const challenge = await fixture.authorizer.issueChallenge(
      fixture.client,
      "ios:test-device",
      operation,
    );
    const proof = {
      method: "biometric" as const,
      challengeId: challenge.challengeId,
      deviceId: "ios:test-device",
      signature: signPayload(fixture.privateKey, challenge.payload),
    };
    await expect(
      fixture.authorizer.authorize(
        {},
        { ...operation, filename: "other.json" },
        proof,
      ),
    ).rejects.toMatchObject<FileMutationAuthError>({
      code: "challenge_invalid_or_expired",
    });
    await expect(
      fixture.authorizer.authorize(fixture.client, operation, proof),
    ).rejects.toMatchObject<FileMutationAuthError>({
      code: "challenge_invalid_or_expired",
    });
  });
});

async function createFixture() {
  const directory = await mkdtemp(join(tmpdir(), "ccpocket-file-auth-"));
  temporaryDirectories.push(directory);
  const filePath = join(directory, "auth.json");
  const store = new FileMutationAuthStore({ filePath });
  const authorizer = new FileMutationAuthorizer({
    store,
    bridgeInstanceId: "bridge-test",
  });
  const client = {};
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const jwk = publicKey.export({ format: "jwk" });
  const x = Buffer.from(jwk.x!, "base64url");
  const y = Buffer.from(jwk.y!, "base64url");
  return {
    filePath,
    store,
    authorizer,
    client,
    privateKey,
    publicKey: Buffer.concat([Buffer.from([0x04]), x, y]).toString("base64url"),
  };
}

function signPayload(privateKey: KeyObject, payload: string): string {
  return sign("sha256", Buffer.from(payload, "utf8"), privateKey).toString(
    "base64url",
  );
}

async function writeLegacyScryptStore(
  filePath: string,
  password: string,
): Promise<void> {
  const salt = randomBytes(16);
  const hash = await new Promise<Buffer>((resolve, reject) => {
    nodeScrypt(
      password,
      salt,
      64,
      {
        N: 1 << 15,
        r: 8,
        p: 1,
        maxmem: 64 * 1024 * 1024,
      },
      (error, derivedKey) => {
        if (error) reject(error);
        else resolve(Buffer.from(derivedKey));
      },
    );
  });
  await writeFile(
    filePath,
    `${JSON.stringify({
      version: 1,
      password: {
        algorithm: "scrypt",
        salt: salt.toString("base64url"),
        hash: hash.toString("base64url"),
        n: 1 << 15,
        r: 8,
        p: 1,
      },
      devices: [],
    })}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}
