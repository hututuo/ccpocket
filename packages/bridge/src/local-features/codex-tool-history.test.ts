import { describe, expect, it } from "vitest";
import {
  codexDesktopToolOutputText,
  describeCodexDesktopToolCall,
} from "./codex-tool-history.js";

describe("Codex Desktop history tool compatibility", () => {
  it.each([
    ["rg -n TODO apps/mobile", "Search"],
    ["ls -la apps/mobile", "ListFiles"],
    ["sed -n '1,80p' apps/mobile/pubspec.yaml", "Read"],
    ["git status --short", "Bash"],
  ])("classifies %s as %s", (command, expectedName) => {
    const descriptor = describeCodexDesktopToolCall(
      "exec",
      `const r = await tools.exec_command({cmd:${JSON.stringify(command)}}); text(r.output);`,
    );
    expect(descriptor.name).toBe(expectedName);
  });

  it("keeps background-terminal wait separate from sub-agent wait", () => {
    expect(describeCodexDesktopToolCall("wait", {}).name).toBe("Wait");
    expect(describeCodexDesktopToolCall("wait_agent", {}).name).toBe(
      "WaitForAgents",
    );
  });

  it("restores all textual output blocks in order", () => {
    expect(
      codexDesktopToolOutputText([
        { type: "input_text", text: "Script completed" },
        { type: "input_text", text: "result" },
      ]),
    ).toBe("Script completed\nresult");
  });
});
