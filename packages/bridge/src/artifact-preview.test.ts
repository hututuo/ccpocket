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
    ["page.html", "text/html", "html"],
    ["page.htm", "application/octet-stream", "html"],
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

  it("renders share, download, and collapsible preview controls", () => {
    const html = renderArtifactPreviewHtml(baseModel);

    expect(html).toContain(`/artifacts/${baseModel.token}/content`);
    expect(html).toContain(`/artifacts/${baseModel.token}/download`);
    expect(html).toContain('id="share-artifact"');
    expect(html).toContain('id="hide-toolbar"');
    expect(html).toContain('id="show-toolbar"');
    expect(html).toContain('/artifacts/assets/preview-controls.v1.js');
    expect(html).not.toContain('>打开原文件<');
    expect(html).toContain("viewport-fit=cover");
  });

  it("omits browser controls from embedded previews", () => {
    const standalone = renderArtifactPreviewHtml(baseModel);
    const embedded = renderArtifactPreviewHtml({
      ...baseModel,
      embedded: true,
    });

    expect(standalone).toContain('class="shell"');
    expect(embedded).toContain('class="shell embedded"');
    expect(standalone).toContain('id="artifact-toolbar"');
    expect(standalone).toContain('preview-controls.v1.js');
    expect(embedded).not.toContain('id="artifact-toolbar"');
    expect(embedded).not.toContain('preview-controls.v1.js');
    expect(embedded).not.toContain('id="artifact-toast"');
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

  it("routes local HTML through the isolated artifact sandbox", () => {
    const html = renderArtifactPreviewHtml({
      ...baseModel,
      filename: "page.html",
      mimeType: "text/html; charset=utf-8",
    });

    expect(html).toContain(`/artifacts/${baseModel.token}/sandbox`);
    expect(html).toContain('sandbox="allow-scripts"');
    expect(html).toContain('referrerpolicy="no-referrer"');
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
