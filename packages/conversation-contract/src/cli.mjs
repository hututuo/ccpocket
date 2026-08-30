#!/usr/bin/env node

import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs, promisify } from 'node:util';

import { GENERATED_FILES, generateArtifacts, writeArtifacts } from './generate.mjs';
import { validateInputs } from './validate.mjs';

const execFileAsync = promisify(execFile);
const EXPECTED_DART_FORMATTER_VERSION = '3.13.0';
const MISE_FLUTTER_VERSION = '3.47.0';

async function runDart(args) {
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
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label}: invalid JSON in ${filename}: ${error.message}`);
  }
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

async function checkDrift(outputDirectory, artifacts) {
  const drift = [];
  for (const filename of GENERATED_FILES) {
    let committed;
    try {
      committed = await readFile(path.join(outputDirectory, filename), 'utf8');
    } catch {
      drift.push(`${filename} (missing)`);
      continue;
    }
    if (committed !== artifacts.get(filename)) drift.push(filename);
  }
  if (drift.length > 0) {
    throw new Error(`generated artifact drift: ${drift.join(', ')}; run generate`);
  }
}

async function formatDartArtifact(model) {
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
    const raw = generateArtifacts(model).get('contract.dart');
    await writeFile(filename, raw, 'utf8');
    await runDart(['format', filename]);
    const formatted = await readFile(filename, 'utf8');
    return generateArtifacts(model, {
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
      'format-dart': {type: 'boolean', default: false},
    },
  });
  if (positionals.length !== 1 || !['validate', 'generate', 'check'].includes(positionals[0])) {
    throw new Error('usage: cli.mjs <validate|generate|check> --registry <file> --vectors <file> [--out <dir>]');
  }
  const command = positionals[0];
  const model = await loadModel(values);
  if (command === 'validate') {
    return {command, profileId: model.activeProfileId};
  }
  if (!values.out) throw new Error(`--out is required for ${command}`);
  const outputDirectory = path.resolve(values.out);
  const artifacts = values['format-dart']
    ? await formatDartArtifact(model)
    : generateArtifacts(model);
  if (command === 'generate') {
    await writeArtifacts(outputDirectory, artifacts);
    return {command, profileId: model.activeProfileId, outputDirectory};
  }
  const temporary = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-check-'));
  try {
    await writeArtifacts(temporary, artifacts);
    const regenerated = new Map();
    for (const filename of GENERATED_FILES) {
      regenerated.set(filename, await readFile(path.join(temporary, filename), 'utf8'));
    }
    await checkDrift(outputDirectory, regenerated);
  } finally {
    await rm(temporary, {recursive: true, force: true});
  }
  return {command, profileId: model.activeProfileId, outputDirectory};
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
