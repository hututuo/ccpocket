import { describe, expect, it } from "vitest";
import {
  BACKGROUND_NOTIFICATION_MAX_CODEX_REQUEST_IDS,
  BACKGROUND_NOTIFICATION_MAX_PERMISSION_IDS_PER_SESSION,
  BACKGROUND_NOTIFICATION_MAX_TRACKED_SESSIONS,
  createBackgroundNotificationPolicy,
  createBackgroundNotificationProjectionState,
  projectCodexActionBackgroundNotification,
  projectBackgroundNotification,
} from "./background-notification-projector.js";

const context = {
  deliveryId: "delivery-1",
  sessionId: "session-1",
  provider: "codex" as const,
  bridgeInstanceId: "bridge-1",
  codexSourceId: "codex-source-1",
  label: "同步修复 (ccpocket)",
  now: Date.parse("2026-07-24T01:00:00.000Z"),
};

describe("background notification projector", () => {
  it("projects the exact Codex Action Broker fence without request input", () => {
    const state = createBackgroundNotificationProjectionState();
    const request = {
      opaqueRequestId: "opaque-cab-1",
      codexSourceId: "codex-source-1",
      threadId: "thread-1",
      turnId: "turn-1",
      kind: "command_approval" as const,
      state: "pending" as const,
      observedAt: "2026-07-24T01:00:00.000Z",
      expiresAt: "2026-07-24T01:10:00.000Z",
      updatedAt: "2026-07-24T01:00:01.000Z",
      authorityGeneration: "cab:1:7",
      live: true,
      toolName: "Bash",
      input: { command: "cat /private/secret" },
      allowedActions: ["approve", "reject"] as ("approve" | "reject")[],
    };
    const message = projectCodexActionBackgroundNotification(
      request,
      { ...context, sessionId: "thread-1", providerSessionId: "thread-1" },
      createBackgroundNotificationPolicy({
        locale: "zh",
        enabledEventTypes: ["approval_required"],
      }),
      state,
    );

    expect(message).toMatchObject({
      eventType: "approval_required",
      sessionId: "thread-1",
      provider: "codex",
      data: {
        actionPayloadVersion: "2",
        opaqueRequestId: "opaque-cab-1",
        codexSourceId: "codex-source-1",
        threadId: "thread-1",
        turnId: "turn-1",
        authorityGeneration: "cab:1:7",
        allowedActions: "approve,reject",
      },
    });
    expect(message?.data.permissionId).toBeUndefined();
    expect(JSON.stringify(message)).not.toContain("cat /private/secret");
    expect(
      projectCodexActionBackgroundNotification(
        request,
        context,
        createBackgroundNotificationPolicy(),
        state,
      ),
    ).toBeNull();
  });

  it("keeps Codex broker notification bodies private and releases terminal dedup", () => {
    const state = createBackgroundNotificationProjectionState();
    const request = {
      opaqueRequestId: "opaque-private",
      codexSourceId: "codex-source-1",
      threadId: "thread-private",
      turnId: "turn-private",
      kind: "file_approval" as const,
      state: "pending" as const,
      observedAt: "2026-07-24T01:00:00.000Z",
      expiresAt: "2026-07-24T01:10:00.000Z",
      updatedAt: "2026-07-24T01:00:01.000Z",
      authorityGeneration: "cab:2:1",
      live: true,
      toolName: "SecretFileWriter",
      input: { path: "/private/secret" },
      allowedActions: ["approve", "reject"] as ("approve" | "reject")[],
    };
    const policy = createBackgroundNotificationPolicy({
      locale: "zh",
      privacyMode: true,
      enabledEventTypes: ["approval_required"],
    });
    const message = projectCodexActionBackgroundNotification(
      request,
      context,
      policy,
      state,
    );
    expect(JSON.stringify(message)).not.toContain("SecretFileWriter");
    expect(JSON.stringify(message)).not.toContain("/private/secret");

    expect(
      projectCodexActionBackgroundNotification(
        { ...request, state: "resolved" as const, live: false },
        context,
        policy,
        state,
      ),
    ).toBeNull();
    expect(
      projectCodexActionBackgroundNotification(request, context, policy, state),
    ).not.toBeNull();
  });

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
      bridgeInstanceId: "bridge-1",
      codexSourceId: "codex-source-1",
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
      bridgeInstanceId: "bridge-1",
      codexSourceId: "codex-source-1",
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

  it("bounds all best-effort notification dedupe caches when terminal events are missed", () => {
    const state = createBackgroundNotificationProjectionState();
    const approvalPolicy = createBackgroundNotificationPolicy({
      enabledEventTypes: ["approval_required"],
    });
    for (
      let index = 0;
      index <= BACKGROUND_NOTIFICATION_MAX_CODEX_REQUEST_IDS;
      index += 1
    ) {
      expect(
        projectCodexActionBackgroundNotification(
          {
            opaqueRequestId: `opaque-${index}`,
            codexSourceId: "codex-source-1",
            threadId: `thread-${index}`,
            turnId: `turn-${index}`,
            kind: "command_approval",
            state: "pending",
            observedAt: "2026-07-24T01:00:00.000Z",
            expiresAt: "2026-07-24T01:10:00.000Z",
            updatedAt: "2026-07-24T01:00:01.000Z",
            authorityGeneration: "cab:bounded:1",
            live: true,
            toolName: "Bash",
            input: { command: "pwd" },
            allowedActions: ["approve", "reject"],
          },
          { ...context, sessionId: `thread-${index}` },
          approvalPolicy,
          state,
        ),
      ).not.toBeNull();
    }
    expect(state.codexActionRequestIds.size).toBe(
      BACKGROUND_NOTIFICATION_MAX_CODEX_REQUEST_IDS,
    );

    for (
      let index = 0;
      index <= BACKGROUND_NOTIFICATION_MAX_TRACKED_SESSIONS;
      index += 1
    ) {
      projectBackgroundNotification(
        {
          type: "permission_request",
          toolUseId: `permission-${index}`,
          toolName: "Bash",
          input: {},
        },
        { ...context, sessionId: `permission-session-${index}` },
        approvalPolicy,
        state,
      );
    }
    expect(state.permissionToolUsesBySession.size).toBe(
      BACKGROUND_NOTIFICATION_MAX_TRACKED_SESSIONS,
    );

    const progressPolicy = createBackgroundNotificationPolicy({
      enabledEventTypes: ["session_progress"],
    });
    for (
      let index = 0;
      index <= BACKGROUND_NOTIFICATION_MAX_TRACKED_SESSIONS;
      index += 1
    ) {
      projectBackgroundNotification(
        {
          type: "assistant",
          message: {
            id: `progress-message-${index}`,
            role: "assistant",
            model: "gpt-5.6",
            content: [
              {
                type: "tool_use",
                id: `progress-tool-${index}`,
                name: "Read",
                input: {},
              },
            ],
          },
        },
        {
          ...context,
          sessionId: `progress-session-${index}`,
          now: context.now + index * 50_000,
        },
        progressPolicy,
        state,
      );
    }
    expect(state.progressBySession.size).toBe(
      BACKGROUND_NOTIFICATION_MAX_TRACKED_SESSIONS,
    );

    const oneSession = "one-long-running-session";
    for (
      let index = 0;
      index <= BACKGROUND_NOTIFICATION_MAX_PERMISSION_IDS_PER_SESSION;
      index += 1
    ) {
      projectBackgroundNotification(
        {
          type: "permission_request",
          toolUseId: `long-permission-${index}`,
          toolName: "Bash",
          input: {},
        },
        { ...context, sessionId: oneSession },
        approvalPolicy,
        state,
      );
    }
    expect(state.permissionToolUsesBySession.get(oneSession)?.size).toBe(
      BACKGROUND_NOTIFICATION_MAX_PERMISSION_IDS_PER_SESSION,
    );
  });
});
