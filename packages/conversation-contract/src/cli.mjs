#!/usr/bin/env node

import {execFile, spawn} from 'node:child_process';
import {constants as fsConstants} from 'node:fs';
import {
  lstat,
  mkdtemp,
  open,
  readFile,
  readdir,
  realpath,
  rm,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs, promisify } from 'node:util';

import {
  GENERATED_FILES,
  assertOutputDirectory,
  bindSecureDirectory,
  findTransactionResidues,
  generateArtifacts,
  resolveProjectTarget,
  resolveRealProjectRoot,
  transactionRootsForTargets,
  writeArtifactTargets,
  writeArtifacts,
} from './generate.mjs';
import { parseStrictJson } from './strict-json.mjs';
import {
  createGeneratorSourceSnapshot,
  verifyGeneratorSourceFiles,
} from './source-snapshot.mjs';
import { validateInputs } from './validate.mjs';

export { parseStrictJson } from './strict-json.mjs';

const execFileAsync = promisify(execFile);
const EXPECTED_DART_FORMATTER_VERSION = '3.13.0';
const MISE_FLUTTER_VERSION = '3.47.0';
const GENERATOR_SOURCE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const GENERATOR_SOURCE_PATH_PREFIX = 'packages/conversation-contract/src';
const SOURCE_SNAPSHOT_ENV = 'CCPOCKET_CONTRACT_SOURCE_SNAPSHOT_V1';
const ARTIFACT_OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);
const DIRECTORY_OPEN_FLAGS = fsConstants.O_RDONLY |
  (fsConstants.O_DIRECTORY ?? 0) |
  (fsConstants.O_NOFOLLOW ?? 0);

function hasExecutableMode(status) {
  if (process.platform === 'win32') return false;
  return typeof status.mode === 'bigint'
    ? (status.mode & 0o111n) !== 0n
    : (status.mode & 0o111) !== 0;
}

function sameArtifactIdentity(left, right) {
  return left.dev === right.dev &&
    left.ino === right.ino &&
    left.mode === right.mode &&
    left.size === right.size &&
    left.mtimeNs === right.mtimeNs &&
    left.ctimeNs === right.ctimeNs;
}

async function runHook(hooks, name, details) {
  if (hooks?.[name] !== undefined) await hooks[name](details);
}

