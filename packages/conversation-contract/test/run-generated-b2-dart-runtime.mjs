import {spawnSync} from 'node:child_process';
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {generateArtifacts} from '../src/generate.mjs';
import {validateInputs} from '../src/validate.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.dirname(here);
const repositoryRoot = path.resolve(packageRoot, '..', '..');
const registry = JSON.parse(readFileSync(path.join(
  repositoryRoot,
  'docs/design/codex-kernel-v4/contracts/contract-registry.json',
), 'utf8'));
const vectors = JSON.parse(readFileSync(path.join(
  repositoryRoot,
  'docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json',
), 'utf8'));
const runner = readFileSync(path.join(
  here,
  'fixtures/dart/b2-authority-runtime.dart',
), 'utf8');
const directory = mkdtempSync(path.join(tmpdir(), 'ccpocket-b2-dart-runtime-'));

try {
  const artifacts = generateArtifacts(validateInputs(registry, vectors));
  const contractPath = path.join(directory, 'contract.dart');
  const runnerPath = path.join(directory, 'runtime.dart');
  writeFileSync(contractPath, artifacts.get('contract.dart'));
  writeFileSync(runnerPath, runner);
  const packageConfig = path.join(
    repositoryRoot,
    'apps/mobile/.dart_tool/package_config.json',
  );
  const result = spawnSync(
    'mise',
    [
      'exec',
      'flutter@3.47.0',
      '--',
      'dart',
      `--packages=${packageConfig}`,
      runnerPath,
    ],
    {cwd: repositoryRoot, encoding: 'utf8'},
  );
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) process.exitCode = result.status ?? 1;
} finally {
  rmSync(directory, {recursive: true, force: true});
}
