import type { FileHandle } from "node:fs/promises";
import { open } from "node:fs/promises";
import type { ServerResponse } from "node:http";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import {
  ARTIFACT_PREVIEW_CONTROLS_SCRIPT,
  DOCX_VIEWER_SCRIPT,
} from "./artifact-preview.js";
import { sendArtifactText } from "./artifact-content.js";

export const ARTIFACT_ASSET_PATTERN =
  /^\/artifacts\/assets\/(jszip\.min\.js|docx-preview\.min\.js|docx-viewer\.js|preview-controls\.v1\.js)$/;

function assetPath(name: string): string {
  const require = createRequire(import.meta.url);
  if (name === "docx-preview.min.js") {
    return join(dirname(require.resolve("docx-preview")), name);
  }
  return join(dirname(dirname(require.resolve("jszip"))), "dist", name);
}

export async function serveArtifactAsset(
  name: string,
  headOnly: boolean,
  res: ServerResponse,
): Promise<void> {
  const generatedScript =
    name === "docx-viewer.js"
      ? DOCX_VIEWER_SCRIPT
      : name === "preview-controls.v1.js"
        ? ARTIFACT_PREVIEW_CONTROLS_SCRIPT
        : undefined;
  if (generatedScript !== undefined) {
    const buffer = Buffer.from(generatedScript);
    res.writeHead(200, {
      "Content-Type": "text/javascript; charset=utf-8",
      "Content-Length": buffer.length,
      "Cache-Control": "public, max-age=31536000, immutable",
      "X-Content-Type-Options": "nosniff",
    });
    res.end(headOnly ? undefined : buffer);
    return;
  }

  let handle: FileHandle | undefined;
  try {
    handle = await open(assetPath(name), "r");
    const stats = await handle.stat();
    res.writeHead(200, {
      "Content-Type": "text/javascript; charset=utf-8",
      "Content-Length": stats.size,
      "Cache-Control": "public, max-age=31536000, immutable",
      "X-Content-Type-Options": "nosniff",
    });
    if (headOnly) {
      await handle.close();
      handle = undefined;
      res.end();
      return;
    }

    const stream = handle.createReadStream({ autoClose: true });
    handle = undefined;
    res.once("close", () => {
      if (!res.writableEnded) stream.destroy();
    });
    stream.once("error", (error) => res.destroy(error));
    stream.pipe(res);
  } catch (error) {
    if (handle) await handle.close().catch(() => undefined);
    if (!res.headersSent) sendArtifactText(res, 404, "Not Found");
    else res.destroy(error instanceof Error ? error : undefined);
  }
}
