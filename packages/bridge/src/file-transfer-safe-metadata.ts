import { constants as fsConstants } from "node:fs";
import { lstat, open } from "node:fs/promises";

/**
 * Reads small transfer metadata from a pinned descriptor. The lexical path
 * must continue to name that exact regular file before and after the bounded
 * read; callers decide whether an unsafe/missing file is fatal or a fallback.
 */
export async function readBoundedNoFollowMetadata(
  path: string,
  maxBytes: number,
  label: string,
): Promise<string> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new Error(`${label} has an invalid read limit`);
  }
  if (typeof fsConstants.O_NOFOLLOW !== "number") {
    throw new Error(`${label} cannot be read safely on this platform`);
  }
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(
      path,
      fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW,
    );
    const opened = await handle.stat();
    const lexical = await lstat(path);
    if (
      !opened.isFile() ||
      !lexical.isFile() ||
      lexical.isSymbolicLink() ||
      opened.dev !== lexical.dev ||
      opened.ino !== lexical.ino ||
      opened.size !== lexical.size
    ) {
      throw new Error(`${label} must be a pinned regular file`);
    }
    if (
      !Number.isSafeInteger(opened.size) ||
      opened.size < 0 ||
      opened.size > maxBytes
    ) {
      throw new Error(`${label} exceeds ${maxBytes} bytes`);
    }

    const buffer = Buffer.allocUnsafe(opened.size + 1);
    let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await handle.read(
        buffer,
        offset,
        buffer.length - offset,
        null,
      );
      if (bytesRead === 0) break;
      offset += bytesRead;
      if (offset > opened.size) {
        throw new Error(`${label} changed while loading`);
      }
    }
    if (offset !== opened.size) {
      throw new Error(`${label} changed while loading`);
    }

    const after = await handle.stat();
    const published = await lstat(path);
    if (
      !after.isFile() ||
      !published.isFile() ||
      published.isSymbolicLink() ||
      after.dev !== opened.dev ||
      after.ino !== opened.ino ||
      after.size !== opened.size ||
      published.dev !== opened.dev ||
      published.ino !== opened.ino ||
      published.size !== opened.size
    ) {
      throw new Error(`${label} changed while loading`);
    }
    return buffer.subarray(0, offset).toString("utf8");
  } catch (error) {
    if (nodeCode(error) === "ELOOP") {
      throw new Error(`${label} must not be a symbolic link`, { cause: error });
    }
    throw error;
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

function nodeCode(error: unknown): string | undefined {
  if (!error || typeof error !== "object" || !("code" in error)) {
    return undefined;
  }
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" ? code : undefined;
}
