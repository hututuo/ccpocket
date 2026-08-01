import { describe, expect, it } from "vitest";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("auto-approval local protocol", () => {
  it("parses legacy runtime-session and durable source/thread targets", () => {
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
        type: "get_auto_approval_state",
        requestId: "request-scoped-get",
        codexSourceId: "source-1",
        providerSessionId: "thread-1",
      }),
    ).toEqual({
      type: "get_auto_approval_state",
      requestId: "request-scoped-get",
      codexSourceId: "source-1",
      providerSessionId: "thread-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "set_auto_approval",
        sessionId: "ui-session-1",
        requestId: "request-scoped-set",
        codexSourceId: "source-1",
        providerSessionId: "thread-1",
        enabled: true,
      }),
    ).toEqual({
      type: "set_auto_approval",
      sessionId: "ui-session-1",
      requestId: "request-scoped-set",
      codexSourceId: "source-1",
      providerSessionId: "thread-1",
      enabled: true,
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "disable_all_auto_approvals",
        requestId: "request-3",
        codexSourceId: "source-1",
      }),
    ).toEqual({
      type: "disable_all_auto_approvals",
      requestId: "request-3",
      codexSourceId: "source-1",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "disable_all_auto_approvals",
        sessionId: "bridge-auto-approval",
        requestId: "request-legacy-disable",
      }),
    ).toEqual({
      type: "disable_all_auto_approvals",
      sessionId: "bridge-auto-approval",
      requestId: "request-legacy-disable",
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
        type: "set_auto_approval",
        requestId: "partial-target",
        codexSourceId: "source-1",
        enabled: true,
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "get_auto_approval_state",
        requestId: "missing-target",
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
    expect(isLocalFeatureServerMessageType("auto_approval_state_v1")).toBe(
      true,
    );
  });
});
