import { describe, expect, it } from "vitest";
import {
  createBackgroundNotificationPolicy,
  createBackgroundNotificationProjectionState,
  projectBackgroundNotification,
} from "./background-notification-projector.js";

const context = {
  deliveryId: "delivery-1",
  sessionId: "session-1",
  provider: "codex" as const,
  label: "同步修复 (ccpocket)",
  now: Date.parse("2026-07-24T01:00:00.000Z"),
};

describe("background notification projector", () => {
  it("projects only enabled lightweight events and never includes tool input", () => {
    const policy = createBackgroundNotificationPolicy({
      locale: "zh-CN",
      enabledEventTypes: ["approval_required"],
    });
    const state = createBackgroundNotificationProjectionState();
    const message = projectBackgroundNotification(
      {
        type: "permission_request",
        toolUseId: "tool-1",
        toolName: "Bash",
        input: { command: "cat /private/secret" },
      },
      context,
      policy,
      state,
    );

    expect(message).toMatchObject({
      type: "background_notification_v1",
      eventType: "approval_required",
      sessionId: "session-1",
      provider: "codex",
      title: "需要批准 - 同步修复 (ccpocket)",
      body: "请批准执行 Bash",
    });
    expect(JSON.stringify(message)).not.toContain("cat /private/secret");
    expect(
      projectBackgroundNotification(
        {
          type: "permission_request",
          toolUseId: "tool-1",
          toolName: "Bash",
          input: {},
        },
        context,
        policy,
        state,
      ),
    ).toBeNull();
  });

  it("keeps progress opt-in, deduplicated and rate limited", () => {
    const policy = createBackgroundNotificationPolicy({
      locale: "en",
      enabledEventTypes: ["session_progress"],
    });
    const state = createBackgroundNotificationProjectionState();
    const assistant = (id: string, name: string) =>
      ({
        type: "assistant",
        message: {
          id: `message-${id}`,
          role: "assistant",
          model: "gpt-5.6",
          content: [{ type: "tool_use", id, name, input: { large: "value" } }],
        },
      }) as const;

    expect(
      projectBackgroundNotification(
        assistant("tool-1", "Read"),
        context,
        policy,
        state,
      ),
    ).toMatchObject({
      eventType: "session_progress",
      body: "Using Read",
    });
    expect(
      projectBackgroundNotification(
        assistant("tool-1", "Read"),
        { ...context, now: context.now + 50_000 },
        policy,
        state,
      ),
    ).toBeNull();
    expect(
      projectBackgroundNotification(
        assistant("tool-2", "Bash"),
        { ...context, now: context.now + 30_000 },
        policy,
        state,
      ),
    ).toBeNull();
    expect(
      projectBackgroundNotification(
        assistant("tool-2", "Bash"),
        { ...context, now: context.now + 45_000 },
        policy,
        state,
      ),
    ).toMatchObject({ body: "Using Bash" });
  });

  it("removes result content in privacy mode", () => {
    const policy = createBackgroundNotificationPolicy({
      locale: "zh",
      privacyMode: true,
      enabledEventTypes: ["session_completed"],
    });
    const message = projectBackgroundNotification(
      {
        type: "result",
        subtype: "success",
        result: "sensitive result body",
        duration: 3.2,
      },
      context,
      policy,
      createBackgroundNotificationProjectionState(),
    );

    expect(message).toMatchObject({
      title: "任务已完成",
      body: "会话已完成 (3.2s)",
    });
    expect(JSON.stringify(message)).not.toContain("sensitive");
  });

  it("removes tool metadata in privacy mode", () => {
    const policy = createBackgroundNotificationPolicy({
      locale: "zh",
      privacyMode: true,
      enabledEventTypes: ["session_progress"],
    });
    const message = projectBackgroundNotification(
      {
        type: "assistant",
        message: {
          id: "message-private",
          role: "assistant",
          model: "gpt-5.6",
          content: [
            {
              type: "tool_use",
              id: "private-tool-id",
              name: "SensitiveToolName",
              input: { ignoredValue: "not-forwarded" },
            },
          ],
        },
      },
      context,
      policy,
      createBackgroundNotificationProjectionState(),
    );

    expect(message?.data).toEqual({
      deliveryId: "delivery-1",
      sessionId: "session-1",
      provider: "codex",
    });
    expect(JSON.stringify(message)).not.toContain("SensitiveToolName");
    expect(JSON.stringify(message)).not.toContain("private-tool-id");
    expect(JSON.stringify(message)).not.toContain("not-forwarded");
  });

  it("keeps only the opaque approval identity in privacy mode", () => {
    const policy = createBackgroundNotificationPolicy({
      locale: "zh",
      privacyMode: true,
      enabledEventTypes: ["approval_required"],
    });
    const message = projectBackgroundNotification(
      {
        type: "permission_request",
        toolUseId: "approval-opaque-id",
        toolName: "SensitiveToolName",
        input: { command: "private command" },
      },
      context,
      policy,
      createBackgroundNotificationProjectionState(),
    );

    expect(message?.data).toEqual({
      deliveryId: "delivery-1",
      sessionId: "session-1",
      provider: "codex",
      permissionId: "approval-opaque-id",
    });
    expect(JSON.stringify(message)).not.toContain("SensitiveToolName");
    expect(JSON.stringify(message)).not.toContain("private command");
  });

  it("releases per-session deduplication state when a turn ends", () => {
    const policy = createBackgroundNotificationPolicy({
      enabledEventTypes: ["approval_required", "session_progress"],
    });
    const state = createBackgroundNotificationProjectionState();
    state.progressBySession.set("session-1", {
      lastSentAt: context.now,
      lastToolKey: "tool-1:Read",
    });
    state.permissionToolUsesBySession.set(
      "session-1",
      new Set(["permission-1"]),
    );

    expect(
      projectBackgroundNotification(
        { type: "result", subtype: "stopped" },
        context,
        policy,
        state,
      ),
    ).toBeNull();
    expect(state.progressBySession.has("session-1")).toBe(false);
    expect(state.permissionToolUsesBySession.has("session-1")).toBe(false);
  });
});
