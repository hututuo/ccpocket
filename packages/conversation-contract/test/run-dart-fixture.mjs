import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { runDart } from '../src/cli.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = path.join(here, 'fixtures/dart/analyze.dart');
const packageConfig = path.resolve(here, '../../../apps/mobile/.dart_tool/package_config.json');
const mobileRoot = path.resolve(here, '../../../apps/mobile');
const {stdout, stderr} = await runDart(['--version']);
const version = /Dart SDK version:\s*([^\s]+)/.exec(`${stdout}\n${stderr}`)?.[1];
if (version !== '3.13.0') {
  throw new Error(`Dart fixture requires 3.13.0, got ${version ?? 'unknown'}`);
}
process.chdir(mobileRoot);
await runDart(['analyze', fixture]);
await runDart([`--packages=${packageConfig}`, fixture]);
