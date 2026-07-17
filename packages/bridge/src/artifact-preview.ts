import { extname } from "node:path";

export type ArtifactPreviewKind =
  | "image"
  | "pdf"
  | "text"
  | "audio"
  | "video"
  | "docx"
  | "office"
  | "unsupported";

export interface ArtifactPreviewModel {
  token: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  expiresAt: string;
  embedded?: boolean;
  textPreview?: string;
  textPreviewTruncated?: boolean;
  previewKind?: ArtifactPreviewKind;
}

const MIME_TYPES: Record<string, string> = {
  ".aac": "audio/aac",
  ".avi": "video/x-msvideo",
  ".bmp": "image/bmp",
  ".csv": "text/csv; charset=utf-8",
  ".doc": "application/msword",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".gif": "image/gif",
  ".heic": "image/heic",
  ".html": "text/html; charset=utf-8",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".log": "text/plain; charset=utf-8",
  ".m4a": "audio/mp4",
  ".md": "text/markdown; charset=utf-8",
  ".mov": "video/quicktime",
  ".mp3": "audio/mpeg",
  ".mp4": "video/mp4",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".ppt": "application/vnd.ms-powerpoint",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".py": "text/x-python; charset=utf-8",
  ".rtf": "application/rtf",
  ".sh": "text/x-shellscript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".swift": "text/x-swift; charset=utf-8",
  ".ts": "text/typescript; charset=utf-8",
  ".tsv": "text/tab-separated-values; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".wav": "audio/wav",
  ".webm": "video/webm",
  ".webp": "image/webp",
  ".xls": "application/vnd.ms-excel",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".xml": "application/xml; charset=utf-8",
  ".yaml": "text/yaml; charset=utf-8",
  ".yml": "text/yaml; charset=utf-8",
  ".zip": "application/zip",
};

const TEXT_EXTENSIONS = new Set([
  ".c",
  ".cc",
  ".conf",
  ".cpp",
  ".css",
  ".csv",
  ".dart",
  ".go",
  ".h",
  ".hpp",
  ".html",
  ".ini",
  ".java",
  ".js",
  ".json",
  ".jsx",
  ".kt",
  ".log",
  ".md",
  ".mjs",
  ".php",
  ".plist",
  ".py",
  ".rb",
  ".rs",
  ".sh",
  ".sql",
  ".swift",
  ".toml",
  ".ts",
  ".tsx",
  ".tsv",
  ".txt",
  ".vue",
  ".xml",
  ".yaml",
  ".yml",
]);

const OFFICE_EXTENSIONS = new Set([
  ".doc",
  ".ppt",
  ".pptx",
  ".rtf",
  ".xls",
  ".xlsx",
]);

export function mimeTypeForFilename(filename: string): string {
  return MIME_TYPES[extname(filename).toLowerCase()] ?? "application/octet-stream";
}