async function bindArtifactDirectory(directory) {
  const lexicalBefore = await lstat(directory, {bigint: true});
  if (lexicalBefore.isSymbolicLink() || !lexicalBefore.isDirectory()) {
    throw new Error(`generated artifact directory is not regular: ${directory}`);
  }
  const handle = await open(directory, DIRECTORY_OPEN_FLAGS);
  try {
    const handleStatus = await handle.stat({bigint: true});
    const canonical = await realpath(directory);
    const lexicalAfter = await lstat(directory, {bigint: true});
    for (const status of [handleStatus, lexicalAfter]) {
      if (!status.isDirectory() ||
          status.dev !== lexicalBefore.dev ||
          status.ino !== lexicalBefore.ino) {
        throw new Error(`generated artifact directory changed while bound: ${directory}`);
      }
    }
    return {
      canonical,
      directory,
      handle,
      identity: {dev: handleStatus.dev, ino: handleStatus.ino},
    };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function assertArtifactDirectoryBinding(binding) {
  const handleBefore = await binding.handle.stat({bigint: true});
  const lexical = await lstat(binding.directory, {bigint: true});
  const canonical = await realpath(binding.directory);
  const handleAfter = await binding.handle.stat({bigint: true});
  for (const status of [handleBefore, lexical, handleAfter]) {
    if (!status.isDirectory() ||
        status.dev !== binding.identity.dev ||
        status.ino !== binding.identity.ino) {
      throw new Error(
        `generated artifact directory changed while checked: ${binding.directory}`,
      );
    }
  }
  if (lexical.isSymbolicLink() || canonical !== binding.canonical) {
    throw new Error(`generated artifact directory changed while checked: ${binding.directory}`);
  }
}

async function withArtifactDirectoryBinding(directory, action) {
  const binding = await bindArtifactDirectory(directory);
  try {
    await assertArtifactDirectoryBinding(binding);
    let value;
    let actionFailure;
    try {
      value = await action(binding);
    } catch (error) {
      actionFailure = error;
    }
    try {
      await assertArtifactDirectoryBinding(binding);
    } catch (bindingFailure) {
      throw new Error(bindingFailure.message, {cause: actionFailure ?? bindingFailure});
    }
    if (actionFailure !== undefined) throw actionFailure;
    return value;
  } finally {
    await binding.handle.close();
  }
}

async function assertSecureArtifactDirectoryBindings(bindings) {
  for (const binding of [...new Set(bindings)]) {
    await binding.assertCurrent();
  }
}

async function withSecureArtifactDirectoryBindings(bindings, action) {
  const unique = [...new Set(bindings)];
  let actionFailure;
  try {
    await assertSecureArtifactDirectoryBindings(unique);
    let value;
    try {
      value = await action();
    } catch (error) {
      actionFailure = error;
    }
    try {
      await assertSecureArtifactDirectoryBindings(unique);
    } catch (bindingFailure) {
      throw new Error(bindingFailure.message, {cause: actionFailure ?? bindingFailure});
    }
    if (actionFailure !== undefined) throw actionFailure;
    return value;
  } finally {
    const failures = [];
    for (const binding of unique.reverse()) {
      try {
        await binding.close();
      } catch (error) {
        failures.push(error);
      }
    }
    if (failures.length > 0) {
      const closeFailure = new AggregateError(
        failures,
        'failed to close generated artifact directory bindings',
      );
      if (actionFailure !== undefined) {
        throw new AggregateError(
          [actionFailure, closeFailure],
          'artifact check and directory binding cleanup both failed',
        );
      }
      throw closeFailure;
    }
  }
}

async function inspectArtifact(target, expected, hooks, details) {
  let handle;
  try {
    handle = await open(target, ARTIFACT_OPEN_FLAGS);
  } catch (error) {
    if (error?.code === 'ENOENT') return 'missing';
    if (error?.code === 'ELOOP') return 'not a regular file';
    throw error;
  }
  try {
    const handleBefore = await handle.stat({bigint: true});
    if (!handleBefore.isFile()) return 'not a regular file';
    if (hasExecutableMode(handleBefore)) return 'must not be executable';
    await runHook(hooks, 'afterArtifactHandleBound', {
      ...details,
      target,
    });
    const bytes = await handle.readFile();
    const handleAfter = await handle.stat({bigint: true});
    let lexicalAfter;
    try {
      lexicalAfter = await lstat(target, {bigint: true});
    } catch (error) {
      if (error?.code === 'ENOENT') return 'changed while checked';
      throw error;
    }
    if (!handleAfter.isFile() ||
        lexicalAfter.isSymbolicLink() ||
        !lexicalAfter.isFile() ||
        !sameArtifactIdentity(handleBefore, handleAfter) ||
        !sameArtifactIdentity(handleAfter, lexicalAfter) ||
        BigInt(bytes.byteLength) !== handleAfter.size) {
      return 'changed while checked';
    }
    if (hasExecutableMode(handleAfter) || hasExecutableMode(lexicalAfter)) {
      return 'must not be executable';
    }
    return bytes.equals(Buffer.from(expected, 'utf8')) ? undefined : 'content differs';
  } finally {
    await handle.close();
  }
}

export async function runDart(args) {
  try {
    return await execFileAsync('dart', args);
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
    try {
      return await execFileAsync('mise', [
        'exec',
        `flutter@${MISE_FLUTTER_VERSION}`,
        '--',
        'dart',
        ...args,
      ]);
    } catch (fallbackError) {
      if (fallbackError?.code === 'ENOENT') {
        throw new Error(
          'Dart formatter not found; install Dart 3.13.0 or mise with Flutter 3.47.0',
        );
      }
      throw fallbackError;
    }
  }
}

async function readJson(filename, label) {
  let text;
  try {
    text = await readFile(filename, 'utf8');
  } catch (error) {
    throw new Error(`${label}: cannot read ${filename}: ${error.message}`);
  }
  return parseStrictJson(text, {filename, label});
}

async function loadModel(options) {
  if (!options.registry) throw new Error('--registry is required');
  if (!options.vectors) throw new Error('--vectors is required');
  const [registry, vectors] = await Promise.all([
    readJson(path.resolve(options.registry), 'registry'),
    readJson(path.resolve(options.vectors), 'vectors'),
  ]);
  return validateInputs(registry, vectors);
}

async function loadTargetMap(filename) {
  const resolved = path.resolve(filename);
  const document = await readJson(resolved, 'target map');
  if (document === null || typeof document !== 'object' || Array.isArray(document)) {
    throw new Error(`target map: expected an object in ${resolved}`);
  }
  const documentKeys = Object.keys(document).sort();
  if (JSON.stringify(documentKeys) !== JSON.stringify(['artifacts', 'formatVersion', 'projectRoot'])) {
    throw new Error(`target map: expected only formatVersion, projectRoot, and artifacts in ${resolved}`);
  }
  if (document.formatVersion !== 1) {
    throw new Error(`target map: only format version 1 is supported in ${resolved}`);
  }
  if (typeof document.projectRoot !== 'string' || document.projectRoot.length === 0) {
    throw new Error(`target map: projectRoot must be a non-empty string in ${resolved}`);
  }
  if (document.artifacts === null ||
      typeof document.artifacts !== 'object' ||
      Array.isArray(document.artifacts)) {
    throw new Error(`target map: artifacts must be an object in ${resolved}`);
  }
  const artifactKeys = Object.keys(document.artifacts).sort();
  const expectedKeys = [...GENERATED_FILES].sort();
  if (JSON.stringify(artifactKeys) !== JSON.stringify(expectedKeys)) {
    throw new Error(`target map: artifacts must map exactly ${expectedKeys.join(', ')} in ${resolved}`);
  }

  const configuredProjectRoot = path.resolve(path.dirname(resolved), document.projectRoot);
  const projectRoot = await resolveRealProjectRoot(configuredProjectRoot);
  const targets = new Map();
  for (const filename of GENERATED_FILES) {
    const configured = document.artifacts[filename];
    if (typeof configured !== 'string' || configured.length === 0) {
      throw new Error(`target map: ${filename} must map to a non-empty path in ${resolved}`);
    }
    let target;
    try {
      target = resolveProjectTarget(projectRoot, configured, filename);
    } catch (error) {
      throw new Error(`target map: ${error.message} in ${resolved}`);
    }
    targets.set(filename, target);
  }
  if (new Set(targets.values()).size !== GENERATED_FILES.length) {
    throw new Error(`target map: artifact targets must be unique in ${resolved}`);
  }
  return {filename: resolved, projectRoot, targets};
}

async function checkDrift(outputDirectory, artifacts, hooks) {
  const canonicalDirectory = await assertOutputDirectory(outputDirectory);
  const drift = [];
  await withArtifactDirectoryBinding(canonicalDirectory, async (binding) => {
    for (const filename of GENERATED_FILES) {
      const target = path.join(canonicalDirectory, filename);
      await assertArtifactDirectoryBinding(binding);
      const issue = await inspectArtifact(
        target,
        artifacts.get(filename),
        hooks,
        {filename, mode: 'standalone'},
      );
      if (issue !== undefined) drift.push(`${filename} (${issue})`);
      await runHook(hooks, 'afterArtifactInspected', {
        filename,
        mode: 'standalone',
        target,
      });
      await assertArtifactDirectoryBinding(binding);
    }
    await assertArtifactDirectoryBinding(binding);
    const entries = await readdir(canonicalDirectory, {withFileTypes: true});
    await assertArtifactDirectoryBinding(binding);
    for (const entry of entries) {
      if (!GENERATED_FILES.includes(entry.name)) {
        drift.push(`${entry.name} (unexpected)`);
      }
    }
  });
  if (drift.length > 0) {
    throw new Error(`generated artifact drift: ${drift.join(', ')}; run generate`);
  }
}

async function checkTargetDrift(targetMap, artifacts, hooks) {
  const drift = [];
  const filesByDirectory = new Map();
  for (const filename of GENERATED_FILES) {
    const target = targetMap.targets.get(filename);
    const directory = path.dirname(target);
    if (!filesByDirectory.has(directory)) filesByDirectory.set(directory, new Set());
    filesByDirectory.get(directory).add(path.basename(target));
  }
  const bindingsByDirectory = new Map();
  for (const directory of filesByDirectory.keys()) {
    try {
      bindingsByDirectory.set(
        directory,
        await bindSecureDirectory(targetMap.projectRoot, directory),
      );
    } catch (error) {
      drift.push(`${directory} (${error.message})`);
    }
  }
  const bindings = [...bindingsByDirectory.values()];
  const transactionRoots = transactionRootsForTargets(
    targetMap.projectRoot,
    targetMap.targets,
  );
  await withSecureArtifactDirectoryBindings(bindings, async () => {
    for (const residue of await findTransactionResidues(transactionRoots)) {
      drift.push(`${residue} (unfinished transaction)`);
    }
    for (const filename of GENERATED_FILES) {
      const target = targetMap.targets.get(filename);
      const directory = path.dirname(target);
      if (!bindingsByDirectory.has(directory)) continue;
      await assertSecureArtifactDirectoryBindings(bindings);
      const issue = await inspectArtifact(
        target,
        artifacts.get(filename),
        hooks,
        {filename, mode: 'mapped'},
      );
      if (issue !== undefined) drift.push(`${target} (${issue})`);
      await runHook(hooks, 'afterArtifactInspected', {
        filename,
        mode: 'mapped',
        target,
      });
      await assertSecureArtifactDirectoryBindings(bindings);
    }
    for (const [directory, expected] of filesByDirectory) {
      if (!bindingsByDirectory.has(directory)) continue;
      await assertSecureArtifactDirectoryBindings(bindings);
      const entries = await readdir(directory, {withFileTypes: true});
      await assertSecureArtifactDirectoryBindings(bindings);
      for (const entry of entries) {
        if (!expected.has(entry.name)) {
          drift.push(`${path.join(directory, entry.name)} (unexpected)`);
        }
      }
    }
  });
  if (drift.length > 0) {
    throw new Error(`generated artifact drift: ${drift.join(', ')}; run generate`);
  }
}

function artifactTargetsForGeneration(targetMap) {
  if (!targetMap) {
    return Object.fromEntries(GENERATED_FILES.map((filename) => [filename, filename]));
  }
  return Object.fromEntries(GENERATED_FILES.map((filename) => [
    filename,
    path.relative(targetMap.projectRoot, targetMap.targets.get(filename))
      .split(path.sep)
      .join('/'),
  ]));
}

async function formatDartArtifact(model, generationOptions) {
  const {stdout, stderr} = await runDart(['--version']);
  const versionText = `${stdout}\n${stderr}`;
  const version = /Dart SDK version:\s*([^\s]+)/.exec(versionText)?.[1];
  if (version !== EXPECTED_DART_FORMATTER_VERSION) {
    throw new Error(
      `dart formatter must be ${EXPECTED_DART_FORMATTER_VERSION}, got ${version ?? 'unknown'}`,
    );
  }
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-dart-'));
  try {
    const filename = path.join(directory, 'contract.dart');
    const raw = generateArtifacts(model, generationOptions).get('contract.dart');
    await writeFile(filename, raw, 'utf8');
    await runDart(['format', filename]);
    const formatted = await readFile(filename, 'utf8');
    return generateArtifacts(model, {
      ...generationOptions,
      dartSource: formatted,
      dartFormatterVersion: version,
    });
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
}

export async function run(argv = process.argv.slice(2), runtimeOptions = {}) {
  const {values, positionals} = parseArgs({
    args: argv,
    allowPositionals: true,
    strict: true,
    options: {
      registry: {type: 'string'},
      vectors: {type: 'string'},
      out: {type: 'string'},
      'target-map': {type: 'string'},
      'format-dart': {type: 'boolean', default: false},
    },
  });
  if (positionals.length !== 1 || !['validate', 'generate', 'check'].includes(positionals[0])) {
    throw new Error(
      'usage: cli.mjs <validate|generate|check> --registry <file> --vectors <file> ' +
      '[--out <dir> | --target-map <file>]',
    );
  }
  const command = positionals[0];
  const model = await loadModel(values);
  if (command === 'validate') {
    return {command, profileId: model.activeProfileId};
  }
  if (Boolean(values.out) === Boolean(values['target-map'])) {
    throw new Error(`exactly one of --out or --target-map is required for ${command}`);
  }
  const outputDirectory = values.out ? path.resolve(values.out) : undefined;
  const targetMap = values['target-map']
    ? await loadTargetMap(values['target-map'])
    : undefined;
  const generationOptions = {
    artifactTargets: artifactTargetsForGeneration(targetMap),
    generatorExecutionBinding: runtimeOptions.generatorExecutionBinding,
    generatorSourceFiles: runtimeOptions.generatorSourceFiles,
  };
  const artifacts = values['format-dart']
    ? await formatDartArtifact(model, generationOptions)
    : generateArtifacts(model, generationOptions);
  if (command === 'generate') {
    if (targetMap) {
      await writeArtifactTargets(targetMap.targets, artifacts, {
        projectRoot: targetMap.projectRoot,
        beforeCommit: runtimeOptions.beforeArtifactCommit,
      });
    } else {
      await writeArtifacts(outputDirectory, artifacts, {
        beforeCommit: runtimeOptions.beforeArtifactCommit,
      });
    }
    return {
      command,
      profileId: model.activeProfileId,
      ...(targetMap ? {targetMap: targetMap.filename} : {outputDirectory}),
    };
  }
  if (targetMap) await checkTargetDrift(targetMap, artifacts, runtimeOptions.hooks);
  else await checkDrift(outputDirectory, artifacts, runtimeOptions.hooks);
  return {
    command,
    profileId: model.activeProfileId,
    ...(targetMap ? {targetMap: targetMap.filename} : {outputDirectory}),
  };
}

function spawnSnapshotCli(snapshot, argv) {
  const payload = Buffer.from(JSON.stringify({
    catalog: snapshot.catalog,
    directory: snapshot.directory,
  }), 'utf8').toString('base64');
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [path.join(snapshot.directory, 'cli.mjs'), ...argv],
      {
        cwd: process.cwd(),
        env: {...process.env, [SOURCE_SNAPSHOT_ENV]: payload},
        stdio: 'inherit',
      },
    );
    child.once('error', reject);
    child.once('close', (code, signal) => {
      if (signal !== null) {
        reject(new Error(`generator snapshot child terminated by ${signal}`));
      } else {
        resolve(code ?? 1);
      }
    });
  });
}

