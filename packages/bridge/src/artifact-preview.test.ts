import { describe, expect, it } from "vitest";
import {
  escapeHtml,
  mimeTypeForFilename,
  previewKindForFile,
  renderArtifactPreviewHtml,
} from "./artifact-preview.js";

describe("artifact preview types", () => {
  it.each([
    ["report.pdf", "application/pdf", "pdf"],
    ["photo.png", "image/png", "image"],
    ["notes.md", "text/markdown", "text"],
    ["voice.m4a", "audio/mp4", "audio"],
    ["clip.mov", "video/quicktime", "video"],
    ["report.docx", "application/octet-stream", "docx"],
    ["table.xlsx", "application/octet-stream", "office"],
    ["archive.zip", "application/zip", "unsupported"],
  ])("classifies %s as %s", (filename, mimeType, expected) => {
    expect(previewKindForFile(filename, mimeType)).toBe(expected);
  });

  it("uses a safe fallback MIME type", () => {
    expect(mimeTypeForFilename("unknown.bin")).toBe(
      "application/octet-stream",
    );
  });
});

describe("renderArtifactPreviewHtml", () => {
  const baseModel = {
    token: "A".repeat(43),
    filename: "report.pdf",
    mimeType: "application/pdf",
    sizeBytes: 1234,
    expiresAt: "2026-07-16T02:00:00.000Z",
  };

  it("renders preview and download actions", () => {
    const html = renderArtifactPreviewHtml(baseModel);

    expect(html).toContain(`/artifacts/${baseModel.token}/content`);
    expect(html).toContain(`/artifacts/${baseModel.token}/download`);
    expect(html).toContain("viewport-fit=cover");
  });

  it("escapes text preview content", () => {
    const html = renderArtifactPreviewHtml({
      ...baseModel,
      filename: "payload.txt",
      mimeType: "text/plain",
      textPreview: '<script>alert("x")</script>',
    });

    expect(html).toContain("&lt;script&gt;");
    expect(html).not.toContain('<script>alert("x")</script>');
  });

  it("loads only local scripts for DOCX previews", () => {
    const html = renderArtifactPreviewHtml({
      ...baseModel,
      filename: "报告.docx",
      mimeType:
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    });

    expect(html).toContain('/artifacts/assets/docx-preview.min.js');
    expect(html).toContain('/artifacts/assets/docx-viewer.js');
    expect(html).not.toContain("https://");
  });

  it("can fall back from DOCX rendering for large files", () => {
    const html = renderArtifactPreviewHtml({
      ...baseModel,
      filename: "large.docx",
      mimeType:
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      previewKind: "office",
    });

    expect(html).not.toContain("docx-preview.min.js");
    expect(html).toContain("系统文档预览");
  });

  it("escapes HTML metacharacters", () => {
    expect(escapeHtml('<>&"\'')).toBe("&lt;&gt;&amp;&quot;&#39;");
  });
});
