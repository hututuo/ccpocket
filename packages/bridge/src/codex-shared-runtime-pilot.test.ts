import { afterEach, describe, expect, it } from "vitest";
import {
  assertSharedRuntimePilotRpcAllowed,
  claimSharedRuntimePilotAttachment,
  readSharedRuntimePilotGates,
  releaseSharedRuntimePilotAttachment,
  sharedRuntimePilotAttachmentCount,
  snapshotSharedRuntimePilotGates,
} from "./codex-shared-runtime-pilot.js";

const baseEnv = {
  BRIDGE_CODEX_APP_SERVER_MODE: "daemon",
  BRIDGE_CODEX_SHARED_PILOT: "1",
  BRIDGE_CODEX_SOURCE_ID: "pilot-source",
  BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START: "0",
  BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START: "0",
};

const claimed: Array<{ owner: object; key: string | null }> = [];

function gates(env: NodeJS.ProcessEnv = baseEnv) {
  return snapshotSharedRuntimePilotGates(env);
}

afterEach(() => {
  for (const entry of claimed.splice(0)) {
    releaseSharedRuntimePilotAttachment(entry.owner, entry.key);
  }
  expect(sharedRuntimePilotAttachmentCount()).toBe(0);
});

describe("shared runtime Stage 1 pilot gates", () => {
  it("requires an explicit pilot and stable Codex source identity", () => {
    expect(() =>
      readSharedRuntimePilotGates({
        ...baseEnv,
        BRIDGE_CODEX_SHARED_PILOT: "0",
      }),
    ).toThrow("pilot-only");
    expect(() =>
      readSharedRuntimePilotGates({
        ...baseEnv,
        BRIDGE_CODEX_SOURCE_ID: "",
      }),
    ).toThrow("BRIDGE_CODEX_SOURCE_ID");
  });

  it("allows reads and strict resume while mutations remain closed", () => {
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("thread/list", null, gates()),
    ).not.toThrow();
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("thread/resume", "observer", gates()),
    ).not.toThrow();
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("thread/resume", null, gates()),
    ).toThrow("settings-neutral");
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("thread/start", null, gates()),
    ).toThrow("ALLOW_THREAD_START");
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("turn/start", "adoption", gates()),
    ).toThrow("ALLOW_TURN_START");
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("turn/steer", "adoption", gates()),
    ).toThrow("not allowed");
  });

  it("opens only the two explicit canary mutations", () => {
    const env = {
      ...baseEnv,
      BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START: "1",
      BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START: "1",
    };
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("thread/start", null, gates(env)),
    ).not.toThrow();
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("thread/name/set", null, gates(env)),
    ).not.toThrow();
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("turn/start", "adoption", gates(env)),
    ).not.toThrow();
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("turn/interrupt", null, gates(env)),
    ).not.toThrow();
    expect(() =>
      assertSharedRuntimePilotRpcAllowed("thread/delete", null, gates(env)),
    ).toThrow("not allowed");
  });

  it("permits only one attachment per source and thread", () => {
    const first = {};
    const second = {};
    const frozen = gates();
    const key = claimSharedRuntimePilotAttachment(first, "thread-1", frozen);
    claimed.push({ owner: first, key });
    expect(sharedRuntimePilotAttachmentCount()).toBe(1);
    expect(() =>
      claimSharedRuntimePilotAttachment(second, "thread-1", frozen),
    ).toThrow("already exists");
    const otherKey = claimSharedRuntimePilotAttachment(
      second,
      "thread-2",
      frozen,
    );
    claimed.push({ owner: second, key: otherKey });
    expect(sharedRuntimePilotAttachmentCount()).toBe(2);
  });
});