export function previewKindForFile(
  filename: string,
  mimeType: string,
): ArtifactPreviewKind {
  const ext = extname(filename).toLowerCase();
  if (ext === ".docx") return "docx";
  if (OFFICE_EXTENSIONS.has(ext)) return "office";
  if (ext === ".pdf" || mimeType === "application/pdf") return "pdf";
  if (mimeType.startsWith("image/")) return "image";
  if (mimeType.startsWith("audio/")) return "audio";
  if (mimeType.startsWith("video/")) return "video";
  if (
    TEXT_EXTENSIONS.has(ext) ||
    mimeType.startsWith("text/") ||
    mimeType.startsWith("application/json") ||
    mimeType.startsWith("application/xml")
  ) {
    return "text";
  }
  return "unsupported";
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = units[0];
  for (let i = 1; i < units.length && value >= 1024; i += 1) {
    value /= 1024;
    unit = units[i];
  }
  const digits = value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(digits)} ${unit}`;
}

function previewBody(model: ArtifactPreviewModel): string {
  const basePath = `/artifacts/${model.token}`;
  const contentUrl = `${basePath}/content`;
  const filename = escapeHtml(model.filename);
  const kind =
    model.previewKind ?? previewKindForFile(model.filename, model.mimeType);

  if (kind === "image") {
    return `<div class="stage image-stage"><img src="${contentUrl}" alt="${filename}"></div>`;
  }
  if (kind === "pdf") {
    return `<div class="stage frame-stage"><iframe src="${contentUrl}" title="${filename}"></iframe></div>`;
  }
  if (kind === "audio") {
    return `<div class="stage media-stage"><div class="file-glyph">♫</div><audio controls preload="metadata" src="${contentUrl}"></audio></div>`;
  }
  if (kind === "video") {
    return `<div class="stage media-stage"><video controls playsinline preload="metadata" src="${contentUrl}"></video></div>`;
  }
  if (kind === "docx") {
    return `<div class="stage docx-stage"><div id="docx-loading" class="loading">正在解析 Word 文档…</div><div id="docx-preview" data-source="${contentUrl}"></div></div>`;
  }
  if (kind === "text") {
    const text = escapeHtml(model.textPreview ?? "");
    const truncated = model.textPreviewTruncated
      ? `<div class="notice">预览只显示文件开头；下载可获得完整内容。</div>`
      : "";
    return `${truncated}<div class="stage text-stage"><pre><code>${text}</code></pre></div>`;
  }

  const message =
    kind === "office"
      ? "此格式可交给 iPhone 的系统文档预览打开。"
      : "浏览器暂不支持直接渲染此格式。";
  return `<div class="stage fallback-stage"><div class="file-glyph">⌑</div><h2>${escapeHtml(message)}</h2><p>文件仍保留在你的 Mac 上，链接过期后将无法访问。</p><a class="button secondary" href="${contentUrl}">使用系统预览打开</a></div>`;
}

function docxScripts(model: ArtifactPreviewModel): string {
  const kind =
    model.previewKind ?? previewKindForFile(model.filename, model.mimeType);
  if (kind !== "docx") return "";
  return `
  <script defer src="/artifacts/assets/jszip.min.js"></script>
  <script defer src="/artifacts/assets/docx-preview.min.js"></script>
  <script defer src="/artifacts/assets/docx-viewer.js"></script>`;
}

function previewControlsScript(model: ArtifactPreviewModel): string {
  if (model.embedded) return "";
  return `
  <script defer src="/artifacts/assets/preview-controls.v1.js"></script>`;
}

function previewToolbar(
  model: ArtifactPreviewModel,
  filename: string,
  mimeType: string,
  expires: string,
  downloadUrl: string,
): string {
  if (model.embedded) return "";
  return `<header class="toolbar" id="artifact-toolbar">
      <div class="identity"><h1>${filename}</h1><div class="meta">${escapeHtml(formatBytes(model.sizeBytes))} · ${mimeType} · ${expires} 过期</div></div>
      <button class="toolbar-icon" id="hide-toolbar" type="button" aria-label="隐藏工具栏" aria-controls="artifact-toolbar">⌃</button>
      <div class="actions"><button class="button secondary" id="share-artifact" type="button" data-filename="${filename}" data-expires="${expires}">分享</button><a class="button" id="download-artifact" href="${downloadUrl}">下载</a></div>
    </header>
    <button class="toolbar-reveal" id="show-toolbar" type="button" aria-label="显示工具栏" aria-controls="artifact-toolbar">⌄</button>`;
}

export function renderArtifactPreviewHtml(
  model: ArtifactPreviewModel,
): string {
  const filename = escapeHtml(model.filename);
  const downloadUrl = `/artifacts/${model.token}/download`;
  const expires = escapeHtml(new Date(model.expiresAt).toLocaleString("zh-CN"));
  const mimeType = escapeHtml(model.mimeType.split(";", 1)[0]);

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="color-scheme" content="light dark">
  <title>${filename} · CC Pocket</title>
  <style>
    :root { color-scheme: light dark; --bg:#f4f5f7; --panel:rgba(255,255,255,.88); --text:#17191c; --muted:#68707a; --line:rgba(24,28,34,.12); --accent:#246bfd; --stage:#e8eaee; }
    @media (prefers-color-scheme:dark) { :root { --bg:#111316; --panel:rgba(28,31,36,.9); --text:#f4f6f8; --muted:#9ca4ae; --line:rgba(255,255,255,.12); --accent:#79a7ff; --stage:#090a0c; } }
    * { box-sizing:border-box; }
    html, body { margin:0; min-height:100%; background:var(--bg); color:var(--text); font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif; }
    body { padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
    .shell { min-height:100vh; display:flex; flex-direction:column; }
    .toolbar { position:sticky; top:0; z-index:10; display:flex; gap:14px; align-items:center; padding:12px max(14px,4vw); border-bottom:1px solid var(--line); background:var(--panel); backdrop-filter:blur(18px); -webkit-backdrop-filter:blur(18px); }
    .identity { min-width:0; flex:1; }
    h1 { margin:0; font-size:16px; line-height:1.35; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .meta { margin-top:4px; color:var(--muted); font-size:12px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .actions { display:flex; gap:8px; }
    .button { display:inline-flex; align-items:center; justify-content:center; min-height:40px; padding:0 14px; border-radius:10px; text-decoration:none; font:650 14px/1 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif; background:var(--accent); color:white; border:1px solid transparent; cursor:pointer; }
    .button.secondary { color:var(--text); background:transparent; border-color:var(--line); }
    .button:disabled { opacity:.55; cursor:default; }
    .toolbar-icon { flex:0 0 40px; width:40px; min-height:40px; padding:0; border:1px solid var(--line); border-radius:10px; color:var(--text); background:transparent; font:700 20px/1 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif; cursor:pointer; }
    .toolbar-reveal { position:fixed; z-index:30; top:max(8px,env(safe-area-inset-top)); right:max(8px,env(safe-area-inset-right)); display:none; width:42px; height:42px; place-items:center; border:1px solid var(--line); border-radius:12px; color:var(--text); background:var(--panel); box-shadow:0 5px 22px rgba(0,0,0,.18); backdrop-filter:blur(18px); -webkit-backdrop-filter:blur(18px); font-size:20px; cursor:pointer; }
    .toolbar-hidden .toolbar { display:none; }
    .toolbar-hidden .toolbar-reveal { display:grid; }
    .toolbar-hidden main { padding:0; }
    .toolbar-hidden .stage { min-height:calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom)); border-width:0; border-radius:0; }
    .toolbar-hidden .frame-stage iframe { height:calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom)); border-radius:0; }
    .toolbar-hidden .docx-stage { padding:0; }
    .embedded main { padding:0; }
    .embedded .stage { min-height:100vh; border-width:0; border-radius:0; }
    .embedded .frame-stage iframe { height:100vh; border-radius:0; }
    .embedded .docx-stage { padding:0; }
    .toast { position:fixed; z-index:40; left:50%; bottom:max(18px,calc(env(safe-area-inset-bottom) + 10px)); transform:translateX(-50%); max-width:min(88vw,520px); padding:10px 14px; border-radius:11px; color:var(--text); background:var(--panel); border:1px solid var(--line); box-shadow:0 7px 24px rgba(0,0,0,.2); font-size:13px; text-align:center; }
    .toast[hidden] { display:none; }
    main { flex:1; min-height:0; display:flex; flex-direction:column; padding:14px; }
    .stage { flex:1; min-height:calc(100vh - 104px); overflow:auto; border:1px solid var(--line); border-radius:14px; background:var(--stage); }
    .image-stage { display:flex; align-items:center; justify-content:center; padding:18px; }
    .image-stage img { display:block; max-width:100%; max-height:calc(100vh - 140px); object-fit:contain; border-radius:6px; }
    .frame-stage iframe { display:block; width:100%; height:calc(100vh - 110px); border:0; border-radius:14px; background:white; }
    .media-stage { display:flex; flex-direction:column; gap:24px; align-items:center; justify-content:center; padding:32px; }
    .media-stage audio { width:min(640px,100%); }
    .media-stage video { width:min(1100px,100%); max-height:calc(100vh - 180px); border-radius:10px; background:black; }
    .file-glyph { width:76px; height:76px; display:grid; place-items:center; border-radius:20px; background:var(--panel); border:1px solid var(--line); font-size:34px; }
    .text-stage { min-height:0; background:var(--panel); }
    pre { margin:0; padding:18px; min-height:100%; overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; tab-size:2; font:13px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace; }
    .notice { margin:0 0 10px; padding:10px 12px; border:1px solid var(--line); border-radius:10px; color:var(--muted); font-size:13px; }
    .fallback-stage { display:flex; flex-direction:column; align-items:center; justify-content:center; gap:12px; padding:28px; text-align:center; }
    .fallback-stage h2 { margin:8px 0 0; font-size:18px; }
    .fallback-stage p { max-width:440px; margin:0 0 10px; color:var(--muted); line-height:1.6; }
    .docx-stage { padding:18px; background:#d8dbe0; }
    .loading { padding:28px; text-align:center; color:#545b64; }
    #docx-preview { min-height:200px; }
    #docx-preview .docx-wrapper { padding:14px 0 !important; background:transparent !important; }
    #docx-preview .docx { box-shadow:0 5px 24px rgba(0,0,0,.18) !important; }
    @media (max-width:640px) { .toolbar { align-items:center; flex-wrap:wrap; gap:8px; } .identity { flex:1 1 calc(100% - 96px); } .actions { order:3; width:100%; } .actions .button { flex:1; } main { padding:8px; } .stage { min-height:calc(100vh - 156px); border-radius:10px; } .frame-stage iframe { height:calc(100vh - 156px); } .docx-stage { padding:6px; } }
  </style>${docxScripts(model)}${previewControlsScript(model)}
</head>
<body>
  <div class="shell${model.embedded ? " embedded" : ""}" id="artifact-shell">
    ${previewToolbar(model, filename, mimeType, expires, downloadUrl)}
    <main>${previewBody(model)}</main>
    ${model.embedded ? "" : '<div class="toast" id="artifact-toast" role="status" aria-live="polite" hidden></div>'}
  </div>
</body>
</html>`;
}

