import { describe, expect, it } from "vitest";
import {
  createPathArtifactCandidate,
  extractArtifactCandidates,
  localPathFromArtifactHref,
  MAX_ARTIFACT_MARKDOWN_CHARS,
} from "./artifact-candidates.js";

describe("extractArtifactCandidates", () => {
  it("extracts angle-wrapped, encoded, relative, and image paths", () => {
    const markdown = [
      "[report](</Users/test/My Files/报告.pdf>)",
      "[source](/Users/test/%E6%BA%90%E7%A0%81.ts:12:3)",
      "[relative](./build/result.zip)",
      "![preview](file:///Users/test/My%20Files/chart.png)",
    ].join("\n");

    expect(
      extractArtifactCandidates(markdown, { textContentIndex: 2 }),
    ).toEqual([
      expect.objectContaining({
        linkKind: "link",
        localPath: "/Users/test/My Files/报告.pdf",
        originalHref: "/Users/test/My Files/报告.pdf",
        textContentIndex: 2,
      }),
      expect.objectContaining({
        localPath: "/Users/test/源码.ts:12:3",
        originalHref: "/Users/test/%E6%BA%90%E7%A0%81.ts:12:3",
      }),
      expect.objectContaining({ localPath: "./build/result.zip" }),
      expect.objectContaining({
        linkKind: "image",
        localPath: "/Users/test/My Files/chart.png",
      }),
    ]);
  });

  it("skips links inside fenced and inline code", () => {
    const markdown = [
      "```md",
      "[secret](/Users/test/secret.txt)",
      "```",
      "`[also-secret](/Users/test/also-secret.txt)`",
      "[safe](/Users/test/safe.txt)",
    ].join("\n");

    expect(extractArtifactCandidates(markdown)).toEqual([
      expect.objectContaining({ localPath: "/Users/test/safe.txt" }),
    ]);
  });

  it("rejects remote, data, sandbox, fragment, and unknown schemes", () => {
    const markdown = [
      "[web](https://example.com/a.pdf)",
      "[data](data:text/plain;base64,QQ==)",
      "[sandbox](sandbox:/mnt/data/file.pdf)",
      "[mail](mailto:test@example.com)",
      "[fragment](#section)",
      "[custom](vscode://file/Users/test/file.ts)",
      "[unknown](foo:bar)",
      "[local](/Users/test/file.pdf)",
    ].join("\n");

    expect(
      extractArtifactCandidates(markdown).map((item) => item.localPath),
    ).toEqual(["/Users/test/file.pdf"]);
  });

  it("deduplicates the same rendered target without merging link and image", () => {
    const markdown = [
      "[one](/tmp/result.pdf)",
      "[two](/tmp/result.pdf)",
      "![image](/tmp/result.pdf)",
    ].join("\n");

    const candidates = extractArtifactCandidates(markdown);
    expect(candidates).toHaveLength(2);
    expect(candidates.map((candidate) => candidate.linkKind)).toEqual([
      "link",
      "image",
    ]);
  });

  it("restores a standard Markdown UNC target after marked unescapes it", () => {
    const [candidate] = extractArtifactCandidates(
      String.raw`[network file](\\server\share\报告.txt)`,
      { platform: "win32" },
    );
    expect(candidate).toMatchObject({
      localPath: String.raw`\\server\share\报告.txt`,
      // Keep marked's rendered href for exact matching on the client.
      originalHref: String.raw`\server\share\报告.txt`,
    });
  });

  it("caps one Markdown message at 64 candidates", () => {
    const markdown = Array.from(
      { length: 80 },
      (_, index) => `[file ${index}](/tmp/file-${index}.txt)`,
    ).join("\n");
    const candidates = extractArtifactCandidates(markdown);
    expect(candidates).toHaveLength(64);
    expect(candidates.at(-1)?.localPath).toBe("/tmp/file-63.txt");
  });

  it("skips AST extraction for oversized messages without changing the text", () => {
    const markdown = `${"x".repeat(MAX_ARTIFACT_MARKDOWN_CHARS)}[file](/tmp/file.txt)`;
    const original = markdown.slice();
    expect(extractArtifactCandidates(markdown)).toEqual([]);
    expect(markdown).toBe(original);
  });
});

describe("localPathFromArtifactHref", () => {
  it("supports Windows drive, UNC, and file URL paths", () => {
    expect(localPathFromArtifactHref("C:\\Work\\报告.pdf", "win32")).toBe(
      "C:\\Work\\报告.pdf",
    );
    expect(
      localPathFromArtifactHref("\\\\server\\share\\file.txt", "win32"),
    ).toBe("\\\\server\\share\\file.txt");
    expect(
      localPathFromArtifactHref("file:///C:/Work/My%20File.txt", "win32"),
    ).toBe("C:\\Work\\My File.txt");
    expect(
      localPathFromArtifactHref("file://server/share/file.txt", "win32"),
    ).toBe("\\\\server\\share\\file.txt");
  });

  it("accepts localhost file URLs and rejects remote POSIX hosts", () => {
    expect(
      localPathFromArtifactHref("file://localhost/tmp/a%20b.txt", "darwin"),
    ).toBe("/tmp/a b.txt");
    expect(
      localPathFromArtifactHref("file://server/tmp/a.txt", "darwin"),
    ).toBeUndefined();
  });

  it("fails closed for malformed encoding, encoded separators, and NUL", () => {
    expect(localPathFromArtifactHref("/tmp/%ZZ.txt")).toBeUndefined();
    expect(localPathFromArtifactHref("/tmp/a%2Fb.txt")).toBeUndefined();
    expect(localPathFromArtifactHref("/tmp/a%00b.txt")).toBeUndefined();
    expect(localPathFromArtifactHref("/tmp/a%252Fb.txt")).toBeUndefined();
    expect(localPathFromArtifactHref("/tmp/a%2500b.txt")).toBeUndefined();
  });
});

describe("createPathArtifactCandidate", () => {
  it("creates a structured generated-image candidate", () => {
    expect(
      createPathArtifactCandidate("/tmp/生成 图.png", {
        source: "image_generation",
      }),
    ).toEqual({
      source: "image_generation",
      linkKind: "generated",
      localPath: "/tmp/生成 图.png",
      label: undefined,
      textContentIndex: undefined,
    });
  });
});
