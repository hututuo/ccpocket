/**
 * Compatibility-only presentation helpers for Codex Desktop JSONL history.
 *
 * App-server ThreadItems already carry structured commandActions. Desktop
 * rollouts can instead persist a generic `exec` wrapper around the real tool,
 * so this module recovers a conservative semantic label without executing or
 * evaluating the recorded JavaScript. Keep this parser separate from the
 * canonical session index so future upstream schemas can replace it cleanly.
 */

export interface CodexHistoryToolDescriptor {
  name: string;
  input: Record<string, unknown>;
}

export function describeCodexDesktopToolCall(
  rawName: string,
  rawInput: unknown,
): CodexHistoryToolDescriptor {
  const parsedInput = parseObjectLike(rawInput);
  if (rawName !== "exec") {
    const name = normalizeCodexToolName(rawName);
    if (name === "Bash") {
      const command =
        stringValue(parsedInput.command) ?? stringValue(parsedInput.cmd) ?? "";
      return describeShellCommand(command, parsedInput);
    }
    return { name, input: parsedInput };
  }

  const script = typeof rawInput === "string" ? rawInput : "";
  const nestedTools = [
    ...script.matchAll(/\btools\.([A-Za-z0-9_]+)\s*\(/g),
  ].map((match) => match[1]);
  const uniqueTools = [...new Set(nestedTools)];
  if (uniqueTools.length === 1) {
    const nestedName = uniqueTools[0];
    if (nestedName === "exec_command") {
      const command = extractJavaScriptStringProperty(script, "cmd") ?? "";
      const cwd = extractJavaScriptStringProperty(script, "workdir");
      return describeShellCommand(command, {
        command,
        ...(cwd ? { cwd } : {}),
        script,
      });
    }
    const mapped = normalizeCodexToolName(nestedName);
    if (mapped !== nestedName) return { name: mapped, input: { script } };
    if (nestedName === "web__run") {
      return { name: "WebSearch", input: { script } };
    }
    if (nestedName === "read_mcp_resource") {
      return { name: "Read", input: { script } };
    }
    if (
      nestedName === "list_mcp_resources" ||
      nestedName === "list_mcp_resource_templates"
    ) {
      return { name: "ListFiles", input: { script } };
    }
  }

  if (uniqueTools.length > 1) {
    return { name: "MultiCommand", input: { script, tools: uniqueTools } };
  }
  return { name: "Bash", input: { script } };
}

export function codexDesktopToolOutputText(output: unknown): string {
  if (typeof output === "string") return output;
  if (Array.isArray(output)) {
    return output
      .map((entry) => {
        const item = asRecord(entry);
        if (!item) return typeof entry === "string" ? entry : "";
        return stringValue(item.text) ?? jsonText(item);
      })
      .filter(Boolean)
      .join("\n");
  }
  const item = asRecord(output);
  return item ? jsonText(item) : String(output ?? "");
}

export function formatCodexFileChanges(changes: unknown): string {
  if (!Array.isArray(changes) || changes.length === 0) {
    return "No file changes";
  }

  return changes
    .map((entry) => {
      const change = asRecord(entry);
      if (!change) return "changed";
      const kind = stringValue(change.kind) ?? "changed";
      const path = stringValue(change.path) ?? "(unknown)";
      const diff = stringValue(change.diff)?.trim();
      if (!diff) return `${kind}: ${path}`;
      if (diff.startsWith("---") || diff.startsWith("@@")) {
        return `--- a/${path}\n+++ b/${path}\n${diff}`;
      }
      return diff;
    })
    .join("\n\n");
}

function normalizeCodexToolName(name: string): string {
  if (name === "exec_command" || name === "write_stdin") return "Bash";
  switch (name) {
    case "apply_patch":
      return "FileChange";
    case "view_image":
      return "ViewImage";
    case "wait":
      return "Wait";
    case "wait_agent":
      return "WaitForAgents";
    case "spawn_agent":
      return "SpawnAgent";
    case "send_message":
    case "followup_task":
      return "SendAgentInput";
    case "interrupt_agent":
      return "CloseAgent";
    case "list_agents":
      return "SubAgentActivity";
  }
  if (name.startsWith("mcp__")) {
    const [server, ...toolParts] = name.slice("mcp__".length).split("__");
    if (server && toolParts.length > 0) {
      return `mcp:${server}/${toolParts.join("__")}`;
    }
  }
  return name;
}

function describeShellCommand(
  command: string,
  originalInput: Record<string, unknown>,
): CodexHistoryToolDescriptor {
  const normalized = command.trim();
  const lower = normalized.toLowerCase();
  const commandCount = normalized
    .split(/\n|&&|;/)
    .map((part) => part.trim())
    .filter(Boolean).length;
  if (commandCount > 1) {
    return {
      name: "MultiCommand",
      input: { ...originalInput, command: normalized },
    };
  }

  const path = extractLikelyCommandPath(normalized);
  if (
    /(^|[|&(]\s*)(rg|grep|egrep|fgrep)\b/.test(lower) ||
    /\bxargs\s+(rg|grep|egrep|fgrep)\b/.test(lower)
  ) {
    return {
      name: "Search",
      input: { ...originalInput, command: normalized, ...(path ? { path } : {}) },
    };
  }
  if (/^\s*(ls|tree|find|fd)\b/.test(lower)) {
    return {
      name: "ListFiles",
      input: { ...originalInput, command: normalized, ...(path ? { path } : {}) },
    };
  }
  if (
    /^\s*(cat|head|tail|less|bat|wc)\b/.test(lower) ||
    /^\s*sed\s+-n\b/.test(lower)
  ) {
    const readsSkill = path?.toLowerCase().endsWith("/skill.md") === true;
    return {
      name: readsSkill ? "ReadSkill" : "Read",
      input: {
        ...originalInput,
        command: normalized,
        ...(path ? { file_path: path } : {}),
        ...(readsSkill && path
          ? { skill: path.split(/[\\/]/).filter(Boolean).at(-2) ?? "Skill" }
          : {}),
      },
    };
  }
  return { name: "Bash", input: { ...originalInput, command: normalized } };
}

function extractJavaScriptStringProperty(
  source: string,
  property: string,
): string | undefined {
  const match = source.match(
    new RegExp(
      `(?:["']${property}["']|\\b${property})\\s*:\\s*("(?:\\\\.|[^"\\\\])*")`,
    ),
  );
  if (!match) return undefined;
  try {
    return JSON.parse(match[1]) as string;
  } catch {
    return undefined;
  }
}

function extractLikelyCommandPath(command: string): string | undefined {
  const candidates = [
    ...command.matchAll(/(?:^|\s)(?:"([^"]+)"|'([^']+)'|([^\s|;&]+))/g),
  ]
    .map((match) => match[1] ?? match[2] ?? match[3] ?? "")
    .filter(
      (value) =>
        value.startsWith("/") ||
        value.startsWith("./") ||
        value.startsWith("../") ||
        /\.[A-Za-z0-9]{1,8}$/.test(value),
    );
  return candidates.at(-1);
}

function parseObjectLike(value: unknown): Record<string, unknown> {
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value) as unknown;
      return asRecord(parsed) ?? { value: parsed };
    } catch {
      return { value };
    }
  }
  return asRecord(value) ?? {};
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function jsonText(value: unknown): string {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}