export const DOCX_VIEWER_SCRIPT = `(() => {
  const container = document.getElementById("docx-preview");
  const loading = document.getElementById("docx-loading");
  if (!container || !window.docx) return;
  fetch(container.dataset.source, { credentials: "omit", cache: "no-store" })
    .then((response) => {
      if (!response.ok) throw new Error("HTTP " + response.status);
      return response.blob();
    })
    .then((blob) => window.docx.renderAsync(blob, container, container, {
      breakPages: true,
      ignoreLastRenderedPageBreak: false,
      useBase64URL: true,
    }))
    .then(() => { if (loading) loading.remove(); })
    .catch(() => {
      if (loading) loading.textContent = "Word 预览失败，请使用顶部的下载按钮。";
    });
})();`;

export const ARTIFACT_PREVIEW_CONTROLS_SCRIPT = `(() => {
  const shell = document.getElementById("artifact-shell");
  const hideButton = document.getElementById("hide-toolbar");
  const showButton = document.getElementById("show-toolbar");
  const shareButton = document.getElementById("share-artifact");
  const toast = document.getElementById("artifact-toast");
  let toastTimer;

  const setToolbarHidden = (hidden) => {
    if (!shell) return;
    shell.classList.toggle("toolbar-hidden", hidden);
    hideButton?.setAttribute("aria-expanded", String(!hidden));
  };

  const showToast = (message) => {
    if (!toast) return;
    toast.textContent = message;
    toast.hidden = false;
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => { toast.hidden = true; }, 2400);
  };

  const copyLink = async (url) => {
    if (window.isSecureContext && navigator.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(url);
        return true;
      } catch (_) {}
    }
    const input = document.createElement("textarea");
    input.value = url;
    input.setAttribute("readonly", "");
    input.style.position = "fixed";
    input.style.opacity = "0";
    document.body.appendChild(input);
    input.select();
    input.setSelectionRange(0, input.value.length);
    let copied = false;
    try { copied = document.execCommand("copy"); } catch (_) {}
    input.remove();
    return copied;
  };

  hideButton?.addEventListener("click", () => setToolbarHidden(true));
  showButton?.addEventListener("click", () => setToolbarHidden(false));

  shareButton?.addEventListener("click", async () => {
    const url = location.origin + location.pathname;
    const filename = shareButton.dataset.filename || document.title;
    const expires = shareButton.dataset.expires || "";
    if (typeof navigator.share === "function") {
      try {
        await navigator.share({
          title: filename,
          text: expires
            ? "CC Pocket 临时文件链接（" + expires + " 过期）"
            : "CC Pocket 临时文件链接",
          url,
        });
        return;
      } catch (error) {
        if (error?.name === "AbortError") return;
      }
    }
    showToast(await copyLink(url) ? "链接已复制，可粘贴分享" : "请从浏览器菜单分享此链接");
  });
})();`;
