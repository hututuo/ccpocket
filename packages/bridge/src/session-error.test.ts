import { describe, expect, it } from "vitest";
import { normalizeSessionError } from "./session-error.js";

describe("normalizeSessionError", () => {
  it("adds stable session ownership metadata without changing the message", () => {
    const original = {
      type: "error" as const,
      message: "settings rejected",
      errorCode: "settings_rejected",
      operationId: "op-1",
    };

    const normalized = normalizeSessionError(original, {
      sessionId: "thread-1",
      errorSource: "control",
      errorPhase: "settings_write",
    });

    expect(normalized).toMatchObject({
      ...original,
      sessionId: "thread-1",
      errorCode: "settings_rejected",
      errorSource: "control",
      errorPhase: "settings_write",
    });
    expect(normalized.errorEventId).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("does not rewrite an error explicitly owned by another session", () => {
    const original = {
      type: "error" as const,
      message: "wrong owner",
      sessionId: "thread-2",
      errorEventId: "event-2",
    };

    expect(
      normalizeSessionError(original, { sessionId: "thread-1" }),
    ).toBe(original);
  });

  it("keeps an existing identity and metadata", () => {
    const original = {
      type: "error" as const,
      message: "already normalized",
      sessionId: "thread-1",
      errorCode: "known",
      errorEventId: "event-1",
      errorSource: "provider" as const,
      errorPhase: "provider_stream",
    };

    expect(
      normalizeSessionError(original, {
        sessionId: "thread-1",
        errorSource: "bridge",
        errorPhase: "request",
      }),
    ).toEqual(original);
  });
});
