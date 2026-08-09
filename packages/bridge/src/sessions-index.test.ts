import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  statSync,
  utimesSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  pathToSlug,
  isWorktreeSlug,
  normalizeWorktreePath,
  scanJsonlDir,
  getAllRecentSessions,
  getCodexSessionIndexMetadata,
  loadCodexSessionNames,
  getCodexSessionHistory,
  resolveCodexSessionJsonlPath,
  readClaudeJsonlHistoryWindow,
  readClaudeSessionHistoryWindow,
  extractMessageImages,
  codexThreadToSessionHistory,
  supplementCodexThreadWithDesktopTools,
  type SessionHistoryMessage,
} from "./sessions-index.js";
import { buildAutoRenamePrompt } from "./auto-rename.js";

describe("pathToSlug", () => {
  it("converts a path to Claude directory slug", () => {
    expect(pathToSlug("/Users/x/Workspace/myproject")).toBe(
      "-Users-x-Workspace-myproject",
    );
  });

  it("handles nested paths", () => {
    expect(pathToSlug("/a/b/c/d")).toBe("-a-b-c-d");
  });

  it("handles paths with hyphens", () => {
    expect(pathToSlug("/Users/x/my-project")).toBe("-Users-x-my-project");
  });

  it("converts underscores to hyphens", () => {
    expect(pathToSlug("/Users/x/flutter_claude_sandbox")).toBe(
      "-Users-x-flutter-claude-sandbox",
    );
  });

  it("matches Claude project slugs for Windows drive paths", () => {
    expect(pathToSlug("C:\\Users\\29642")).toBe("C--Users-29642");
  });
});

describe("codexThreadToSessionHistory", () => {
  it("retains provider item and turn identity for every projected item", () => {
    const history = codexThreadToSessionHistory({
      turns: [
        {
          id: "turn-provider-1",
          items: [
            {
              type: "userMessage",
              id: "provider-user-1",
              clientMessageId: "client-user-1",
              content: [{ type: "text", text: "hello" }],
            },
            {
              type: "agentMessage",
              id: "provider-assistant-1",
              text: "hi",
            },
            {
              type: "commandExecution",
              id: "provider-tool-1",
              command: "pwd",
              status: "completed",
              aggregatedOutput: "/tmp",
            },
          ],
        },
      ],
    });

    expect(history).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          role: "user",
          rawItemId: "provider-user-1",
          clientMessageId: "client-user-1",
          historyTurnId: "turn-provider-1",
        }),
        expect.objectContaining({
          role: "assistant",
          uuid: "provider-assistant-1",
          historyTurnId: "turn-provider-1",
        }),
        expect.objectContaining({
          role: "tool_result",
          toolUseId: "provider-tool-1",
          historyTurnId: "turn-provider-1",
        }),
      ]),
    );
  });

  it("retains repeated tool ids separately across provider turns", () => {
    const history = codexThreadToSessionHistory({
      turns: ["provider-turn-one", "provider-turn-two"].map((turnId) => ({
        id: turnId,
        items: [
          {
            type: "userMessage",
            id: `user-${turnId}`,
            content: [{ type: "text", text: `request ${turnId}` }],
          },
          {
            type: "commandExecution",
            id: "reused-tool",
            command: "pwd",
            status: "completed",
            aggregatedOutput: `result ${turnId}`,
          },
        ],
      })),
    });

    const results = history.filter(
      (message) =>
        message.role === "tool_result" && message.toolUseId === "reused-tool",
    );
    expect(results).toHaveLength(2);
    expect(results.map((message) => message.historyTurnId)).toEqual([
      "provider-turn-one",
      "provider-turn-two",
    ]);
    expect(results.map((message) => message.content)).toEqual([
      "status: completed\nresult provider-turn-one",
      "status: completed\nresult provider-turn-two",
    ]);
  });

  it("converts official thread turns into display history", () => {
    const history = codexThreadToSessionHistory({
      turns: [
        {
          startedAt: 1700000000,
          completedAt: 1700000001,
          items: [
            {
              type: "userMessage",
              id: "u1",
              content: [{ type: "text", text: "hello" }],
            },
            {
              type: "agentMessage",
              id: "a1",
              text: "hi",
              phase: null,
              memoryCitation: null,
            },
            {
              type: "commandExecution",
              id: "cmd1",
              command: "git status",
              cwd: "/tmp/repo",
              pluginId: "openai.browser",
              scriptPath: "/tmp/openai.browser/run.sh",
              status: "completed",
              aggregatedOutput: "clean",
              exitCode: 0,
            },
          ],
        },
      ],
    });

    expect(history).toMatchObject([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        rawItemId: "u1",
        content: [{ type: "text", text: "hello" }],
      },
      {
        role: "assistant",
        uuid: "a1",
        content: [{ type: "text", text: "hi" }],
      },
      {
        role: "assistant",
        uuid: "cmd1",
        content: [
          {
            type: "tool_use",
            id: "cmd1",
            name: "Bash",
            input: {
              command: "git status",
              cwd: "/tmp/repo",
              pluginId: "openai.browser",
              scriptPath: "/tmp/openai.browser/run.sh",
            },
          },
        ],
      },
      {
        role: "tool_result",
        toolUseId: "cmd1",
        toolName: "Bash",
        content: "status: completed\nexitCode: 0\nclean",
      },
    ]);
  });

  it("uses each local provider event time instead of one turn timestamp", () => {
    const history = codexThreadToSessionHistory(
      {
        turns: [
          {
            id: "turn-timestamps",
            startedAt: 1_700_000_000,
            completedAt: 1_700_000_100,
            items: [
              {
                type: "userMessage",
                id: "user-time",
                content: [{ type: "text", text: "inspect this" }],
              },
              {
                type: "reasoning",
                id: "reasoning-time",
                summary: ["checking"],
              },
              {
                type: "dynamicToolCall",
                id: "tool-time",
                tool: "Read",
                arguments: {
                  path: "/tmp/example.txt",
                  privatePayload: "stays behind the disclosure",
                },
                status: "completed",
                contentItems: [{ type: "inputText", text: "contents" }],
              },
              {
                type: "agentMessage",
                id: "assistant-time",
                text: "finished",
              },
            ],
          },
        ],
      },
      {
        desktopToolTimeline: {
          callIds: new Set(["tool-time"]),
          events: [],
          itemTimestamps: new Map([
            [
              "user-time",
              {
                startedAt: "2026-07-29T05:20:00.000Z",
                completedAt: "2026-07-29T05:20:00.000Z",
              },
            ],
            [
              "reasoning-time",
              {
                startedAt: "2026-07-29T05:20:01.000Z",
                completedAt: "2026-07-29T05:20:01.000Z",
              },
            ],
            [
              "tool-time",
              {
                startedAt: "2026-07-29T05:20:02.000Z",
                completedAt: "2026-07-29T05:20:04.000Z",
              },
            ],
            [
              "assistant-time",
              {
                startedAt: "2026-07-29T05:20:05.000Z",
                completedAt: "2026-07-29T05:20:05.000Z",
              },
            ],
          ]),
        },
      },
    );

    expect(
      history.map((message) => ({
        timestamp: message.timestamp,
        authoritative: message.timestampIsAuthoritative,
      })),
    ).toEqual([
      {
        timestamp: "2026-07-29T05:20:00.000Z",
        authoritative: true,
      },
      {
        timestamp: "2026-07-29T05:20:01.000Z",
        authoritative: true,
      },
      {
        timestamp: "2026-07-29T05:20:02.000Z",
        authoritative: true,
      },
      {
        timestamp: "2026-07-29T05:20:04.000Z",
        authoritative: true,
      },
      {
        timestamp: "2026-07-29T05:20:05.000Z",
        authoritative: true,
      },
    ]);
    expect(history[2]).toMatchObject({
      role: "assistant",
      content: [
        {
          type: "tool_use",
          name: "Read",
          input: {
            path: "/tmp/example.txt",
            arguments: { path: "/tmp/example.txt" },
            status: "completed",
          },
        },
      ],
    });
    expect(
      (history[2] as { content: Array<{ input: Record<string, unknown> }> })
        .content[0]?.input.privatePayload,
    ).toBeUndefined();
  });

  it("keeps exact event time when a mirror consumes a supplemented thread", () => {
    const timeline = {
      callIds: new Set<string>(),
      events: [],
      itemTimestamps: new Map([
        [
          "assistant-mirror-time",
          {
            startedAt: "2026-07-29T05:21:07.000Z",
            completedAt: "2026-07-29T05:21:07.000Z",
          },
        ],
      ]),
    };
    const supplemented = supplementCodexThreadWithDesktopTools(
      {
        turns: [
          {
            id: "turn-mirror-time",
            completedAt: 1_700_000_100,
            items: [
              {
                type: "agentMessage",
                id: "assistant-mirror-time",
                text: "mirrored",
              },
            ],
          },
        ],
      },
      timeline,
    );

    expect(codexThreadToSessionHistory(supplemented)).toMatchObject([
      {
        role: "assistant",
        timestamp: "2026-07-29T05:21:07.000Z",
        timestampIsAuthoritative: true,
      },
    ]);
  });

  it("preserves distinct official agentMessage ids with duplicate text", () => {
    const history = codexThreadToSessionHistory({
      turns: [
        {
          items: [
            { type: "agentMessage", id: "a1", text: "same reply" },
            { type: "agentMessage", id: "a2", text: "same reply" },
          ],
        },
      ],
    });

    expect(history).toEqual([
      {
        role: "assistant",
        uuid: "a1",
        content: [{ type: "text", text: "same reply" }],
      },
      {
        role: "assistant",
        uuid: "a2",
        content: [{ type: "text", text: "same reply" }],
      },
    ]);
  });

  it("preserves official Read, List, Search, and command completion semantics", () => {
    const history = codexThreadToSessionHistory({
      turns: [
        {
          items: [
            {
              type: "commandExecution",
              id: "read-1",
              command: "sed -n '1,40p' /tmp/repo/README.md",
              cwd: "/tmp/repo",
              status: "completed",
              commandActions: [
                {
                  type: "read",
                  command: "sed -n '1,40p' /tmp/repo/README.md",
                  name: "sed",
                  path: "/tmp/repo/README.md",
                },
              ],
              aggregatedOutput: "hello",
              exitCode: 0,
            },
            {
              type: "commandExecution",
              id: "list-1",
              command: "ls -la",
              status: "completed",
              commandActions: [
                { type: "listFiles", command: "ls -la", path: "." },
              ],
              aggregatedOutput: "README.md",
              exitCode: 0,
            },
            {
              type: "commandExecution",
              id: "search-1",
              command: "rg TODO lib",
              status: "completed",
              commandActions: [
                {
                  type: "search",
                  command: "rg TODO lib",
                  query: "TODO",
                  path: "lib",
                },
              ],
              aggregatedOutput: "lib/a.ts:TODO",
              exitCode: 0,
            },
          ],
        },
      ],
    });

    const toolUses = history
      .filter((message) => message.role === "assistant")
      .map((message) => message.content[0]);
    expect(toolUses).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: "read-1", name: "Read" }),
        expect.objectContaining({ id: "list-1", name: "ListFiles" }),
        expect.objectContaining({ id: "search-1", name: "Search" }),
      ]),
    );
    expect(history).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          role: "tool_result",
          toolUseId: "read-1",
          toolName: "Read",
        }),
        expect.objectContaining({
          role: "tool_result",
          toolUseId: "list-1",
          toolName: "ListFiles",
        }),
        expect.objectContaining({
          role: "tool_result",
          toolUseId: "search-1",
          toolName: "Search",
        }),
      ]),
    );
  });

  it("preserves official tool item ids and user image refs", () => {
    const history = codexThreadToSessionHistory({
      turns: [
        {
          items: [
            {
              type: "userMessage",
              id: "u1",
              content: [
                { type: "text", text: "inspect this" },
                { type: "localImage", path: "/tmp/local.png" },
                {
                  type: "image",
                  imageUrl: "data:image/png;base64,aW1hZ2U=",
                },
              ],
            },
            {
              type: "imageGeneration",
              id: "img1",
              status: "completed",
            },
          ],
        },
      ],
    });

    expect(history[0]).toMatchObject({
      role: "user",
      uuid: "codex:user-turn:1",
      rawItemId: "u1",
      content: [{ type: "text", text: "inspect this" }],
      imageCount: 2,
      imagePaths: ["/tmp/local.png"],
      imageBase64: [{ data: "aW1hZ2U=", mimeType: "image/png" }],
    });
    expect(history[1]).toMatchObject({
      role: "assistant",
      uuid: "img1",
      content: [
        {
          type: "tool_use",
          id: "img1",
          name: "ImageGeneration",
        },
      ],
    });
  });

  it("converts the full official Codex activity item family", () => {
    const history = codexThreadToSessionHistory({
      turns: [
        {
          id: "turn-activity",
          items: [
            {
              type: "collabAgentToolCall",
              id: "agent-wait",
              tool: "wait",
              status: "completed",
              receiverThreadIds: ["agent-1"],
              agentsStates: { "agent-1": "completed" },
            },
            {
              type: "subAgentActivity",
              id: "agent-start",
              kind: "started",
              agentThreadId: "agent-2",
              agentPath: "/root/reviewer",
            },
            {
              type: "subAgentActivity",
              id: "agent-interact",
              kind: "interacted",
              agentThreadId: "agent-2",
              agentPath: "/root/reviewer",
            },
            { type: "contextCompaction", id: "compact-1" },
            { type: "imageView", id: "image-1", path: "/tmp/a.png" },
            { type: "sleep", id: "sleep-1", durationMs: 250 },
          ],
        },
      ],
    });

    const toolNames = history.flatMap((message) =>
      message.role === "assistant" && Array.isArray(message.content)
        ? message.content
            .filter((item) => item.type === "tool_use")
            .map((item) => item.name)
        : [],
    );
    expect(toolNames).toEqual([
      "WaitForAgents",
      "SpawnAgent",
      "SubAgentInteraction",
      "ContextCompaction",
      "ViewImage",
      "Wait",
    ]);
    expect(history).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          role: "tool_result",
          toolUseId: "agent-start",
          toolName: "SpawnAgent",
          content: "Started sub-agent /root/reviewer",
        }),
        expect.objectContaining({
          role: "tool_result",
          toolUseId: "compact-1",
          toolName: "ContextCompaction",
        }),
        expect.objectContaining({
          role: "tool_result",
          toolUseId: "image-1",
          toolName: "ViewImage",
          imagePaths: ["/tmp/a.png"],
        }),
      ]),
    );
  });

  it("merges omitted Desktop tools into the correct visible-message interval", () => {
    const history = codexThreadToSessionHistory(
      {
        turns: [
          {
            id: "turn-1",
            items: [
              {
                type: "userMessage",
                id: "user-1",
                content: [{ type: "text", text: "inspect this" }],
              },
              { type: "reasoning", id: "r1", summary: ["checking"] },
              {
                type: "agentMessage",
                id: "a1",
                text: "I found the adapter.",
              },
              { type: "reasoning", id: "r2", summary: ["reviewing"] },
              {
                type: "subAgentActivity",
                id: "call-agent",
                kind: "started",
                agentThreadId: "agent-1",
                agentPath: "/root/reviewer",
              },
              {
                type: "agentMessage",
                id: "a2",
                text: "The review is running.",
              },
            ],
          },
        ],
      },
      {
        desktopToolTimeline: {
          callIds: new Set(["call-skill", "call-agent"]),
          events: [
            {
              turnId: "turn-1",
              callId: "call-skill",
              afterVisibleMessage: 1,
              sequence: 1,
              type: "tool_use",
              name: "ReadSkill",
              input: { file_path: "/tmp/pdf/SKILL.md", skill: "pdf" },
            },
            {
              turnId: "turn-1",
              callId: "call-skill",
              afterVisibleMessage: 1,
              sequence: 2,
              type: "tool_result",
              name: "ReadSkill",
              content: "skill body",
            },
            {
              turnId: "turn-1",
              callId: "call-agent",
              afterVisibleMessage: 2,
              sequence: 3,
              type: "tool_use",
              name: "SpawnAgent",
              input: { task_name: "review" },
            },
            {
              turnId: "turn-1",
              callId: "call-agent",
              afterVisibleMessage: 2,
              sequence: 4,
              type: "tool_result",
              name: "SpawnAgent",
              content: "agent started",
            },
          ],
        },
      },
    );

    const labels = history.map((message) => {
      if (message.role === "user") return "user";
      if (message.role === "tool_result") return `result:${message.toolName}`;
      const item = Array.isArray(message.content) ? message.content[0] : null;
      if (item?.type === "tool_use") return `tool:${item.name}`;
      if (item?.type === "thinking") return `thinking:${item.thinking}`;
      return `text:${item?.text}`;
    });
    expect(labels).toEqual([
      "user",
      "thinking:checking",
      "tool:ReadSkill",
      "result:ReadSkill",
      "text:I found the adapter.",
      "thinking:reviewing",
      "tool:SpawnAgent",
      "result:SpawnAgent",
      "text:The review is running.",
    ]);
    expect(
      history.filter(
        (message) =>
          message.role === "tool_result" && message.toolUseId === "call-agent",
      ),
    ).toHaveLength(1);
  });

  it("preserves a supplemented Desktop view_image as a lightweight image path", () => {
    const history = codexThreadToSessionHistory(
      {
        turns: [
          {
            id: "turn-image",
            items: [
              {
                type: "userMessage",
                content: [{ type: "text", text: "show it" }],
              },
            ],
          },
        ],
      },
      {
        desktopToolTimeline: {
          callIds: new Set(["call-image"]),
          events: [
            {
              turnId: "turn-image",
              callId: "call-image",
              afterVisibleMessage: 1,
              sequence: 1,
              type: "tool_use",
              name: "ViewImage",
              input: { path: "/tmp/referenced screenshot.png" },
              imagePaths: ["/tmp/referenced screenshot.png"],
            },
            {
              turnId: "turn-image",
              callId: "call-image",
              afterVisibleMessage: 1,
              sequence: 2,
              type: "tool_result",
              name: "ViewImage",
              content: "Returned 1 image",
              imagePaths: ["/tmp/referenced screenshot.png"],
            },
          ],
        },
      },
    );

    expect(history.at(-1)).toMatchObject({
      role: "tool_result",
      toolUseId: "call-image",
      toolName: "ViewImage",
      imagePaths: ["/tmp/referenced screenshot.png"],
    });
  });
});

