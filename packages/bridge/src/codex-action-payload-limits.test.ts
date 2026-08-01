import { describe, expect, it } from "vitest";
import { isCodexActionPayloadWithinLimits } from "./codex-action-payload-limits.js";

describe("Codex action payload limits", () => {
  it("accepts a bounded approval projection", () => {
    expect(
      isCodexActionPayloadWithinLimits({
        command: "git status --short",
        cwd: "/tmp/project",
        actions: [{ type: "read" }],
      }),
    ).toBe(true);
  });

  it("rejects excessive depth, nodes, individual strings, and total bytes", () => {
    let deep: Record<string, unknown> = {};
    const deepRoot = deep;
    for (let index = 0; index < 14; index += 1) {
      deep.child = {};
      deep = deep.child as Record<string, unknown>;
    }
    expect(isCodexActionPayloadWithinLimits(deepRoot)).toBe(false);
    expect(
      isCodexActionPayloadWithinLimits({
        values: Array.from({ length: 2_100 }, (_, index) => index),
      }),
    ).toBe(false);
    expect(
      isCodexActionPayloadWithinLimits({ value: "x".repeat(16 * 1024 + 1) }),
    ).toBe(false);
    expect(
      isCodexActionPayloadWithinLimits({
        values: Array.from({ length: 4 }, () => "x".repeat(13 * 1024)),
      }),
    ).toBe(false);
  });
});
