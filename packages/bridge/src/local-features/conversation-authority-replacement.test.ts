import { execFile } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { expect, it } from "vitest";

it("retires a real same-ID process authority while the original sync waits for capacity and ACK", async () => {
  const fixtureHome = await mkdtemp(join(tmpdir(), "ccpocket-replacement-test-"));
  const root = fileURLToPath(new URL("../../../../", import.meta.url));
  const harness = fileURLToPath(new URL("../../scripts/conversation-authority-replacement-harness.mjs", import.meta.url));
  try {
    const { stdout } = await promisify(execFile)(
      process.env.CCPOCKET_NODE ?? process.execPath,
      ["--import", "tsx", harness],
      {
        cwd: root, timeout: 45_000, maxBuffer: 5 * 1024 * 1024,
        env: {
          ...process.env,
          HOME: fixtureHome, CODEX_HOME: join(fixtureHome, "codex"),
          CCPOCKET_REPLACEMENT_HOME: fixtureHome,
          BRIDGE_CODEX_APP_SERVER_MODE: "private", NODE_ENV: "test",
        },
      },
    );
    const line = stdout.split("\n").find((value) => value.startsWith("C1G_ACCEPTANCE "));
    expect(line, stdout).toBeDefined();
    const proof = JSON.parse(line!.substring("C1G_ACCEPTANCE ".length));
    expect(proof.oldAuthority).not.toBe(proof.newAuthority);
    expect(proof.originalAckDrainVerified).toBe(true);
    expect(proof.oldOverlayRetired).toBe(true);
    expect(proof.newOverlaySentOnce).toBe(true);
    expect(proof.statusSequence).toBeLessThan(proof.overlaySequence);
  } finally {
    await rm(fixtureHome, { recursive: true, force: true });
  }
}, 60_000);