describe("isWorktreeSlug", () => {
  const projectSlug = "-Users-x-Workspace-vibetunnel";

  it("matches worktree directory slugs", () => {
    expect(
      isWorktreeSlug(
        "-Users-x-Workspace-vibetunnel-worktrees-branch-abc",
        projectSlug,
      ),
    ).toBe(true);
  });

  it("does not match the project directory itself", () => {
    expect(isWorktreeSlug(projectSlug, projectSlug)).toBe(false);
  });

  it("does not match unrelated directories", () => {
    expect(
      isWorktreeSlug("-Users-x-Workspace-other-project", projectSlug),
    ).toBe(false);
  });

  it("does not match partial prefix collisions", () => {
    // "-vibetunnel-extra" is not the same as "-vibetunnel-worktrees-"
    expect(
      isWorktreeSlug("-Users-x-Workspace-vibetunnel-extra", projectSlug),
    ).toBe(false);
  });
});

describe("normalizeWorktreePath", () => {
  it("normalizes a worktree path to the main project path", () => {
    expect(
      normalizeWorktreePath("/Users/x/Workspace/ccpocket-worktrees/notice"),
    ).toBe("/Users/x/Workspace/ccpocket");
  });

  it("handles branch names with hyphens", () => {
    expect(
      normalizeWorktreePath(
        "/Users/x/Workspace/gtri-worktrees/test-session-verify",
      ),
    ).toBe("/Users/x/Workspace/gtri");
  });

  it("returns the original path when not a worktree path", () => {
    expect(normalizeWorktreePath("/Users/x/Workspace/ccpocket")).toBe(
      "/Users/x/Workspace/ccpocket",
    );
  });

  it("returns the original path for empty string", () => {
    expect(normalizeWorktreePath("")).toBe("");
  });

  it("does not match paths ending with -worktrees (no branch segment)", () => {
    expect(normalizeWorktreePath("/Users/x/Workspace/ccpocket-worktrees")).toBe(
      "/Users/x/Workspace/ccpocket-worktrees",
    );
  });

  it("does not match nested worktree-like paths", () => {
    // Only the last -worktrees/branch segment should match
    expect(
      normalizeWorktreePath("/Users/x/Workspace/foo-worktrees/bar/baz"),
    ).toBe("/Users/x/Workspace/foo-worktrees/bar/baz");
  });
});

