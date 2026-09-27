import { describe, expect, it } from "vitest";
import { isCodexActionPayloadWithinLimits } from "./codex-action-payload-limits.js";
import { projectCodexServerActionRequest } from "./codex-process.js";

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

describe("Codex Action Broker payload bounds", () => {
  it.each([
    ["item/commandExecution/requestApproval", { command: "synthetic", availableDecisions: ["accept", "decline"] }],
    ["item/fileChange/requestApproval", { changes: [], availableDecisions: ["accept", "decline"] }],
    ["item/permissions/requestApproval", { permissions: { network: { enabled: true } } }],
  ])("accepts bounded shared references in the production %s projection", (method, params) => {
    const projection = projectCodexServerActionRequest("fixture", method as string, params as Record<string, unknown>);
    expect(projection).not.toBeNull();
    expect(isCodexActionPayloadWithinLimits(projection)).toBe(true);
    expect(isCodexActionPayloadWithinLimits(JSON.parse(JSON.stringify(projection)))).toBe(true);
  });

  it("rejects actual object and array cycles", () => {
    const object: Record<string, unknown> = {};
    object.self = object;
    const array: unknown[] = [];
    array.push(array);
    for (const value of [object, array, { nested: object }]) {
      expect(isCodexActionPayloadWithinLimits(value)).toBe(false);
    }
  });

  it("counts repeated subtrees against serialized byte and node bounds", () => {
    const text = { text: "x".repeat(16 * 1024) };
    expect(isCodexActionPayloadWithinLimits([text, text])).toBe(true);
    expect(isCodexActionPayloadWithinLimits([text, text, text])).toBe(false);
    const manyNodes = Array.from({ length: 1024 }, () => ({}));
    expect(isCodexActionPayloadWithinLimits([manyNodes, manyNodes])).toBe(false);
  });

  it("still rejects deep, oversized, nonfinite and non-JSON data", () => {
    let deep: unknown = null;
    for (let i = 0; i < 14; i++) deep = { child: deep };
    for (const value of [deep, "x".repeat(16 * 1024 + 1), NaN, Infinity, undefined, new Date(), () => null]) {
      expect(isCodexActionPayloadWithinLimits(value)).toBe(false);
    }
  });
});
