import assert from 'node:assert/strict';
import {readdir, readFile} from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(here, '..', '..', '..');
const runtimeRoots = [
  path.join(repositoryRoot, 'packages', 'bridge', 'src'),
  path.join(repositoryRoot, 'apps', 'mobile', 'lib'),
];
const sourceExtensions = new Set(['.cjs', '.dart', '.js', '.mjs', '.ts', '.tsx']);
const forbiddenGenericDigest = /\b(?:digestJson|jcsDigest)\b/;

async function sourceFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, {withFileTypes: true})) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await sourceFiles(entryPath));
    else if (entry.isFile() && sourceExtensions.has(path.extname(entry.name))) files.push(entryPath);
  }
  return files;
}

test('application runtime cannot import or call generic contract digest primitives', async () => {
  const violations = [];
  for (const runtimeRoot of runtimeRoots) {
    for (const filename of await sourceFiles(runtimeRoot)) {
      const source = await readFile(filename, 'utf8');
      if (forbiddenGenericDigest.test(source)) {
        violations.push(path.relative(repositoryRoot, filename));
      }
    }
  }
  assert.deepEqual(
    violations,
    [],
    'jcsDigest/digestJson are build-tool primitives; runtime must use generated typed helpers',
  );
});