describe("scanJsonlDir", () => {
  const testDir = join(tmpdir(), "ccpocket-test-scanJsonl-" + Date.now());

  beforeEach(() => {
    mkdirSync(testDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(testDir, { recursive: true, force: true });
  });

  it("returns empty for nonexistent directory", async () => {
    const result = await scanJsonlDir("/nonexistent/path");
    expect(result).toEqual([]);
  });

  it("returns empty for directory with no JSONL files", async () => {
    writeFileSync(join(testDir, "readme.txt"), "hello");
    const result = await scanJsonlDir(testDir);
    expect(result).toEqual([]);
  });

  it("parses a JSONL session file correctly", async () => {
    const lines = [
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "hello world" }],
        },
        cwd: "/my/project",
        gitBranch: "main",
        sessionId: "test-session-1",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
      JSON.stringify({
        type: "assistant",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "Hi there!" }],
        },
        sessionId: "test-session-1",
        timestamp: "2026-01-01T00:00:01.000Z",
      }),
    ];
    writeFileSync(join(testDir, "test-session-1.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);

    const entry = result[0];
    expect(entry.sessionId).toBe("test-session-1");
    expect(entry.provider).toBe("claude");
    expect(entry.firstPrompt).toBe("hello world");
    expect(entry.created).toBe("2026-01-01T00:00:00.000Z");
    expect(entry.modified).toBe("2026-01-01T00:00:01.000Z");
    expect(entry.gitBranch).toBe("main");
    expect(entry.projectPath).toBe("/my/project");
    expect(entry.isSidechain).toBe(false);
  });

  it("treats the last Claude custom-title entry as authoritative", async () => {
    const lines = [
      JSON.stringify({
        type: "custom-title",
        customTitle: "Old title",
        sessionId: "test-session-title",
      }),
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "hello title" }],
        },
        cwd: "/my/project",
        gitBranch: "main",
        sessionId: "test-session-title",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
      JSON.stringify({
        type: "custom-title",
        customTitle: "",
        sessionId: "test-session-title",
      }),
    ];
    writeFileSync(join(testDir, "test-session-title.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);
    expect(result[0].firstPrompt).toBe("hello title");
    expect(result[0].name).toBeUndefined();
  });

  it("excludes Claude auto-rename helper sessions", async () => {
    const lines = [
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [
            {
              type: "text",
              text: buildAutoRenamePrompt({ userText: "real task" }),
            },
          ],
        },
        cwd: "/my/project",
        gitBranch: "main",
        sessionId: "auto-rename-helper",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
      JSON.stringify({
        type: "assistant",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "Real task name" }],
        },
        sessionId: "auto-rename-helper",
        timestamp: "2026-01-01T00:00:01.000Z",
      }),
    ];
    writeFileSync(join(testDir, "auto-rename-helper.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toEqual([]);
  });

  it("extracts summary from summary entries", async () => {
    const lines = [
      JSON.stringify({
        type: "summary",
        summary: "This is a session summary",
      }),
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "test prompt" }],
        },
        cwd: "/proj",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    ];
    writeFileSync(
      join(testDir, "session-with-summary.jsonl"),
      lines.join("\n"),
    );

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);
    // Fast parser skips summary entries for performance (summary comes from sessions-index.json)
    expect(result[0].summary).toBeUndefined();
  });

  it("skips JSONL files with no user/assistant messages", async () => {
    const lines = [
      JSON.stringify({ type: "queue-operation", operation: "dequeue" }),
    ];
    writeFileSync(join(testDir, "empty-session.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toEqual([]);
  });

  it("handles multiple JSONL files", async () => {
    for (const id of ["session-a", "session-b"]) {
      const lines = [
        JSON.stringify({
          type: "user",
          message: {
            role: "user",
            content: [{ type: "text", text: `prompt for ${id}` }],
          },
          cwd: "/proj",
          timestamp: "2026-01-01T00:00:00.000Z",
        }),
      ];
      writeFileSync(join(testDir, `${id}.jsonl`), lines.join("\n"));
    }

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(2);
    const ids = result.map((e) => e.sessionId).sort();
    expect(ids).toEqual(["session-a", "session-b"]);
  });

  it("handles malformed JSON lines gracefully", async () => {
    const lines = [
      "not valid json",
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "valid line" }],
        },
        cwd: "/proj",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    ];
    writeFileSync(join(testDir, "mixed.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);
    expect(result[0].firstPrompt).toBe("valid line");
  });

  it("handles string content in user messages", async () => {
    const lines = [
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: "plain string prompt",
        },
        cwd: "/proj",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    ];
    writeFileSync(join(testDir, "string-content.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);
    expect(result[0].firstPrompt).toBe("plain string prompt");
  });

  it("normalizes worktree cwd to main project path", async () => {
    const lines = [
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "worktree prompt" }],
        },
        cwd: "/Users/x/Workspace/myproject-worktrees/feature-branch",
        gitBranch: "feature-branch",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    ];
    writeFileSync(join(testDir, "wt-session.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);
    expect(result[0].projectPath).toBe("/Users/x/Workspace/myproject");
  });

  it("detects sidechain sessions", async () => {
    const lines = [
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "sidechain test" }],
        },
        cwd: "/proj",
        isSidechain: true,
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    ];
    writeFileSync(join(testDir, "sidechain.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);
    expect(result[0].isSidechain).toBe(true);
  });

  it("extracts projectPath via streaming fallback when first message exceeds HEAD_BYTES", async () => {
    // Simulate the bug: a user message with large base64 image data pushes
    // the cwd field beyond the 16KB HEAD_BYTES window of the fast parser.
    const largePadding = "x".repeat(20000); // > 16KB
    const lines = [
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", data: largePadding },
            },
            { type: "text", text: "analyze this image" },
          ],
        },
        cwd: "/Users/test/big-image-project",
        gitBranch: "feature/images",
        sessionId: "large-msg-session",
        timestamp: "2026-03-01T00:00:00.000Z",
      }),
      JSON.stringify({
        type: "assistant",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "I see the image." }],
        },
        sessionId: "large-msg-session",
        timestamp: "2026-03-01T00:00:01.000Z",
      }),
    ];
    writeFileSync(join(testDir, "large-msg-session.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);

    const entry = result[0];
    expect(entry.sessionId).toBe("large-msg-session");
    // The critical assertion: projectPath must be extracted even when
    // the cwd field is beyond the fast-read HEAD_BYTES window.
    expect(entry.projectPath).toBe("/Users/test/big-image-project");
    expect(entry.gitBranch).toBe("feature/images");
    expect(entry.firstPrompt).toBe("analyze this image");
  });

  it("prefers the original cwd over later cwd values when first line exceeds HEAD_BYTES", async () => {
    const largePadding = "x".repeat(20000); // > 16KB
    const lines = [
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", data: largePadding } },
            { type: "text", text: "restore this session correctly" },
          ],
        },
        cwd: "/Users/test/original-project",
        gitBranch: "main",
        sessionId: "cwd-drift-session",
        timestamp: "2026-03-01T00:00:00.000Z",
      }),
      JSON.stringify({
        type: "assistant",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "Working..." }],
        },
        cwd: "/Users/test/later-project/subdir",
        gitBranch: "feature/drift",
        sessionId: "cwd-drift-session",
        timestamp: "2026-03-01T00:00:01.000Z",
      }),
    ];
    writeFileSync(join(testDir, "cwd-drift-session.jsonl"), lines.join("\n"));

    const result = await scanJsonlDir(testDir);
    expect(result).toHaveLength(1);
    expect(result[0].projectPath).toBe("/Users/test/original-project");
    expect(result[0].gitBranch).toBe("main");
    expect(result[0].firstPrompt).toBe("restore this session correctly");
  });

  it("skips jsonl files when sessionId is excluded", async () => {
    writeFileSync(
      join(testDir, "included.jsonl"),
      JSON.stringify({
        type: "user",
        message: { role: "user", content: "included session" },
        cwd: "/proj",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    );
    writeFileSync(
      join(testDir, "excluded.jsonl"),
      JSON.stringify({
        type: "user",
        message: { role: "user", content: "excluded session" },
        cwd: "/proj",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    );

    const result = await scanJsonlDir(testDir, {
      excludeSessionIds: new Set(["excluded"]),
    });

    expect(result).toHaveLength(1);
    expect(result[0].sessionId).toBe("included");
  });
});

describe("codex sessions integration", () => {
  const oldHome = process.env.HOME;
  const oldUserProfile = process.env.USERPROFILE;
  const oldCodexHome = process.env.CODEX_HOME;
  const tempHome = mkdtempSync(join(tmpdir(), "ccpocket-test-codex-home-"));

  beforeEach(() => {
    process.env.HOME = tempHome;
    process.env.USERPROFILE = tempHome;
    delete process.env.CODEX_HOME;
  });

  afterEach(() => {
    process.env.HOME = oldHome;
    process.env.USERPROFILE = oldUserProfile;
    if (oldCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = oldCodexHome;
    }
    rmSync(tempHome, { recursive: true, force: true });
  });

  it("treats the latest empty Codex thread name as an authoritative clear", async () => {
    const isolatedHome = join(tempHome, "clear-name-codex-home");
    mkdirSync(isolatedHome, { recursive: true });
    process.env.CODEX_HOME = isolatedHome;
    writeFileSync(
      join(isolatedHome, "session_index.jsonl"),
      [
        JSON.stringify({ id: "thread-clear", thread_name: "Before" }),
        JSON.stringify({ id: "thread-other", thread_name: "Keep" }),
        JSON.stringify({ id: "thread-clear", thread_name: "" }),
      ].join("\n"),
    );

    const names = await loadCodexSessionNames();

    expect(names.has("thread-clear")).toBe(false);
    expect(names.get("thread-other")).toBe("Keep");
  });

  it("uses CODEX_HOME instead of mixing an isolated app-server with ~/.codex", async () => {
    const selectedThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68020";
    const defaultThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68021";
    const isolatedHome = join(tempHome, "cockpit-codex-home");
    process.env.CODEX_HOME = isolatedHome;

    const writeRollout = (root: string, threadId: string, prompt: string) => {
      const sessionsDir = join(root, "sessions", "2026", "02", "13");
      mkdirSync(sessionsDir, { recursive: true });
      writeFileSync(
        join(sessionsDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
        [
          JSON.stringify({
            timestamp: "2026-02-13T11:26:43.995Z",
            type: "session_meta",
            payload: { id: threadId, cwd: "/tmp/project-a" },
          }),
          JSON.stringify({
            timestamp: "2026-02-13T11:26:44.100Z",
            type: "event_msg",
            payload: { type: "user_message", message: prompt },
          }),
        ].join("\n"),
      );
    };

    writeRollout(isolatedHome, selectedThreadId, "selected home");
    writeRollout(join(tempHome, ".codex"), defaultThreadId, "wrong home");

    const { sessions } = await getAllRecentSessions({
      provider: "codex",
      limit: 20,
    });

    expect(sessions.map((session) => session.sessionId)).toContain(
      selectedThreadId,
    );
    expect(sessions.map((session) => session.sessionId)).not.toContain(
      defaultThreadId,
    );
  });

  it("shares the rollout path index and isolates it by CODEX_HOME", async () => {
    const firstHome = join(tempHome, "first-codex-home");
    const secondHome = join(tempHome, "second-codex-home");
    const firstIds = [
      "019c56c0-d4d8-7b22-9e3c-200664d68022",
      "019c56c0-d4d8-7b22-9e3c-200664d68023",
    ];
    const writeRollout = (root: string, threadId: string) => {
      const sessionsDir = join(root, "sessions", "2026", "02", "13");
      mkdirSync(sessionsDir, { recursive: true });
      const path = join(
        sessionsDir,
        `rollout-2026-02-13T11-26-43-${threadId}.jsonl`,
      );
      writeFileSync(
        path,
        JSON.stringify({
          timestamp: "2026-02-13T11:26:43.995Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
      );
      return path;
    };

    process.env.CODEX_HOME = firstHome;
    const firstPaths = firstIds.map((threadId) =>
      writeRollout(firstHome, threadId),
    );
    expect(
      await Promise.all(firstIds.map(resolveCodexSessionJsonlPath)),
    ).toEqual(firstPaths);

    const secondId = "019c56c0-d4d8-7b22-9e3c-200664d68024";
    process.env.CODEX_HOME = secondHome;
    const secondPath = writeRollout(secondHome, secondId);
    expect(await resolveCodexSessionJsonlPath(secondId)).toBe(secondPath);
    expect(await resolveCodexSessionJsonlPath(firstIds[0]!)).toBeNull();
  });

  it("caches content-derived paths for legacy rollout filenames", async () => {
    const legacyHome = join(tempHome, "legacy-codex-home");
    const sessionsDir = join(legacyHome, "sessions", "2026", "02", "13");
    const firstId = "019c56c0-d4d8-7b22-9e3c-200664d68025";
    const secondId = "019c56c0-d4d8-7b22-9e3c-200664d68026";
    const firstPath = join(sessionsDir, "legacy-first.jsonl");
    const secondPath = join(sessionsDir, "legacy-second.jsonl");
    const writeLegacyRollout = (path: string, threadId: string) => {
      mkdirSync(sessionsDir, { recursive: true });
      writeFileSync(
        path,
        JSON.stringify({
          timestamp: "2026-02-13T11:26:43.995Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
      );
    };

    process.env.CODEX_HOME = legacyHome;
    writeLegacyRollout(firstPath, firstId);
    writeLegacyRollout(secondPath, secondId);
    expect(
      await Promise.all([
        resolveCodexSessionJsonlPath(firstId),
        resolveCodexSessionJsonlPath(secondId),
      ]),
    ).toEqual([firstPath, secondPath]);

    // A cached content-derived binding follows the same stat-validated
    // semantics as a UUID filename. Rewriting metadata must not trigger
    // another whole-tree fallback scan on the next lookup.
    writeLegacyRollout(firstPath, "019c56c0-d4d8-7b22-9e3c-200664d68027");
    expect(await resolveCodexSessionJsonlPath(firstId)).toBe(firstPath);
  });

  it("detects a newly-created current-day rollout during the recheck cooldown", async () => {
    const liveHome = join(tempHome, "live-codex-home");
    const missingId = "019c56c0-d4d8-7b22-9e3c-200664d68028";
    const newId = "019c56c0-d4d8-7b22-9e3c-200664d68029";
    process.env.CODEX_HOME = liveHome;
    expect(await resolveCodexSessionJsonlPath(missingId)).toBeNull();

    const now = new Date();
    const sessionsDir = join(
      liveHome,
      "sessions",
      String(now.getFullYear()).padStart(4, "0"),
      String(now.getMonth() + 1).padStart(2, "0"),
      String(now.getDate()).padStart(2, "0"),
    );
    mkdirSync(sessionsDir, { recursive: true });
    const newPath = join(sessionsDir, `rollout-now-${newId}.jsonl`);
    writeFileSync(
      newPath,
      JSON.stringify({
        timestamp: now.toISOString(),
        type: "session_meta",
        payload: { id: newId, cwd: "/tmp/project-a" },
      }),
    );

    expect(await resolveCodexSessionJsonlPath(newId)).toBe(newPath);
  });

  it("preserves Claude and Codex sessions that share the same raw id", async () => {
    const sharedId = "019c56c0-d4d8-7b22-9e3c-200664d68030";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    const claudeDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(codexDir, { recursive: true });
    mkdirSync(claudeDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${sharedId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T11:26:43.995Z",
          type: "session_meta",
          payload: { id: sharedId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T11:26:44.100Z",
          type: "event_msg",
          payload: { type: "user_message", message: "codex conversation" },
        }),
      ].join("\n"),
    );
    writeFileSync(
      join(claudeDir, `${sharedId}.jsonl`),
      [
        JSON.stringify({
          type: "user",
          uuid: "claude-user-1",
          cwd: "/tmp/project-a",
          timestamp: "2026-02-13T11:26:45.000Z",
          message: { role: "user", content: "claude conversation" },
        }),
      ].join("\n"),
    );

    const { sessions } = await getAllRecentSessions({ limit: 20 });
    const matching = sessions.filter(
      (session) => session.sessionId === sharedId,
    );

    expect(matching.map((session) => session.provider).sort()).toEqual([
      "claude",
      "codex",
    ]);
  });

  it("applies Desktop project grouping and project-name search to Claude rows", async () => {
    const sharedSessionId = "claude-desktop-shared";
    const unmatchedSessionId = "claude-desktop-unmatched";
    const sharedDir = join(
      tempHome,
      ".claude",
      "projects",
      "-tmp-desktop-shared",
    );
    const unmatchedDir = join(
      tempHome,
      ".claude",
      "projects",
      "-private-tmp-desktop-unmatched",
    );
    const codexHome = join(tempHome, ".codex");
    const globalStatePath = join(codexHome, ".codex-global-state.json");
    mkdirSync(codexHome, { recursive: true });
    mkdirSync(sharedDir, { recursive: true });
    mkdirSync(unmatchedDir, { recursive: true });
    writeFileSync(
      globalStatePath,
      JSON.stringify({
        "local-projects": {
          "project-shared": {
            id: "project-shared",
            name: "Shared Workspace",
            rootPaths: ["/tmp/desktop-shared"],
          },
          "project-other": {
            id: "project-other",
            name: "Other Workspace",
            rootPaths: ["/tmp/desktop-other"],
          },
        },
        "thread-project-assignments": {
          // Desktop assignments are Codex-only even when a Claude-local ID
          // happens to contain the same text.
          [sharedSessionId]: { projectId: "project-other" },
        },
        "projectless-thread-ids": [],
      }),
    );
    writeFileSync(
      join(sharedDir, `${sharedSessionId}.jsonl`),
      JSON.stringify({
        type: "user",
        uuid: "claude-desktop-shared-user",
        cwd: "/tmp/desktop-shared",
        timestamp: "2026-03-01T00:00:00.000Z",
        message: { role: "user", content: "shared Claude conversation" },
      }),
    );
    writeFileSync(
      join(unmatchedDir, `${unmatchedSessionId}.jsonl`),
      JSON.stringify({
        type: "user",
        uuid: "claude-desktop-unmatched-user",
        cwd: "/private/tmp/desktop-unmatched",
        timestamp: "2026-03-01T00:00:01.000Z",
        message: { role: "user", content: "unmatched Claude conversation" },
      }),
    );

    try {
      const { sessions } = await getAllRecentSessions({
        provider: "claude",
        limit: 200,
        metadataOnly: true,
      });
      const shared = sessions.find(
        (session) => session.sessionId === sharedSessionId,
      );
      const unmatched = sessions.find(
        (session) => session.sessionId === unmatchedSessionId,
      );

      expect(shared).toMatchObject({
        provider: "claude",
        projectGroupKind: "desktopProject",
        projectGroupingSnapshotComplete: true,
        projectGroupId: "project-shared",
        projectGroupName: "Shared Workspace",
        projectGroupPath: "/tmp/desktop-shared",
      });
      expect(unmatched).toMatchObject({
        provider: "claude",
        projectGroupKind: "projectless",
        projectGroupingSnapshotComplete: true,
      });

      const searched = await getAllRecentSessions({
        provider: "claude",
        searchQuery: "shared workspace",
        limit: 20,
        metadataOnly: true,
      });
      expect(searched.sessions.map((session) => session.sessionId)).toContain(
        sharedSessionId,
      );
    } finally {
      rmSync(globalStatePath, { force: true });
      rmSync(sharedDir, { recursive: true, force: true });
      rmSync(unmatchedDir, { recursive: true, force: true });
    }
  });

  it("includes codex sessions in getAllRecentSessions", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68010";
    const parentThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68000";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        timestamp: "2026-02-13T11:26:43.995Z",
        type: "session_meta",
        payload: {
          id: threadId,
          forked_from_id: parentThreadId,
          cwd: "/tmp/project-a",
          git: { branch: "main" },
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T11:26:44.100Z",
        type: "event_msg",
        payload: { type: "user_message", message: "hello codex" },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T11:26:45.100Z",
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "hello from assistant" }],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const { sessions } = await getAllRecentSessions({
      projectPath: "/tmp/project-a",
      limit: 200,
    });
    const entry = sessions.find((s) => s.sessionId === threadId);
    expect(entry).toBeDefined();
    expect(entry?.provider).toBe("codex");
    expect(entry?.forkedFromThreadId).toBe(parentThreadId);
    expect(entry?.projectPath).toBe("/tmp/project-a");
    expect(entry?.resumeCwd).toBeUndefined();
    expect(entry?.firstPrompt).toBe("hello codex");

    const metadata = await getCodexSessionIndexMetadata([threadId]);
    expect(metadata.get(threadId)?.forkedFromThreadId).toBe(parentThreadId);
    expect(metadata.get(threadId)?.projectPath).toBe("/tmp/project-a");
    expect(metadata.get(threadId)?.resumeCwd).toBeUndefined();
  });

  it("excludes codex subagent sessions from recent sessions", async () => {
    const userThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68020";
    const subagentThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68021";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${userThreadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: userThreadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "user visible session" },
        }),
      ].join("\n"),
    );
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-01-00-${subagentThreadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:01:00.000Z",
          type: "session_meta",
          payload: {
            id: subagentThreadId,
            cwd: "/tmp/project-a",
            source: { subagent: { other: "guardian" } },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:01:01.000Z",
          type: "turn_context",
          payload: { model: "codex-auto-review" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:01:02.000Z",
          type: "event_msg",
          payload: {
            type: "user_message",
            message: "The following is the Codex agent history...",
          },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions.map((s) => s.sessionId)).toEqual([userThreadId]);
  });

  it("excludes codex auto review sessions by model as a fallback", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68022";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-02-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:02:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:02:01.000Z",
          type: "turn_context",
          payload: {
            model: "codex-auto-review",
            collaboration_mode: {
              mode: "default",
              settings: { model: "codex-auto-review", reasoning_effort: "low" },
            },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:02:02.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "approval review prompt" },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions.some((s) => s.sessionId === threadId)).toBe(false);
  });

  it("excludes Codex auto-rename helpers without hiding prefix-matching user sessions", async () => {
    const userThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68023";
    const renameThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68024";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-03-00-${userThreadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:03:00.000Z",
          type: "session_meta",
          payload: { id: userThreadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:03:01.000Z",
          type: "turn_context",
          payload: { model: "gpt-5.4-mini" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:03:02.000Z",
          type: "event_msg",
          payload: {
            type: "user_message",
            message:
              "Write a concise name for this coding-agent session.\n\nPlease implement a similar user-facing prompt.",
          },
        }),
      ].join("\n"),
    );
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-04-00-${renameThreadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:04:00.000Z",
          type: "session_meta",
          payload: { id: renameThreadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:04:01.000Z",
          type: "turn_context",
          payload: { model: "gpt-oss:20b-cloud" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:04:02.000Z",
          type: "event_msg",
          payload: {
            type: "user_message",
            message: buildAutoRenamePrompt({ userText: "real task" }),
          },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions.map((s) => s.sessionId)).toEqual([userThreadId]);
  });

  it("normalizes codex worktree projectPath and keeps resumeCwd for resume targets", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68077";
    const mainProjectPath = "/tmp/project-a";
    const worktreePath = "/tmp/project-a-worktrees/feature-x";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        timestamp: "2026-02-13T12:00:00.000Z",
        type: "session_meta",
        payload: {
          id: threadId,
          cwd: worktreePath,
          git: { branch: "feature/x" },
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T12:00:01.000Z",
        type: "event_msg",
        payload: {
          type: "user_message",
          message: "resume this worktree session",
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T12:00:02.000Z",
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "worktree response" }],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const { sessions } = await getAllRecentSessions({ limit: 200 });
    const entry = sessions.find((s) => s.sessionId === threadId);
    expect(entry).toBeDefined();
    expect(entry?.provider).toBe("codex");
    expect(entry?.projectPath).toBe(mainProjectPath);
    expect(entry?.resumeCwd).toBe(worktreePath);

    const mainFilter = await getAllRecentSessions({
      projectPath: mainProjectPath,
      limit: 200,
    });
    expect(mainFilter.sessions.some((s) => s.sessionId === threadId)).toBe(
      true,
    );

    const worktreeFilter = await getAllRecentSessions({
      projectPath: worktreePath,
      limit: 200,
    });
    expect(worktreeFilter.sessions.some((s) => s.sessionId === threadId)).toBe(
      true,
    );
  });

  it("returns only codex sessions when provider=codex", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68088";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "codex only" },
        }),
      ].join("\n"),
    );

    // Add Claude data in the same HOME to validate provider filtering.
    const claudeProjectDir = join(
      tempHome,
      ".claude",
      "projects",
      "-tmp-project-a",
    );
    mkdirSync(claudeProjectDir, { recursive: true });
    writeFileSync(
      join(claudeProjectDir, "claude-session-1.jsonl"),
      JSON.stringify({
        type: "user",
        message: { role: "user", content: "claude session" },
        cwd: "/tmp/project-a",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].provider).toBe("codex");
    expect(result.sessions[0].sessionId).toBe(threadId);
  });

  it("restores codex reasoning effort from turn_context", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68011";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.500Z",
          type: "turn_context",
          payload: {
            model: "gpt-5.4",
            collaboration_mode: {
              mode: "default",
              settings: {
                model: "gpt-5.4",
                reasoning_effort: "xhigh",
              },
            },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "codex only" },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].codexSettings?.modelReasoningEffort).toBe(
      "xhigh",
    );
    expect(result.sessions[0].codexSettings?.collaborationMode).toBe("default");
  });

  it("uses the latest turn_context when restoring Codex speed", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68013";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.500Z",
          type: "turn_context",
          payload: { model: "gpt-5.6-sol", service_tier: "fast" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "turn_context",
          payload: { model: "gpt-5.6-sol" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:02.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "standard again" },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].codexSettings?.serviceTier).toBe("standard");
  });

  it("normalizes persisted Codex priority tier to client Fast", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68015";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.500Z",
          type: "turn_context",
          payload: { model: "gpt-5.6-sol", service_tier: "default" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.750Z",
          type: "event_msg",
          payload: {
            type: "thread_settings_applied",
            thread_settings: {
              model: "gpt-5.6-sol",
              reasoning_effort: "ultra",
              service_tier: "priority",
            },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "keep Fast selected" },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].codexSettings?.serviceTier).toBe("fast");
    expect(result.sessions[0].codexSettings?.modelReasoningEffort).toBe(
      "ultra",
    );
  });

  it("preserves non-UI Codex service tiers from turn_context", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68014";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.500Z",
          type: "turn_context",
          payload: { model: "gpt-5.6-sol", service_tier: "flex" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "keep flex" },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].codexSettings?.serviceTier).toBe("flex");
  });

  it("includes codex sessions when early turn context is large", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68012";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.500Z",
          type: "turn_context",
          payload: {
            model: "gpt-5.4",
            instructions: "x".repeat(70_000),
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "after large context" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:02.000Z",
          type: "response_item",
          payload: {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "assistant summary" }],
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:03.000Z",
          type: "event_msg",
          payload: { type: "token_count", details: "x".repeat(300_000) },
        }),
      ].join("\n"),
    );

    const result = await getAllRecentSessions({
      provider: "codex",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].sessionId).toBe(threadId);
    expect(result.sessions[0].firstPrompt).toBe("after large context");
  });

  it("restores authoritative Codex permissions beyond the fast tail window", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68103";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const rolloutPath = join(
      codexDir,
      `rollout-2026-02-13T12-00-00-${threadId}.jsonl`,
    );
    const lines = [
      JSON.stringify({
        timestamp: "2026-02-13T12:00:00.000Z",
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T12:00:00.100Z",
        type: "turn_context",
        payload: {
          model: "gpt-5.5",
          approval_policy: "on-request",
          approvals_reviewer: "user",
          sandbox_policy: { type: "workspace-write" },
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T12:00:00.200Z",
        type: "event_msg",
        payload: { type: "user_message", message: "large permission thread" },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T12:00:00.300Z",
        type: "event_msg",
        payload: { type: "token_count", details: "x".repeat(180_000) },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T12:00:01.000Z",
        type: "turn_context",
        payload: {
          model: "gpt-5.6-sol",
          approval_policy: "never",
          approvals_reviewer: "user",
          sandbox_policy: {
            type: "danger-full-access",
            network_access: true,
          },
          web_search: "live",
          service_tier: "priority",
          collaboration_mode: {
            mode: "default",
            settings: {
              model: "gpt-5.6-sol",
              reasoning_effort: "max",
            },
          },
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T12:00:01.100Z",
        type: "event_msg",
        payload: { type: "token_count", details: "y".repeat(80_000) },
      }),
    ];
    writeFileSync(
      rolloutPath,
      `${lines.join("\n")}\n{"timestamp":"2026-02-13T12:00:02.000Z","type":"turn_context","payload":{"approval_policy":"on-request"`,
    );

    const metadata = await getCodexSessionIndexMetadata([threadId], {
      authoritativeCodexSettings: true,
    });

    expect(metadata.get(threadId)?.codexSettings).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "max",
      serviceTier: "fast",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
      networkAccessEnabled: true,
      webSearchMode: "live",
    });
  });

  it("applies a newer official permission profile over the prior turn", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68104";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.100Z",
          type: "turn_context",
          payload: {
            model: "gpt-5.5",
            approval_policy: "on-request",
            approvals_reviewer: "user",
            sandbox_policy: { type: "workspace-write" },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.200Z",
          type: "event_msg",
          payload: { type: "user_message", message: "change permissions" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.300Z",
          type: "event_msg",
          payload: { type: "token_count", details: "x".repeat(180_000) },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: {
            type: "thread_settings_applied",
            thread_settings: {
              model: "gpt-5.6-sol",
              approval_policy: "never",
              approvals_reviewer: "user",
              active_permission_profile: { id: ":danger-full-access" },
              reasoning_effort: "ultra",
              service_tier: "priority",
            },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.100Z",
          type: "event_msg",
          payload: { type: "token_count", details: "y".repeat(80_000) },
        }),
      ].join("\n"),
    );

    const metadata = await getCodexSessionIndexMetadata([threadId], {
      authoritativeCodexSettings: true,
    });

    expect(metadata.get(threadId)?.codexSettings).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
    });
  });

  it("restores permissions when fast presentation metadata is unavailable", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68105";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.050Z",
          type: "response_item",
          payload: {
            type: "message",
            role: "developer",
            content: [{ type: "input_text", text: "d".repeat(140_000) }],
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.100Z",
          type: "event_msg",
          payload: { type: "user_message", message: "outside the fast head" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "turn_context",
          payload: {
            model: "gpt-5.6-sol",
            approval_policy: "never",
            approvals_reviewer: "user",
            sandbox_policy: { type: "danger-full-access" },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.100Z",
          type: "event_msg",
          payload: { type: "token_count", details: "z".repeat(80_000) },
        }),
      ].join("\n"),
    );

    const fastMetadata = await getCodexSessionIndexMetadata([threadId]);
    expect(fastMetadata.has(threadId)).toBe(false);

    const resumeMetadata = await getCodexSessionIndexMetadata([threadId], {
      authoritativeCodexSettings: true,
    });
    expect(resumeMetadata.get(threadId)?.codexSettings).toMatchObject({
      model: "gpt-5.6-sol",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
    });
  });

  it("keeps authoritative settings when the fast tail replays a parent session_meta", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68106";
    const parentThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68107";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${threadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/child-project" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.100Z",
          type: "turn_context",
          payload: {
            model: "gpt-5.6-sol",
            approval_policy: "never",
            approvals_reviewer: "user",
            sandbox_policy: { type: "danger-full-access" },
            collaboration_mode: {
              mode: "plan",
              settings: { reasoning_effort: "ultra" },
            },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.200Z",
          type: "event_msg",
          payload: { type: "user_message", message: "child request" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.300Z",
          type: "event_msg",
          payload: { type: "token_count", details: "x".repeat(180_000) },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "session_meta",
          payload: { id: parentThreadId, cwd: "/tmp/parent-project" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.100Z",
          type: "event_msg",
          payload: { type: "agent_message", message: "child answer" },
        }),
      ].join("\n"),
    );

    const metadata = await getCodexSessionIndexMetadata([threadId], {
      authoritativeCodexSettings: true,
    });

    expect(metadata.get(threadId)?.codexSettings).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
      collaborationMode: "plan",
    });
    expect(metadata.get(threadId)?.projectPath).toBe("/tmp/child-project");
    expect(metadata.get(threadId)?.resumeCwd).toBeUndefined();
  });

  it("rejects authoritative settings when the persisted rollout owner differs", async () => {
    const requestedThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68108";
    const persistedThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68109";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${requestedThreadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: persistedThreadId, cwd: "/tmp/wrong-owner" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.100Z",
          type: "turn_context",
          payload: {
            model: "gpt-5.6-sol",
            approval_policy: "never",
            sandbox_policy: { type: "danger-full-access" },
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.200Z",
          type: "event_msg",
          payload: { type: "user_message", message: "wrong owner" },
        }),
      ].join("\n"),
    );

    const metadata = await getCodexSessionIndexMetadata([requestedThreadId], {
      authoritativeCodexSettings: true,
    });

    expect(metadata.has(requestedThreadId)).toBe(false);
  });

  it("loads codex index metadata only for requested thread ids", async () => {
    const wantedThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68101";
    const ignoredThreadId = "019c56c0-d4d8-7b22-9e3c-200664d68102";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${wantedThreadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: {
            id: wantedThreadId,
            cwd: "/tmp/project-a-worktrees/feature-x",
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.500Z",
          type: "turn_context",
          payload: {
            model: "gpt-5.4",
            approval_policy: "on-request",
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "wanted" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:02.000Z",
          type: "event_msg",
          payload: { type: "agent_message", message: "done: fixed the bug" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:02.500Z",
          type: "response_item",
          payload: {
            type: "agent_message",
            message: "private agent-to-agent handoff",
          },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:03.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "thanks, now add a test" },
        }),
      ].join("\n"),
    );
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T12-00-00-${ignoredThreadId}.jsonl`),
      [
        JSON.stringify({
          timestamp: "2026-02-13T12:00:00.000Z",
          type: "session_meta",
          payload: { id: ignoredThreadId, cwd: "/tmp/project-b" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T12:00:01.000Z",
          type: "event_msg",
          payload: { type: "user_message", message: "ignored" },
        }),
      ].join("\n"),
    );

    const metadata = await getCodexSessionIndexMetadata([wantedThreadId]);

    expect([...metadata.keys()]).toEqual([wantedThreadId]);
    expect(metadata.get(wantedThreadId)?.projectPath).toBe("/tmp/project-a");
    expect(metadata.get(wantedThreadId)?.resumeCwd).toBe(
      "/tmp/project-a-worktrees/feature-x",
    );
    expect(metadata.get(wantedThreadId)?.codexSettings?.model).toBe("gpt-5.4");
    expect(metadata.get(wantedThreadId)?.codexSettings?.approvalPolicy).toBe(
      "on-request",
    );
    expect(metadata.get(wantedThreadId)?.firstPrompt).toBe("wanted");
    expect(metadata.get(wantedThreadId)?.lastPrompt).toBe(
      "thanks, now add a test",
    );
    expect(metadata.get(wantedThreadId)?.summary).toBe("done: fixed the bug");
  });

  it("reads codex history from jsonl", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68010";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "show me the diff" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "Here is the diff summary." }],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history).toHaveLength(2);
    expect(history[0].role).toBe("user");
    expect(history[0].uuid).toBe("codex:user-turn:1");
    expect(history[0].content[0].text).toBe("show me the diff");
    expect(history[1].role).toBe("assistant");
    expect(history[1].content[0].text).toBe("Here is the diff summary.");
  });

  it("keeps repeated JSONL tool ids isolated by active provider turn", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68019";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });
    const lines: string[] = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
    ];
    for (const turnId of ["provider-turn-one", "provider-turn-two"]) {
      lines.push(
        JSON.stringify({
          type: "event_msg",
          payload: { type: "task_started", turn_id: turnId },
        }),
        JSON.stringify({
          type: "event_msg",
          payload: {
            type: "user_message",
            client_id: "reused-client-message",
            message: `request ${turnId}`,
          },
        }),
        JSON.stringify({
          type: "response_item",
          payload: {
            type: "function_call",
            name: "exec_command",
            call_id: "reused-tool",
            arguments: JSON.stringify({ cmd: "pwd" }),
          },
        }),
        JSON.stringify({
          type: "response_item",
          payload: {
            type: "function_call_output",
            call_id: "reused-tool",
            output: `result ${turnId}`,
          },
        }),
        JSON.stringify({
          type: "event_msg",
          payload: { type: "task_complete", turn_id: turnId },
        }),
      );
    }
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    const results = history.filter(
      (message) =>
        message.role === "tool_result" && message.toolUseId === "reused-tool",
    );
    expect(results).toHaveLength(2);
    expect(results.map((message) => message.historyTurnId)).toEqual([
      "provider-turn-one",
      "provider-turn-two",
    ]);
    expect(results.map((message) => message.content)).toEqual([
      "result provider-turn-one",
      "result provider-turn-two",
    ]);
  });

  it("streams codex history with large irrelevant entries", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68011";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const filler = JSON.stringify({
      type: "turn_context",
      payload: { ignored: "x".repeat(1024) },
    });
    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      ...Array.from({ length: 20_000 }, () => filler),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "after large context" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "still responsive" }],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history.map((message) => message.content[0].text)).toEqual([
      "after large context",
      "still responsive",
    ]);
  });

  it("trims codex history after thread_rolled_back events", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68013";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "first turn" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "first answer" }],
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "second turn" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "second answer" }],
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "thread_rolled_back", num_turns: 1 },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history.map((message) => message.content[0].text)).toEqual([
      "first turn",
      "first answer",
    ]);
    expect(history[0].uuid).toBe("codex:user-turn:1");
  });

  it("restores codex tool-use history from response_item entries", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68012";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: "# AGENTS.md instructions for /tmp/project-a",
            },
          ],
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "check simulator status" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "mcp__dart-mcp__list_running_apps",
          call_id: "call-1",
          arguments: '{"root":"/tmp/project-a"}',
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "custom_tool_call",
          name: "apply_patch",
          call_id: "call-2",
          input: "*** Begin Patch\n*** End Patch\n",
          status: "completed",
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "web_search_call",
          status: "completed",
          action: {
            type: "search",
            query: "ccpocket codex mcp history restore",
          },
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "Checked all logs." }],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);

    expect(history).toHaveLength(5);
    expect(history[0]).toEqual({
      role: "user",
      uuid: "codex:user-turn:1",
      content: [{ type: "text", text: "check simulator status" }],
    });
    expect(history[1]).toEqual({
      role: "assistant",
      uuid: "call-1",
      content: [
        {
          type: "tool_use",
          id: "call-1",
          name: "mcp:dart-mcp/list_running_apps",
          input: { root: "/tmp/project-a" },
        },
      ],
    });
    expect(history[2].content[0].type).toBe("tool_use");
    expect(history[2].content[0].name).toBe("FileChange");
    expect(history[3]).toEqual({
      role: "assistant",
      uuid: "web-search-5",
      content: [
        {
          type: "tool_use",
          id: "web-search-5",
          name: "WebSearch",
          input: { query: "ccpocket codex mcp history restore" },
        },
      ],
    });
    expect(history[4]).toMatchObject({
      role: "assistant",
      content: [{ type: "text", text: "Checked all logs." }],
    });
    expect(history[4].uuid).toMatch(/^codex:assistant:[A-Za-z0-9_-]{32}$/);
    const replayed = await getCodexSessionHistory(threadId);
    expect(replayed[4].uuid).toBe(history[4].uuid);
  });

  it("restores Desktop exec categories and matching completion outputs", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68019";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "custom_tool_call",
          name: "exec",
          call_id: "call-read",
          input:
            'const r = await tools.exec_command({cmd:"sed -n \'1,40p\' /tmp/project-a/SKILL.md",workdir:"/tmp/project-a"}); text(r.output);',
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T11:28:00.000Z",
        type: "response_item",
        payload: {
          type: "custom_tool_call_output",
          call_id: "call-read",
          output: [
            { type: "input_text", text: "Script completed\n" },
            { type: "input_text", text: "skill body" },
          ],
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "spawn_agent",
          call_id: "call-agent",
          arguments: '{"task_name":"review"}',
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: "call-agent",
          output: "agent started",
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history).toEqual([
      expect.objectContaining({
        role: "assistant",
        uuid: "call-read",
        content: [
          expect.objectContaining({
            type: "tool_use",
            id: "call-read",
            name: "ReadSkill",
          }),
        ],
      }),
      expect.objectContaining({
        role: "tool_result",
        toolUseId: "call-read",
        toolName: "ReadSkill",
        content: "Script completed\n\nskill body",
      }),
      expect.objectContaining({
        role: "assistant",
        uuid: "call-agent",
        content: [expect.objectContaining({ name: "SpawnAgent" })],
      }),
      expect.objectContaining({
        role: "tool_result",
        toolUseId: "call-agent",
        toolName: "SpawnAgent",
        content: "agent started",
      }),
    ]);
  });

  it("restores the real Codex Desktop view_image shape without base64 text", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68029";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });
    const imagePath = "/tmp/project-a/referenced screenshot.png";
    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "view_image",
          call_id: "call-image",
          arguments: JSON.stringify({ path: imagePath, detail: "high" }),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: "call-image",
          output: [
            {
              type: "input_image",
              detail: "high",
              image_url: "data:image/png;base64,aGVsbG8=",
            },
          ],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history).toEqual([
      expect.objectContaining({
        role: "assistant",
        uuid: "call-image",
        content: [
          expect.objectContaining({
            type: "tool_use",
            id: "call-image",
            name: "ViewImage",
          }),
        ],
      }),
      expect.objectContaining({
        role: "tool_result",
        toolUseId: "call-image",
        toolName: "ViewImage",
        content: "Viewed image",
        imagePaths: [imagePath],
      }),
    ]);
    expect(JSON.stringify(history)).not.toContain("aGVsbG8=");
  });

  it("restores codex MCP tool result images from event_msg entries", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68016";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const imageData = "iVBORw0KGgo=";
    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "inspect chrome" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "mcp__computer-use__get_app_state",
          call_id: "call-1",
          arguments: '{"app":"Google Chrome"}',
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T11:28:00.000Z",
        type: "event_msg",
        payload: {
          type: "mcp_tool_call_end",
          call_id: "call-1",
          invocation: {
            server: "computer-use",
            tool: "get_app_state",
            arguments: { app: "Google Chrome" },
          },
          result: {
            Ok: {
              content: [
                { type: "text", text: "Computer Use state" },
                { type: "image", data: imageData, mimeType: "image/png" },
              ],
            },
          },
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);

    expect(history).toHaveLength(3);
    expect(history[0]).toEqual({
      role: "user",
      uuid: "codex:user-turn:1",
      content: [{ type: "text", text: "inspect chrome" }],
    });
    expect(history[1].content[0].type).toBe("tool_use");
    expect(history[2]).toEqual({
      role: "tool_result",
      toolUseId: "call-1",
      toolName: "mcp:computer-use/get_app_state",
      content: "Computer Use state",
      imageBase64: [{ data: imageData, mimeType: "image/png" }],
      timestamp: "2026-02-13T11:28:00.000Z",
      timestampIsAuthoritative: true,
    });
  });

  it("skips codex skill injections and restores image generation results", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68015";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const savedPath = "/tmp/project-a/generated.png";
    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "$imagegen make a hero" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: "<skill>\n<name>imagegen</name>\nsecret instructions\n</skill>",
            },
          ],
        },
      }),
      JSON.stringify({
        timestamp: "2026-02-13T11:27:00.000Z",
        type: "event_msg",
        payload: {
          type: "image_generation_end",
          call_id: "ig-1",
          status: "completed",
          revised_prompt: "polished mobile app hero",
          saved_path: savedPath,
          result: "large-base64-data",
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "image_generation_call",
          id: "ig-1",
          status: "completed",
          revised_prompt: "polished mobile app hero",
          result: "large-base64-data",
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);

    expect(history).toEqual([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "$imagegen make a hero" }],
      },
      {
        role: "tool_result",
        toolUseId: "ig-1",
        toolName: "ImageGeneration",
        content:
          "status: completed\nrevisedPrompt: polished mobile app hero\n" +
          `savedPath: ${savedPath}`,
        imagePaths: [savedPath],
        timestamp: "2026-02-13T11:27:00.000Z",
        timestampIsAuthoritative: true,
      },
    ]);
  });

  it("restores image generation base64 result without leaking it into content", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68016";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      [
        JSON.stringify({
          type: "session_meta",
          payload: { id: threadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          type: "event_msg",
          payload: { type: "user_message", message: "$imagegen make a hero" },
        }),
        JSON.stringify({
          timestamp: "2026-02-13T11:27:00.000Z",
          type: "response_item",
          payload: {
            type: "image_generation_call",
            id: "ig-2",
            status: "completed",
            result: "data:image/png;base64,aGVsbG8=",
          },
        }),
      ].join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);

    expect(history).toEqual([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "$imagegen make a hero" }],
      },
      {
        role: "tool_result",
        toolUseId: "ig-2",
        toolName: "ImageGeneration",
        content: "status: completed",
        imageBase64: [{ data: "aGVsbG8=", mimeType: "image/png" }],
        timestamp: "2026-02-13T11:27:00.000Z",
        timestampIsAuthoritative: true,
      },
    ]);
  });

  it("renders placeholder text for image-only codex user messages", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68013";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "user_message",
          message: "",
          images: [{ id: "img1" }],
          local_images: [{ path: "/tmp/1.png" }],
          text_elements: [],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history).toEqual([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "[Image attached x2]" }],
        imageCount: 2,
      },
    ]);
  });

  it("extracts codex user images by turn uuid", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68014";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "first" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "user_message",
          message: "with image",
          images: ["data:image/png;base64,aW1hZ2U="],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    await expect(
      extractMessageImages(threadId, "codex:user-turn:2"),
    ).resolves.toEqual([{ base64: "aW1hZ2U=", mimeType: "image/png" }]);
  });

  it("extracts codex user images from rollout filename without session meta", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68017";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "user_message",
          message: "with image",
          images: ["data:image/png;base64,aW1hZ2U="],
        },
      }),
    );

    await expect(
      extractMessageImages(threadId, "codex:user-turn:1"),
    ).resolves.toEqual([{ base64: "aW1hZ2U=", mimeType: "image/png" }]);
  });

  it("extracts codex user images from local image paths", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68015";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    const imagePath = join(tempHome, "ccpocket-codex-image.png");
    mkdirSync(codexDir, { recursive: true });
    writeFileSync(imagePath, Buffer.from("local-image"));

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "user_message",
          message: "with local image",
          images: [],
          local_images: [imagePath],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    await expect(getCodexSessionHistory(threadId)).resolves.toEqual([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "with local image" }],
        imageCount: 1,
      },
    ]);
    await expect(
      extractMessageImages(threadId, "codex:user-turn:1"),
    ).resolves.toEqual([
      {
        base64: Buffer.from("local-image").toString("base64"),
        mimeType: "image/png",
      },
    ]);
  });

  it("extracts codex user images from response items when local image files are gone", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68016";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: "# AGENTS.md instructions for /tmp/project-a\n\n<INSTRUCTIONS>",
            },
            {
              type: "input_text",
              text: "<environment_context><cwd>/tmp/project-a</cwd></environment_context>",
            },
          ],
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [
            { type: "input_text", text: "with response image" },
            { type: "input_text", text: "<image name=[Image #1]>" },
            {
              type: "input_image",
              image_url: "data:image/png;base64,cmVzcG9uc2UtaW1hZ2U=",
            },
            { type: "input_text", text: "</image>" },
          ],
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "user_message",
          message: "with response image",
          images: [],
          local_images: [join(tempHome, "missing-image.png")],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    await expect(getCodexSessionHistory(threadId)).resolves.toEqual([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "with response image" }],
        imageCount: 1,
      },
    ]);
    await expect(
      extractMessageImages(threadId, "codex:user-turn:1"),
    ).resolves.toEqual([
      { base64: "cmVzcG9uc2UtaW1hZ2U=", mimeType: "image/png" },
    ]);
  });

  it("pairs codex response images when the event entry appears first", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68018";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      [
        JSON.stringify({
          type: "event_msg",
          payload: {
            type: "user_message",
            message: "event first",
            images: [],
          },
        }),
        JSON.stringify({
          type: "response_item",
          payload: {
            type: "message",
            role: "user",
            content: [
              { type: "input_text", text: "event first" },
              {
                type: "input_image",
                image_url: "data:image/png;base64,ZXZlbnQtZmlyc3Q=",
              },
            ],
          },
        }),
      ].join("\n"),
    );

    await expect(
      extractMessageImages(threadId, "codex:user-turn:1"),
    ).resolves.toEqual([{ base64: "ZXZlbnQtZmlyc3Q=", mimeType: "image/png" }]);
  });

  it("supports legacy codex response_item tool schemas", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68014";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "legacy tool schema" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "command_execution",
          id: "cmd-1",
          command: "git status",
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "mcp_tool_call",
          id: "mcp-1",
          server: "dart-mcp",
          tool: "launch_app",
          arguments: { device: "ios" },
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history).toEqual([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "legacy tool schema" }],
      },
      {
        role: "assistant",
        uuid: "cmd-1",
        content: [
          {
            type: "tool_use",
            id: "cmd-1",
            name: "Bash",
            input: { command: "git status" },
          },
        ],
      },
      {
        role: "assistant",
        uuid: "mcp-1",
        content: [
          {
            type: "tool_use",
            id: "mcp-1",
            name: "mcp:dart-mcp/launch_app",
            input: { device: "ios" },
          },
        ],
      },
    ]);
  });

  it("preserves semantic Codex process tools when rebuilding history", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68019";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const toolItems = [
      {
        type: "command_execution",
        id: "read-skill-1",
        command: "sed -n '1,200p' /tmp/demo/SKILL.md",
        command_actions: [
          {
            type: "read",
            command: "sed -n '1,200p' /tmp/demo/SKILL.md",
            name: "SKILL.md",
            path: "/tmp/demo/SKILL.md",
          },
        ],
      },
      {
        type: "command_execution",
        id: "multi-1",
        command: "git status && git diff --stat",
        command_actions: [
          { type: "unknown", command: "git status" },
          { type: "unknown", command: "git diff --stat" },
        ],
      },
      {
        type: "collab_agent_tool_call",
        id: "agent-1",
        tool: "spawnAgent",
        prompt: "Inspect the parser",
      },
      { type: "context_compaction", id: "compact-1" },
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      toolItems
        .map((payload) => JSON.stringify({ type: "response_item", payload }))
        .join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    const toolUses = history.flatMap((message) =>
      message.content.filter((item) => item.type === "tool_use"),
    );
    expect(toolUses.map((item) => item.name)).toEqual([
      "ReadSkill",
      "MultiCommand",
      "SpawnAgent",
      "ContextCompaction",
    ]);
    expect(toolUses[0]?.input).toMatchObject({
      file_path: "/tmp/demo/SKILL.md",
      skill: "demo",
    });
    expect(toolUses[1]?.input).toMatchObject({
      commands: ["git status", "git diff --stat"],
    });
  });

  it("joins multiple assistant output_text chunks and ignores non-text chunks", async () => {
    const threadId = "019c56c0-d4d8-7b22-9e3c-200664d68011";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    const lines = [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId, cwd: "/tmp/project-a" },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", message: "summarize this" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [
            { type: "output_text", text: "Line 1" },
            { type: "reasoning", text: "hidden reasoning" },
            { type: "output_text", text: "Line 2" },
          ],
        },
      }),
    ];
    writeFileSync(
      join(codexDir, `rollout-2026-02-13T11-26-43-${threadId}.jsonl`),
      lines.join("\n"),
    );

    const history = await getCodexSessionHistory(threadId);
    expect(history).toHaveLength(2);
    expect(history[1].role).toBe("assistant");
    expect(history[1].content[0].text).toBe("Line 1\nLine 2");
  });

  it("does not match loosely similar filename suffixes for threadId lookup", async () => {
    const requestedThreadId = "123";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    // Similar suffix ("abc123") should not be treated as threadId "123".
    writeFileSync(
      join(codexDir, "rollout-2026-02-13T11-26-43-abc123.jsonl"),
      [
        JSON.stringify({
          type: "session_meta",
          payload: { id: "abc123", cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          type: "event_msg",
          payload: { type: "user_message", message: "wrong session" },
        }),
      ].join("\n"),
    );

    // Exact "-123" suffix should be matched.
    writeFileSync(
      join(codexDir, "rollout-2026-02-13T11-26-43-123.jsonl"),
      [
        JSON.stringify({
          type: "session_meta",
          payload: { id: requestedThreadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          type: "event_msg",
          payload: { type: "user_message", message: "correct session" },
        }),
      ].join("\n"),
    );

    const history = await getCodexSessionHistory(requestedThreadId);
    expect(history).toHaveLength(1);
    expect(history[0].role).toBe("user");
    expect(history[0].content[0].text).toBe("correct session");
  });

  it("does not trust -threadId filename suffix when session_meta.id differs", async () => {
    const requestedThreadId = "123";
    const codexDir = join(tempHome, ".codex", "sessions", "2026", "02", "13");
    mkdirSync(codexDir, { recursive: true });

    // Filename ends with -123 but meta id is different: must not match.
    writeFileSync(
      join(codexDir, "rollout-2026-02-13T11-26-43-123.jsonl"),
      [
        JSON.stringify({
          type: "session_meta",
          payload: { id: "not-123", cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          type: "event_msg",
          payload: { type: "user_message", message: "wrong session" },
        }),
      ].join("\n"),
    );

    // Exact basename match should still work.
    writeFileSync(
      join(codexDir, "123.jsonl"),
      [
        JSON.stringify({
          type: "session_meta",
          payload: { id: requestedThreadId, cwd: "/tmp/project-a" },
        }),
        JSON.stringify({
          type: "event_msg",
          payload: { type: "user_message", message: "correct session" },
        }),
      ].join("\n"),
    );

    const history = await getCodexSessionHistory(requestedThreadId);
    expect(history).toHaveLength(1);
    expect(history[0].content[0].text).toBe("correct session");
  });

  it("indexes Claude user images by uuid", async () => {
    const sessionId = "claude-image-index";
    const claudeDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(claudeDir, { recursive: true });
    writeFileSync(
      join(claudeDir, `${sessionId}.jsonl`),
      [
        JSON.stringify({
          type: "user",
          uuid: "uuid-text",
          message: { role: "user", content: "text only" },
        }),
        JSON.stringify({
          type: "user",
          uuid: "uuid-image",
          message: {
            role: "user",
            content: [
              { type: "text", text: "look" },
              {
                type: "image",
                source: {
                  type: "base64",
                  media_type: "image/png",
                  data: "aW1hZ2U=",
                },
              },
            ],
          },
        }),
        JSON.stringify({
          type: "user",
          uuid: "uuid-malformed-image",
          message: {
            role: "user",
            content: [
              {
                type: "image",
                source: {
                  type: "base64",
                  media_type: "image/png",
                  data: { unexpected: true },
                },
              },
            ],
          },
        }),
      ].join("\n"),
    );

    await expect(
      extractMessageImages(sessionId, "uuid-image"),
    ).resolves.toEqual([{ base64: "aW1hZ2U=", mimeType: "image/png" }]);
    await expect(extractMessageImages(sessionId, "uuid-text")).resolves.toEqual(
      [],
    );
    await expect(
      extractMessageImages(sessionId, "uuid-malformed-image"),
    ).resolves.toEqual([]);
  });

  it("reuses a fresh Claude image index and invalidates it on file changes", async () => {
    const sessionId = "claude-image-cache-reuse";
    const claudeDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(claudeDir, { recursive: true });
    const jsonlPath = join(claudeDir, `${sessionId}.jsonl`);
    const entry = (data: string) =>
      JSON.stringify({
        type: "user",
        uuid: "uuid-image",
        message: {
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", media_type: "image/png", data },
            },
          ],
        },
      });
    const fixedTime = new Date(1_700_000_000_000);
    writeFileSync(jsonlPath, entry("AAAA"));
    utimesSync(jsonlPath, fixedTime, fixedTime);

    await expect(
      extractMessageImages(sessionId, "uuid-image"),
    ).resolves.toEqual([{ base64: "AAAA", mimeType: "image/png" }]);

    const originalStat = statSync(jsonlPath);
    writeFileSync(jsonlPath, entry("BBBB"));
    utimesSync(jsonlPath, fixedTime, fixedTime);
    expect(statSync(jsonlPath).mtimeMs).toBe(originalStat.mtimeMs);
    await expect(
      extractMessageImages(sessionId, "uuid-image"),
    ).resolves.toEqual([{ base64: "AAAA", mimeType: "image/png" }]);

    writeFileSync(jsonlPath, entry("CCCCCC"));
    await expect(
      extractMessageImages(sessionId, "uuid-image"),
    ).resolves.toEqual([{ base64: "CCCCCC", mimeType: "image/png" }]);
  });
});

describe("claude namedOnly optimization", () => {
  const oldHome = process.env.HOME;
  const tempHome = mkdtempSync(join(tmpdir(), "ccpocket-test-claude-home-"));

  beforeEach(() => {
    process.env.HOME = tempHome;
  });

  afterEach(() => {
    process.env.HOME = oldHome;
    rmSync(tempHome, { recursive: true, force: true });
  });

  it("returns only named Claude sessions from sessions-index", async () => {
    const projectDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "sessions-index.json"),
      JSON.stringify({
        version: 1,
        entries: [
          {
            sessionId: "named-s1",
            fullPath: join(projectDir, "named-s1.jsonl"),
            fileMtime: Date.now(),
            firstPrompt: "named prompt",
            customTitle: "My named session",
            messageCount: 4,
            created: "2026-02-13T11:00:00.000Z",
            modified: "2026-02-13T12:00:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
          {
            sessionId: "unnamed-s2",
            fullPath: join(projectDir, "unnamed-s2.jsonl"),
            fileMtime: Date.now(),
            firstPrompt: "unnamed prompt",
            messageCount: 2,
            created: "2026-02-13T10:00:00.000Z",
            modified: "2026-02-13T10:10:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
        ],
      }),
    );

    const result = await getAllRecentSessions({
      provider: "claude",
      namedOnly: true,
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].sessionId).toBe("named-s1");
    expect(result.sessions[0].name).toBe("My named session");
  });

  it("keeps the content scheduler catalog on indexed metadata", async () => {
    const projectDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    const sessionId = "metadata-only-session";
    const jsonlPath = join(projectDir, `${sessionId}.jsonl`);
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "sessions-index.json"),
      JSON.stringify({
        version: 1,
        entries: [
          {
            sessionId,
            fullPath: jsonlPath,
            fileMtime: Date.now(),
            firstPrompt: "first prompt",
            messageCount: 3,
            created: "2026-02-13T11:00:00.000Z",
            modified: "2026-02-13T12:00:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
        ],
      }),
    );
    writeFileSync(
      jsonlPath,
      [
        JSON.stringify({
          type: "user",
          uuid: "user-1",
          cwd: "/tmp/project-a",
          timestamp: "2026-02-13T11:00:00.000Z",
          message: { role: "user", content: "first prompt" },
        }),
        JSON.stringify({
          type: "assistant",
          uuid: "assistant-1",
          cwd: "/tmp/project-a",
          timestamp: "2026-02-13T11:30:00.000Z",
          message: { role: "assistant", content: "working" },
        }),
        JSON.stringify({
          type: "user",
          uuid: "user-2",
          cwd: "/tmp/project-a",
          timestamp: "2026-02-13T12:00:00.000Z",
          message: { role: "user", content: "latest prompt" },
        }),
      ].join("\n"),
    );

    const metadataOnly = await getAllRecentSessions({
      provider: "claude",
      limit: 200,
      metadataOnly: true,
    });
    const enriched = await getAllRecentSessions({
      provider: "claude",
      limit: 200,
    });

    expect(metadataOnly.sessions).toHaveLength(1);
    expect(metadataOnly.sessions[0]).toMatchObject({
      sessionId,
      modified: "2026-02-13T12:00:00.000Z",
      firstPrompt: "first prompt",
    });
    expect(metadataOnly.sessions[0].lastPrompt).toBeUndefined();
    expect(enriched.sessions).toHaveLength(1);
    expect(enriched.sessions[0].lastPrompt).toBe("latest prompt");
  });

  it("finds an exact Claude session outside the first recent page", async () => {
    const projectDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "sessions-index.json"),
      JSON.stringify({
        version: 1,
        entries: [
          {
            sessionId: "newer-s1",
            fullPath: join(projectDir, "newer-s1.jsonl"),
            fileMtime: Date.now(),
            firstPrompt: "newer prompt",
            messageCount: 2,
            created: "2026-02-13T12:00:00.000Z",
            modified: "2026-02-13T12:00:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
          {
            sessionId: "target-s2",
            fullPath: join(projectDir, "target-s2.jsonl"),
            fileMtime: Date.now() - 1000,
            firstPrompt: "target prompt",
            messageCount: 2,
            created: "2026-02-13T10:00:00.000Z",
            modified: "2026-02-13T10:00:00.000Z",
            gitBranch: "feature",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
        ],
      }),
    );

    const result = await getAllRecentSessions({
      provider: "claude",
      sessionId: "target-s2",
      limit: 1,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0]).toMatchObject({
      sessionId: "target-s2",
      projectPath: "/tmp/project-a",
      gitBranch: "feature",
    });
  });

  it("excludes indexed Claude auto-rename helper sessions", async () => {
    const projectDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "sessions-index.json"),
      JSON.stringify({
        version: 1,
        entries: [
          {
            sessionId: "real-s1",
            fullPath: join(projectDir, "real-s1.jsonl"),
            fileMtime: Date.now(),
            firstPrompt: "real prompt",
            messageCount: 2,
            created: "2026-02-13T11:00:00.000Z",
            modified: "2026-02-13T12:00:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
          {
            sessionId: "auto-rename-helper",
            fullPath: join(projectDir, "auto-rename-helper.jsonl"),
            fileMtime: Date.now(),
            firstPrompt: buildAutoRenamePrompt({ userText: "real task" }),
            messageCount: 2,
            created: "2026-02-13T11:30:00.000Z",
            modified: "2026-02-13T11:30:01.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
        ],
      }),
    );

    const result = await getAllRecentSessions({
      provider: "claude",
      limit: 200,
    });

    expect(result.sessions.map((s) => s.sessionId)).toEqual(["real-s1"]);
  });

  it("skips jsonl-only Claude directories when namedOnly=true", async () => {
    const projectDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "orphan.jsonl"),
      JSON.stringify({
        type: "user",
        message: { role: "user", content: "orphan session" },
        cwd: "/tmp/project-a",
        timestamp: "2026-02-13T12:00:00.000Z",
      }),
    );

    const result = await getAllRecentSessions({
      provider: "claude",
      namedOnly: true,
      limit: 200,
    });

    expect(result.sessions).toEqual([]);
  });

  it("repairs indexed Claude entries with missing projectPath from JSONL", async () => {
    const projectDir = join(
      tempHome,
      ".claude",
      "projects",
      "-Users-test-big-image-project",
    );
    mkdirSync(projectDir, { recursive: true });

    const sessionId = "indexed-missing-project-path";
    const largeBase64 = "A".repeat(20 * 1024);
    writeFileSync(
      join(projectDir, `${sessionId}.jsonl`),
      JSON.stringify({
        type: "user",
        message: {
          role: "user",
          content: [
            { type: "text", text: "Please inspect this screenshot." },
            {
              type: "image",
              source: {
                type: "base64",
                media_type: "image/png",
                data: largeBase64,
              },
            },
          ],
        },
        cwd: "/Users/test/big-image-project",
        gitBranch: "main",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    );
    writeFileSync(
      join(projectDir, "sessions-index.json"),
      JSON.stringify({
        version: 1,
        entries: [
          {
            sessionId,
            fullPath: join(projectDir, `${sessionId}.jsonl`),
            fileMtime: Date.now(),
            firstPrompt: "Please inspect this screenshot.",
            messageCount: 1,
            created: "2026-01-01T00:00:00.000Z",
            modified: "2026-01-01T00:00:00.000Z",
            gitBranch: "",
            projectPath: "",
            isSidechain: false,
          },
        ],
      }),
    );

    const result = await getAllRecentSessions({
      provider: "claude",
      projectPath: "/Users/test/big-image-project",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].sessionId).toBe(sessionId);
    expect(result.sessions[0].projectPath).toBe(
      "/Users/test/big-image-project",
    );
    expect(result.sessions[0].gitBranch).toBe("main");
    expect(result.sessions[0].firstPrompt).toBe(
      "Please inspect this screenshot.",
    );
  });

  it("hydrates indexed Claude session names from JSONL custom-title entries", async () => {
    const projectDir = join(tempHome, ".claude", "projects", "-tmp-project-a");
    mkdirSync(projectDir, { recursive: true });

    const sessionId = "indexed-jsonl-title";
    writeFileSync(
      join(projectDir, `${sessionId}.jsonl`),
      [
        JSON.stringify({
          type: "user",
          message: { role: "user", content: "hello" },
          cwd: "/tmp/project-a",
          gitBranch: "main",
          timestamp: "2026-01-01T00:00:00.000Z",
          uuid: "user-1",
        }),
        JSON.stringify({
          type: "custom-title",
          customTitle: "SDK title",
          sessionId,
        }),
      ].join("\n"),
    );
    writeFileSync(
      join(projectDir, "sessions-index.json"),
      JSON.stringify({
        version: 1,
        entries: [
          {
            sessionId,
            fullPath: join(projectDir, `${sessionId}.jsonl`),
            fileMtime: Date.now(),
            firstPrompt: "hello",
            messageCount: 1,
            created: "2026-01-01T00:00:00.000Z",
            modified: "2026-01-01T00:00:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-a",
            isSidechain: false,
          },
        ],
      }),
    );

    const result = await getAllRecentSessions({
      provider: "claude",
      projectPath: "/tmp/project-a",
      limit: 200,
    });

    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].sessionId).toBe(sessionId);
    expect(result.sessions[0].name).toBe("SDK title");
  });
});

describe("readClaudeJsonlHistoryWindow", () => {
  function textOf(message: SessionHistoryMessage): string {
    if (typeof message.content === "string") return message.content;
    return message.content
      .map((item) => item.text ?? item.thinking ?? "")
      .filter(Boolean)
      .join("\n");
  }

  function userLine(id: string, text: string): string {
    return JSON.stringify({
      type: "user",
      uuid: `user-${id}`,
      timestamp: `2026-07-31T00:00:${id.padStart(2, "0")}.000Z`,
      message: { role: "user", content: text },
    });
  }

  function assistantLine(id: string, text: string): string {
    return JSON.stringify({
      type: "assistant",
      uuid: `assistant-${id}`,
      timestamp: `2026-07-31T00:01:${id.padStart(2, "0")}.000Z`,
      message: {
        role: "assistant",
        content: [{ type: "text", text }],
      },
    });
  }

  it("resolves a durable Claude session id before reading its bounded page", async () => {
    const oldHome = process.env.HOME;
    const directory = mkdtempSync(join(tmpdir(), "claude-session-window-"));
    const sessionId = "bounded-session-id";
    const projectDirectory = join(
      directory,
      ".claude",
      "projects",
      "-bounded-project",
    );
    try {
      process.env.HOME = directory;
      mkdirSync(projectDirectory, { recursive: true });
      writeFileSync(
        join(projectDirectory, `${sessionId}.jsonl`),
        [
          userLine("1", "resolved question"),
          assistantLine("1", "resolved answer"),
        ].join("\n"),
      );

      const result = await readClaudeSessionHistoryWindow(sessionId, {
        maxUserTurns: 1,
        maxBytes: 64 * 1024,
      });

      expect(result.messages.map(textOf)).toEqual([
        "resolved question",
        "resolved answer",
      ]);
      expect(result.hasMore).toBe(false);
    } finally {
      if (oldHome === undefined) delete process.env.HOME;
      else process.env.HOME = oldHome;
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("reads recent real user turns without scanning a huge prefix", async () => {
    const directory = mkdtempSync(join(tmpdir(), "claude-tail-window-"));
    const jsonlPath = join(directory, "history.jsonl");
    try {
      const filler = JSON.stringify({
        type: "progress",
        payload: { ignored: "x".repeat(512) },
      });
      writeFileSync(
        jsonlPath,
        [
          ...Array.from({ length: 10_000 }, () => filler),
          userLine("1", "old question"),
          assistantLine("1", "old answer"),
          userLine("2", "recent question two"),
          assistantLine("2", "recent answer two"),
          JSON.stringify({
            type: "user",
            uuid: "meta-user",
            isMeta: true,
            message: { role: "user", content: "loaded skill context" },
          }),
          JSON.stringify({
            type: "user",
            uuid: "tool-result-only",
            message: {
              role: "user",
              content: [
                { type: "tool_result", tool_use_id: "tool-1", content: "ok" },
              ],
            },
          }),
          "{broken-json",
          userLine("3", "recent question three"),
          assistantLine("3", "recent answer three"),
        ].join("\n"),
      );

      const result = await readClaudeJsonlHistoryWindow(jsonlPath, {
        maxUserTurns: 2,
        maxBytes: 16 * 1024,
      });

      expect(result.userTurnCount).toBe(2);
      expect(result.bytesRead).toBeLessThanOrEqual(16 * 1024);
      expect(result.bytesRead).toBeLessThan(statSync(jsonlPath).size / 100);
      expect(result.messages.map(textOf)).toEqual([
        "recent question two",
        "recent answer two",
        "loaded skill context",
        "recent question three",
        "recent answer three",
      ]);
      expect(result.messages[2].isMeta).toBe(true);
      expect(result.hasMore).toBe(true);
      expect(result.nextCursor).toEqual(expect.any(String));
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("advances an opaque cursor through older pages without overlap", async () => {
    const directory = mkdtempSync(join(tmpdir(), "claude-tail-pages-"));
    const jsonlPath = join(directory, "history.jsonl");
    try {
      writeFileSync(
        jsonlPath,
        [
          userLine("1", "question one"),
          assistantLine("1", "answer one"),
          userLine("2", "question two"),
          assistantLine("2", "answer two"),
          userLine("3", "question three"),
          assistantLine("3", "answer three"),
          userLine("4", "question four"),
          assistantLine("4", "answer four"),
        ].join("\n"),
      );

      const newest = await readClaudeJsonlHistoryWindow(jsonlPath, {
        maxUserTurns: 2,
        maxBytes: 64 * 1024,
      });
      expect(newest.messages.map(textOf)).toEqual([
        "question three",
        "answer three",
        "question four",
        "answer four",
      ]);
      expect(newest.nextCursor).not.toBeNull();

      const older = await readClaudeJsonlHistoryWindow(jsonlPath, {
        cursor: newest.nextCursor!,
        maxUserTurns: 2,
        maxBytes: 64 * 1024,
      });
      expect(older.messages.map(textOf)).toEqual([
        "question one",
        "answer one",
        "question two",
        "answer two",
      ]);
      expect(older.userTurnCount).toBe(2);
      expect(older.hasMore).toBe(false);
      expect(older.nextCursor).toBeNull();

      const uuids = [...newest.messages, ...older.messages]
        .map((message) => message.uuid)
        .filter(Boolean);
      expect(new Set(uuids).size).toBe(uuids.length);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("skips an over-budget line while every cursor continues toward older data", async () => {
    const directory = mkdtempSync(join(tmpdir(), "claude-tail-oversized-"));
    const jsonlPath = join(directory, "history.jsonl");
    try {
      writeFileSync(
        jsonlPath,
        [
          userLine("1", "oldest question"),
          assistantLine("1", "oldest answer"),
          `{\"type\":\"progress\",\"payload\":\"${"x".repeat(4096)}\"}`,
          userLine("2", "latest question"),
          assistantLine("2", "latest answer"),
        ].join("\n"),
      );

      let page = await readClaudeJsonlHistoryWindow(jsonlPath, {
        maxUserTurns: 2,
        maxBytes: 256,
      });
      const cursors = new Set<string>();
      const observedTexts = page.messages.map(textOf);

      for (let pageIndex = 0; page.hasMore && pageIndex < 32; pageIndex += 1) {
        expect(page.bytesRead).toBeLessThanOrEqual(256);
        expect(page.nextCursor).not.toBeNull();
        expect(cursors.has(page.nextCursor!)).toBe(false);
        cursors.add(page.nextCursor!);
        page = await readClaudeJsonlHistoryWindow(jsonlPath, {
          cursor: page.nextCursor!,
          maxUserTurns: 2,
          maxBytes: 256,
        });
        observedTexts.push(...page.messages.map(textOf));
      }

      expect(page.hasMore).toBe(false);
      expect(observedTexts).toContain("latest question");
      expect(observedTexts).toContain("latest answer");
      expect(observedTexts).toContain("oldest question");
      expect(observedTexts).toContain("oldest answer");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("rejects malformed cursors and cursors from a different file", async () => {
    const directory = mkdtempSync(join(tmpdir(), "claude-tail-cursor-"));
    const firstPath = join(directory, "first.jsonl");
    const secondPath = join(directory, "second.jsonl");
    try {
      const history = [
        userLine("1", "first question"),
        assistantLine("1", "first answer"),
        userLine("2", "second question"),
        assistantLine("2", "second answer"),
      ].join("\n");
      writeFileSync(firstPath, history);
      writeFileSync(secondPath, history);

      await expect(
        readClaudeJsonlHistoryWindow(firstPath, {
          cursor: "not-a-valid-cursor",
        }),
      ).rejects.toThrow("Invalid Claude history cursor");
      await expect(
        readClaudeJsonlHistoryWindow(firstPath, { cursor: "" }),
      ).rejects.toThrow("Invalid Claude history cursor");

      const firstPage = await readClaudeJsonlHistoryWindow(firstPath, {
        maxUserTurns: 1,
        maxBytes: 64 * 1024,
      });
      expect(firstPage.nextCursor).not.toBeNull();
      await expect(
        readClaudeJsonlHistoryWindow(secondPath, {
          cursor: firstPage.nextCursor!,
        }),
      ).rejects.toThrow("Invalid Claude history cursor");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
