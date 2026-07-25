import { generateKeyPairSync } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  readFileAccessStatus,
  setFileAccessPassword,
} from "./file-access-command.js";
import { FileMutationAuthStore } from "./file-mutation-auth.js";

const temporaryDirectories: string[] = [];
const testCredential = ["correct", "horse", "battery"].join("-");

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

describe("file-access command", () => {
  it("configures the persisted password without exposing its verifier", async () => {
    const store = await createStore();

    await setFileAccessPassword({
      store,
      password: testCredential,
    });

    await expect(readFileAccessStatus(store)).resolves.toEqual({
      passwordConfigured: true,
      biometricDeviceCount: 0,
    });
    await expect(store.verifyPassword(testCredential)).resolves.toBe(true);
  });

  it("reports biometric enrollment count without exposing device identities", async () => {
    const store = await createStore();
    await store.setPassword(testCredential);
    const { publicKey } = generateKeyPairSync("ec", {
      namedCurve: "prime256v1",
    });
    const jwk = publicKey.export({ format: "jwk" });
    await store.enrollDevice(
      "ios:test-device",
      Buffer.concat([
        Buffer.from([0x04]),
        Buffer.from(jwk.x!, "base64url"),
        Buffer.from(jwk.y!, "base64url"),
      ]).toString("base64url"),
    );

    await expect(readFileAccessStatus(store)).resolves.toEqual({
      passwordConfigured: true,
      biometricDeviceCount: 1,
    });
  });
});

async function createStore(): Promise<FileMutationAuthStore> {
  const directory = await mkdtemp(join(tmpdir(), "ccpocket-file-access-cli-"));
  temporaryDirectories.push(directory);
  return new FileMutationAuthStore({
    filePath: join(directory, "auth.json"),
  });
}