async function runSnapshotChild(argv, encoded) {
  let payload;
  try {
    payload = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
  } catch {
    throw new Error('invalid generator source snapshot handoff');
  }
  const [payloadDirectory, processSourceDirectory] = await Promise.all([
    realpath(path.resolve(payload.directory ?? '')),
    realpath(GENERATOR_SOURCE_DIRECTORY),
  ]);
  if (payloadDirectory !== processSourceDirectory ||
      !Array.isArray(payload.catalog)) {
    throw new Error('generator source snapshot handoff does not match this process');
  }
  await verifyGeneratorSourceFiles(
    GENERATOR_SOURCE_DIRECTORY,
    GENERATOR_SOURCE_PATH_PREFIX,
    payload.catalog,
    {requireReadOnly: true},
  );
  const verifySnapshot = () => verifyGeneratorSourceFiles(
    GENERATOR_SOURCE_DIRECTORY,
    GENERATOR_SOURCE_PATH_PREFIX,
    payload.catalog,
    {requireReadOnly: true},
  );
  let verifiedBeforeCommit = false;
  let result;
  let runFailure;
  try {
    result = await run(argv, {
      generatorExecutionBinding: 'IMMUTABLE_SOURCE_SNAPSHOT_V1',
      generatorSourceFiles: payload.catalog,
      beforeArtifactCommit: async () => {
        await verifySnapshot();
        verifiedBeforeCommit = true;
      },
    });
  } catch (error) {
    runFailure = error;
  }
  if (result?.command !== 'generate' || !verifiedBeforeCommit) {
    try {
      await verifySnapshot();
    } catch (verificationFailure) {
      throw new Error(verificationFailure.message, {
        cause: runFailure ?? verificationFailure,
      });
    }
  }
  if (runFailure !== undefined) throw runFailure;
  process.stdout.write(`${result.command}: ${result.profileId}\n`);
}

async function main(argv) {
  const encodedSnapshot = process.env[SOURCE_SNAPSHOT_ENV];
  if (encodedSnapshot !== undefined) {
    await runSnapshotChild(argv, encodedSnapshot);
    return;
  }
  const snapshot = await createGeneratorSourceSnapshot(
    GENERATOR_SOURCE_DIRECTORY,
    GENERATOR_SOURCE_PATH_PREFIX,
  );
  try {
    process.exitCode = await spawnSnapshotCli(snapshot, argv);
  } finally {
    await snapshot.dispose();
  }
}

if (process.env[SOURCE_SNAPSHOT_ENV] !== undefined ||
    fileURLToPath(import.meta.url) === path.resolve(process.argv[1] ?? '')) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`conversation-contract: ${error.message}\n`);
    process.exitCode = 1;
  });
}
