import { describe, expect, it } from "vitest";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("auto-approval local protocol", () => {
  it("parses the three exact request shapes", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "get_auto_approval_state",
        sessionId: "session-1",
        requestId: "request-1",
      }),
    ).toEqual({
      type: "get_auto_approval_state",
      sessionId: "session-1",
      requestId: "request-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "set_auto_approval",
        sessionId: "session-1",
        requestId: "request-2",
        enabled: true,
      }),
    ).toEqual({
      type: "set_auto_approval",
      sessionId: "session-1",
      requestId: "request-2",
      enabled: true,
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "disable_all_auto_approvals",
        sessionId: "bridge-auto-approval",
        requestId: "request-3",
      }),
    ).toEqual({
      type: "disable_all_auto_approvals",
      sessionId: "bridge-auto-approval",
      requestId: "request-3",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "import_legacy_auto_approvals",
        sessionId: "bridge-auto-approval",
        requestId: "request-4",
        providerSessionIds: ["thread-1", "thread-1"],
      }),
    ).toEqual({
      type: "import_legacy_auto_approvals",
      sessionId: "bridge-auto-approval",
      requestId: "request-4",
      providerSessionIds: ["thread-1"],
    });
  });

  it("rejects malformed and extended payloads", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "set_auto_approval",
        sessionId: "session-1",
        requestId: "request-1",
        enabled: "yes",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "get_auto_approval_state",
        sessionId: "session-1",
        requestId: "request-1",
        extra: true,
      }),
    ).toBeNull();
  });

  it("registers the additive state capability", () => {
    expect(isLocalFeatureServerMessageType("auto_approval_state_v1")).toBe(true);
  });
});
