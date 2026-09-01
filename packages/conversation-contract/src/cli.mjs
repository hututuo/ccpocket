#!/usr/bin/env node

import { execFile } from 'node:child_process';
import { lstat, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs, promisify } from 'node:util';

import {
  GENERATED_FILES,
  assertSecureDirectory,
  assertOutputDirectory,
  findTransactionResidues,
  generateArtifacts,
  resolveProjectTarget,
  resolveRealProjectRoot,
  transactionRootsForTargets,
  writeArtifactTargets,
  writeArtifacts,
} from './generate.mjs';
import { parseStrictJson } from './strict-json.mjs';
import { validateInputs } from './validate.mjs';

export { parseStrictJson } from './strict-json.mjs';

const execFileAsync = promisify(execFile);
const EXPECTED_DART_FORMATTER_VERSION = '3.13.0';
const MISE_FLUTTER_VERSION = '3.47.0';

function hasExecutableMode(status) {
  return process.platform !== 'win32' && (status.mode & 0o111) !== 0;
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

async function checkDrift(outputDirectory, artifacts) {
  const canonicalDirectory = await assertOutputDirectory(outputDirectory);
  const drift = [];
  for (const filename of GENERATED_FILES) {
    const target = path.join(canonicalDirectory, filename);
    let status;
    try {
      status = await lstat(target);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    if (status === undefined) {
      drift.push(`${filename} (missing)`);
      continue;
    }
    if (!status.isFile() || status.isSymbolicLink()) {
      drift.push(`${filename} (not a regular file)`);
      continue;
    }
    if (hasExecutableMode(status)) {
      drift.push(`${filename} (must not be executable)`);
      continue;
    }
    let committed;
    try {
      committed = await readFile(target, 'utf8');
    } catch {
      drift.push(`${filename} (missing)`);
      continue;
    }
    if (committed !== artifacts.get(filename)) drift.push(filename);
  }
  const entries = await readdir(canonicalDirectory, {withFileTypes: true});
  for (const entry of entries) {
    if (!GENERATED_FILES.includes(entry.name)) {
      drift.push(`${entry.name} (unexpected)`);
    }
  }
  if (drift.length > 0) {
    throw new Error(`generated artifact drift: ${drift.join(', ')}; run generate`);
  }
}

async function checkTargetDrift(targetMap, artifacts) {
  const drift = [];
  const filesByDirectory = new Map();
  const transactionRoots = transactionRootsForTargets(
    targetMap.projectRoot,
    targetMap.targets,
  );
  for (const residue of await findTransactionResidues(transactionRoots)) {
    drift.push(`${residue} (unfinished transaction)`);
  }
  for (const filename of GENERATED_FILES) {
    const target = targetMap.targets.get(filename);
    const directory = path.dirname(target);
    try {
      await assertSecureDirectory(targetMap.projectRoot, directory);
    } catch (error) {
      drift.push(`${directory} (${error.message})`);
      continue;
    }
    if (!filesByDirectory.has(directory)) filesByDirectory.set(directory, new Set());
    filesByDirectory.get(directory).add(path.basename(target));
    let status;
    try {
      status = await lstat(target);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    if (status === undefined) {
      drift.push(`${target} (missing)`);
      continue;
    }
    if (!status.isFile() || status.isSymbolicLink()) {
      drift.push(`${target} (not a regular file)`);
      continue;
    }
    if (hasExecutableMode(status)) {
      drift.push(`${target} (must not be executable)`);
      continue;
    }
    let committed;
    try {
      committed = await readFile(target, 'utf8');
    } catch {
      drift.push(`${target} (missing)`);
      continue;
    }
    if (committed !== artifacts.get(filename)) drift.push(target);
  }
  for (const [directory, expected] of filesByDirectory) {
    const entries = await readdir(directory, {withFileTypes: true});
    for (const entry of entries) {
      if (!expected.has(entry.name)) {
        drift.push(`${path.join(directory, entry.name)} (unexpected)`);
      }
    }
  }
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

export async function run(argv = process.argv.slice(2)) {
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
  };
  const artifacts = values['format-dart']
    ? await formatDartArtifact(model, generationOptions)
    : generateArtifacts(model, generationOptions);
  if (command === 'generate') {
    if (targetMap) {
      await writeArtifactTargets(targetMap.targets, artifacts, {
        projectRoot: targetMap.projectRoot,
      });
    } else {
      await writeArtifacts(outputDirectory, artifacts);
    }
    return {
      command,
      profileId: model.activeProfileId,
      ...(targetMap ? {targetMap: targetMap.filename} : {outputDirectory}),
    };
  }
  if (targetMap) await checkTargetDrift(targetMap, artifacts);
  else await checkDrift(outputDirectory, artifacts);
  return {
    command,
    profileId: model.activeProfileId,
    ...(targetMap ? {targetMap: targetMap.filename} : {outputDirectory}),
  };
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] ?? '')) {
  run()
    .then((result) => {
      process.stdout.write(`${result.command}: ${result.profileId}\n`);
    })
    .catch((error) => {
      process.stderr.write(`conversation-contract: ${error.message}\n`);
      process.exitCode = 1;
    });
}
