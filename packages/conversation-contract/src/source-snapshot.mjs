import {constants as fsConstants} from 'node:fs';
import {
  chmod,
  lstat,
  mkdtemp,
  open,
  readdir,
  rm,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';

import {compareUtf16, digestBytes} from './canonical.mjs';
import {finishWithCleanup, runWithCleanup} from './cleanup.mjs';

const SOURCE_OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);

async function runHook(hooks, name, details) {
  if (hooks?.[name] !== undefined) await hooks[name](details);
}

function sameFileIdentity(left, right) {
  return left.dev === right.dev &&
    left.ino === right.ino &&
    left.mode === right.mode &&
    left.size === right.size &&
    left.mtimeNs === right.mtimeNs &&
    left.ctimeNs === right.ctimeNs;
}

async function readStableRegularFile(filename, hooks) {
  const lexicalBefore = await lstat(filename, {bigint: true});
  if (lexicalBefore.isSymbolicLink() || !lexicalBefore.isFile()) {
    throw new Error(`generator source must be a regular file: ${filename}`);
  }
  let handle;
  try {
    handle = await open(filename, SOURCE_OPEN_FLAGS);
  } catch (error) {
    throw new Error(`cannot bind generator source: ${filename}: ${error.message}`);
  }
  return runWithCleanup(async () => {
    await runHook(hooks, 'afterSourceHandleBound', {filename});
    const handleBefore = await handle.stat({bigint: true});
    if (!handleBefore.isFile() || !sameFileIdentity(lexicalBefore, handleBefore)) {
      throw new Error(`generator source changed while it was bound: ${filename}`);
    }
    const bytes = await handle.readFile();
    const handleAfter = await handle.stat({bigint: true});
    const lexicalAfter = await lstat(filename, {bigint: true});
    if (!handleAfter.isFile() ||
        lexicalAfter.isSymbolicLink() ||
        !lexicalAfter.isFile() ||
        !sameFileIdentity(handleBefore, handleAfter) ||
        !sameFileIdentity(handleAfter, lexicalAfter) ||
        BigInt(bytes.byteLength) !== handleAfter.size) {
      throw new Error(`generator source changed while it was read: ${filename}`);
    }
    return bytes;
  }, async () => {
    await handle.close();
    await runHook(hooks, 'afterSourceHandleClose', {filename});
  }, 'generator source read and handle cleanup both failed');
}

function sourceEntry(pathPrefix, filename, bytes) {
  return {
    path: `${pathPrefix}/${filename}`,
    byteLength: bytes.byteLength,
    sha256: digestBytes(bytes),
  };
}

export async function captureGeneratorSourceFiles(
  sourceDirectory,
  pathPrefix,
  {hooks} = {},
) {
  const entries = await readdir(sourceDirectory, {withFileTypes: true});
  const sourceEntries = entries
    .filter((entry) => entry.name.endsWith('.mjs'))
    .sort((left, right) => compareUtf16(left.name, right.name));
  if (sourceEntries.length === 0) {
    throw new Error(`generator source closure is empty: ${sourceDirectory}`);
  }
  const files = new Map();
  const catalog = [];
  for (const entry of sourceEntries) {
    if (entry.isSymbolicLink() || !entry.isFile()) {
      throw new Error(
        `generator source must be a regular file: ${path.join(sourceDirectory, entry.name)}`,
      );
    }
    const bytes = await readStableRegularFile(
      path.join(sourceDirectory, entry.name),
      hooks,
    );
    files.set(entry.name, bytes);
    catalog.push(sourceEntry(pathPrefix, entry.name, bytes));
  }
  return {catalog, files};
}

export async function verifyGeneratorSourceFiles(
  sourceDirectory,
  pathPrefix,
  expectedCatalog,
  {requireReadOnly = false, hooks} = {},
) {
  const actual = await captureGeneratorSourceFiles(sourceDirectory, pathPrefix, {
    hooks,
  });
  if (JSON.stringify(actual.catalog) !== JSON.stringify(expectedCatalog)) {
    throw new Error('generator source snapshot changed during execution');
  }
  if (requireReadOnly) {
    const directoryStatus = await lstat(sourceDirectory, {bigint: true});
    if ((directoryStatus.mode & 0o222n) !== 0n) {
      throw new Error('generator source snapshot directory must be read-only');
    }
    for (const filename of actual.files.keys()) {
      const status = await lstat(path.join(sourceDirectory, filename), {bigint: true});
      if ((status.mode & 0o222n) !== 0n) {
        throw new Error(`generator source snapshot file must be read-only: ${filename}`);
      }
    }
  }
}

async function disposeSnapshot(directory, hooks) {
  await chmod(directory, 0o700).catch(() => {});
  await rm(directory, {recursive: true, force: true});
  await runHook(hooks, 'afterSnapshotDispose', {directory});
}

export async function createGeneratorSourceSnapshot(
  sourceDirectory,
  pathPrefix,
  {hooks} = {},
) {
  const captured = await captureGeneratorSourceFiles(sourceDirectory, pathPrefix, {
    hooks,
  });
  const directory = await mkdtemp(path.join(
    path.dirname(sourceDirectory),
    '.ccpocket-contract-source-',
  ));
  try {
    for (const [filename, bytes] of captured.files) {
      await writeFile(path.join(directory, filename), bytes, {
        flag: 'wx',
        mode: 0o400,
      });
    }
    await chmod(directory, 0o500);
    await runHook(hooks, 'beforeSnapshotVerification', {directory});
    await verifyGeneratorSourceFiles(
      directory,
      pathPrefix,
      captured.catalog,
      {requireReadOnly: true},
    );
    return {
      catalog: captured.catalog,
      directory,
      dispose: () => disposeSnapshot(directory, hooks),
    };
  } catch (error) {
    await finishWithCleanup(
      error,
      () => disposeSnapshot(directory, hooks),
      'generator source snapshot creation and cleanup both failed',
    );
  }
}
