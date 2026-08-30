#!/usr/bin/env node

import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { GENERATED_FILES, generateArtifacts, writeArtifacts } from './generate.mjs';
import { validateInputs } from './validate.mjs';

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

export async function run(argv = process.argv.slice(2)) {
  const {values, positionals} = parseArgs({
    args: argv,
    allowPositionals: true,
    strict: true,
    options: {
      registry: {type: 'string'},
      vectors: {type: 'string'},
      out: {type: 'string'},
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
  const artifacts = generateArtifacts(model);
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
