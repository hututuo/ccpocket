import { describe, expect, it } from "vitest";
import {
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
} from "./protocol.js";

describe("ephemeral side chat local protocol", () => {
  it("parses only the three exact request shapes", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "open_ephemeral_side_chat",
        parentSessionId: "parent-session",
        parentProviderSessionId: "provider-thread",
        requestId: "request-open",
      }),
    ).toEqual({
      type: "open_ephemeral_side_chat",
      parentSessionId: "parent-session",
      parentProviderSessionId: "provider-thread",
      requestId: "request-open",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "list_ephemeral_side_chats",
        requestId: "request-list",
      }),
    ).toEqual({
      type: "list_ephemeral_side_chats",
      requestId: "request-list",
    });
    expect(
      parseLocalFeatureClientMessage({
        type: "close_ephemeral_side_chat",
        childSessionId: "child-session",
        requestId: "request-close",
      }),
    ).toEqual({
      type: "close_ephemeral_side_chat",
      childSessionId: "child-session",
      requestId: "request-close",
    });
  });

  it("rejects empty, oversized, and extended payloads", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "open_ephemeral_side_chat",
        parentSessionId: "",
        requestId: "request-open",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "open_ephemeral_side_chat",
        parentSessionId: "parent-session",
        parentProviderSessionId: "",
        requestId: "request-open",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "list_ephemeral_side_chats",
        requestId: "x".repeat(129),
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "close_ephemeral_side_chat",
        childSessionId: "child-session",
        requestId: "request-close",
        unexpected: true,
      }),
    ).toBeNull();
  });

  it("registers both additive response types", () => {
    expect(
      isLocalFeatureServerMessageType("ephemeral_side_chat_opened"),
    ).toBe(true);
    expect(
      isLocalFeatureServerMessageType("ephemeral_side_chat_registry"),
    ).toBe(true);
  });
});
