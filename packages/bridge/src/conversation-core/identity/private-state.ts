import { constants } from "node:fs";
import { randomUUID } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  open,
  realpath,
  rename,
  rm,
} from "node:fs/promises";
import { dirname, resolve } from "node:path";

const PRIVATE_DIRECTORY_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
const LOCK_ATTEMPTS = 400;
const LOCK_RETRY_MS = 5;

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException).code === "ENOENT";
}

function modeOf(mode: number): number {
  return mode & 0o777;
}

async function pause(milliseconds: number): Promise<void> {
  await new Promise((resolvePause) => setTimeout(resolvePause, milliseconds));
}

export async function preparePrivateStateDirectory(path: string): Promise<string> {
  const absolutePath = resolve(path);
  await mkdir(absolutePath, { recursive: true, mode: PRIVATE_DIRECTORY_MODE });
  const before = await lstat(absolutePath);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error("Conversation identity state directory must be a real directory");
  }
  await chmod(absolutePath, PRIVATE_DIRECTORY_MODE);
  const after = await lstat(absolutePath);
  if (
    after.isSymbolicLink() ||
    !after.isDirectory() ||
    (process.platform !== "win32" && modeOf(after.mode) !== PRIVATE_DIRECTORY_MODE)
  ) {
    throw new Error("Conversation identity state directory is not private");
  }
  return realpath(absolutePath);
}

export async function readBoundedPrivateFile(
  path: string,
  maximumBytes: number,
  description: string,
): Promise<string | undefined> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    try {
      const stats = await lstat(path);
      if (stats.isSymbolicLink() || !stats.isFile()) {
        throw new Error(`${description} must be a private regular file`);
      }
    } catch (error) {
      if (isMissing(error)) return undefined;
      throw error;
    }

    try {
      handle = await open(
        path,
        constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0),
      );
    } catch (error) {
      if (isMissing(error)) return undefined;
      throw new Error(`${description} cannot be opened safely`, { cause: error });
    }

    const before = await handle.stat();
    if (!before.isFile()) {
      throw new Error(`${description} must be a private regular file`);
    }
    if (before.size > maximumBytes) {
      throw new Error(`${description} exceeds its size limit`);
    }

    await handle.chmod(PRIVATE_FILE_MODE);
    const secured = await handle.stat();
    if (
      !secured.isFile() ||
      (process.platform !== "win32" && modeOf(secured.mode) !== PRIVATE_FILE_MODE)
    ) {
      throw new Error(`${description} is not private`);
    }

    const contents = Buffer.alloc(maximumBytes + 1);
    let offset = 0;
    while (offset < contents.length) {
      const result = await handle.read(
        contents,
        offset,
        contents.length - offset,
        offset,
      );
      if (result.bytesRead === 0) break;
      offset += result.bytesRead;
    }
    if (offset > maximumBytes) {
      throw new Error(`${description} exceeds its size limit`);
    }
    return contents.subarray(0, offset).toString("utf8");
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

async function syncDirectory(path: string): Promise<void> {
  const handle = await open(path, constants.O_RDONLY);
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

export async function atomicPrivateWrite(
  path: string,
  contents: string,
  maximumBytes: number,
  description: string,
): Promise<void> {
  if (Buffer.byteLength(contents, "utf8") > maximumBytes) {
    throw new Error(`${description} exceeds its size limit`);
  }

  const directory = dirname(path);
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(temporary, "wx", PRIVATE_FILE_MODE);
    await handle.writeFile(contents, "utf8");
    await handle.chmod(PRIVATE_FILE_MODE);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporary, path);
    await syncDirectory(directory);
  } finally {
    await handle?.close().catch(() => undefined);
    await rm(temporary, { force: true }).catch(() => undefined);
  }
}

export async function acquireStateMutationLock(
  stateFile: string,
  description: string,
): Promise<() => Promise<void>> {
  const lockPath = `${stateFile}.lock`;
  for (let attempt = 0; attempt < LOCK_ATTEMPTS; attempt += 1) {
    try {
      await mkdir(lockPath, { mode: PRIVATE_DIRECTORY_MODE });
      let released = false;
      return async () => {
        if (released) return;
        released = true;
        await rm(lockPath, { recursive: true, force: true });
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      await pause(LOCK_RETRY_MS);
    }
  }
  throw new Error(`${description} is busy`);
}
