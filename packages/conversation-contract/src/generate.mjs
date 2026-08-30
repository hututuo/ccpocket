import { randomUUID } from 'node:crypto';
import { lstat, mkdir, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { canonicalJson, digestBytes, digestJson } from './canonical.mjs';
import { generateDart } from './generate-dart.mjs';
import { generateSchema } from './generate-schema.mjs';
import { generateTypeScript } from './generate-typescript.mjs';

export const GENERATED_FILES = [
  'schema.json',
  'contract.ts',
  'contract.dart',
  'profile-manifest.json',
];

export async function assertOutputDirectory(outputDirectory, {create = false} = {}) {
  let outputStatus;
  try {
    outputStatus = await lstat(outputDirectory);
  } catch (error) {
    if (error?.code !== 'ENOENT' || !create) {
      if (error?.code === 'ENOENT') {
        throw new Error(`output directory does not exist: ${outputDirectory}`);
      }
      throw error;
    }
    await mkdir(outputDirectory, {recursive: true});
    outputStatus = await lstat(outputDirectory);
  }
  if (outputStatus.isSymbolicLink()) {
    throw new Error(`output directory must not be a symbolic link: ${outputDirectory}`);
  }
  if (!outputStatus.isDirectory()) {
    throw new Error(`output path is not a directory: ${outputDirectory}`);
  }
}

function byId(left, right) {
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}

function activeSource(model) {
  const hardRules = [...model.hardRules.values()].sort(byId);
  const ownerIds = new Set(hardRules.map((rule) => rule.ownerRef));
  const consumerIds = new Set(hardRules.map((rule) => rule.consumerRef));
  const testIds = new Set(hardRules.map((rule) => rule.executableTestRef));
  return {
    formatVersion: model.registry.formatVersion,
    profile: {
      ...model.activeProfile,
      rootTypeRefs: [...model.activeProfile.rootTypeRefs].sort(),
    },
    definitions: [...model.activeDefinitionIds]
      .sort()
      .map((id) => {
        const definition = model.definitions.get(id);
        return {...definition, profiles: [...definition.profiles].sort()};
      }),
    owners: [...ownerIds].sort().map((id) => model.owners.get(id)),
    consumers: [...consumerIds].sort().map((id) => model.consumers.get(id)),
    executableTests: [...testIds].sort().map((id) => model.executableTests.get(id)),
    hardRules,
    vectorSets: [...model.vectorSets.values()].sort(byId),
    vectors: [...model.activeVectors].sort(byId),
  };
}

export function generateArtifacts(
  model,
  {dartSource, dartFormatterVersion} = {},
) {
  const source = activeSource(model);
  const sourceDigest = digestJson(source);
  const schema = generateSchema(model, sourceDigest);
  const typescript = generateTypeScript(model, sourceDigest);
  const dart = dartSource ?? generateDart(model, sourceDigest);
  const artifactDigests = {
    'contract.dart': digestBytes(dart),
    'contract.ts': digestBytes(typescript),
    'schema.json': digestBytes(schema),
  };
  const manifest = canonicalJson({
    formatVersion: 1,
    generator: '@ccpocket/conversation-contract@0.0.0-private',
    ...(dartFormatterVersion ? {dartFormatterVersion} : {}),
    profileId: model.activeProfileId,
    profileDigest: sourceDigest,
    typeIds: [...model.activeDefinitionIds].sort(),
    hardRuleIds: [...model.hardRules.keys()].sort(),
    vectorSetIds: [...model.vectorSets.keys()].sort(),
    vectorIds: model.activeVectors.map((vector) => vector.id).sort(),
    artifactDigests,
  });
  return new Map([
    ['schema.json', schema],
    ['contract.ts', typescript],
    ['contract.dart', dart],
    ['profile-manifest.json', manifest],
  ]);
}

export async function writeArtifacts(outputDirectory, artifacts) {
  await assertOutputDirectory(outputDirectory, {create: true});
  const targets = new Map(GENERATED_FILES.map((filename) => [
    filename,
    path.join(outputDirectory, filename),
  ]));
  await writeArtifactTargets(targets, artifacts);
}

function commonAncestor(paths) {
  const split = paths.map((filename) => path.resolve(filename).split(path.sep));
  const common = [];
  for (let index = 0; index < Math.min(...split.map((parts) => parts.length)); index += 1) {
    const part = split[0][index];
    if (!split.every((parts) => parts[index] === part)) break;
    common.push(part);
  }
  return common.length === 1 && common[0] === ''
    ? path.parse(path.resolve(paths[0])).root
    : common.join(path.sep);
}

async function pathStatus(filename) {
  try {
    return await lstat(filename);
  } catch (error) {
    if (error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

export async function writeArtifactTargets(targets, artifacts) {
  const targetPaths = GENERATED_FILES.map((filename) => {
    const target = targets.get(filename);
    if (target === undefined) throw new Error(`missing artifact target ${filename}`);
    return target;
  });
  if (new Set(targetPaths).size !== GENERATED_FILES.length) {
    throw new Error('artifact targets must be unique');
  }
  for (const target of targetPaths) {
    await assertOutputDirectory(path.dirname(target), {create: true});
    const status = await pathStatus(target);
    if (status?.isDirectory()) throw new Error(`artifact target is a directory: ${target}`);
  }

  const transactionRoot = commonAncestor(targetPaths);
  await assertOutputDirectory(transactionRoot);
  const lockDirectory = path.join(transactionRoot, '.ccpocket-contract-targets.lock');
  const stageDirectory = path.join(
    transactionRoot,
    `.ccpocket-contract-targets-stage-${randomUUID()}`,
  );
  const newDirectory = path.join(stageDirectory, 'new');
  const backupDirectory = path.join(stageDirectory, 'backup');
  let ownsLock = false;
  const backedUp = [];
  const installed = [];
  try {
    try {
      await mkdir(lockDirectory, {mode: 0o700});
      ownsLock = true;
    } catch (error) {
      if (error?.code === 'EEXIST') {
        throw new Error(`artifact generation is already locked: ${transactionRoot}`);
      }
      throw error;
    }
    await mkdir(newDirectory, {recursive: true, mode: 0o700});
    await mkdir(backupDirectory, {mode: 0o700});
    for (const filename of GENERATED_FILES) {
      const content = artifacts.get(filename);
      if (content === undefined) throw new Error(`missing generated artifact ${filename}`);
      await writeFile(path.join(newDirectory, filename), content, {
        encoding: 'utf8',
        flag: 'wx',
      });
    }

    for (const filename of GENERATED_FILES) {
      const target = targets.get(filename);
      if (await pathStatus(target)) {
        await rename(target, path.join(backupDirectory, filename));
        backedUp.push(filename);
      }
    }
    for (const filename of GENERATED_FILES) {
      const target = targets.get(filename);
      await rename(path.join(newDirectory, filename), target);
      installed.push(filename);
    }
  } catch (error) {
    for (const filename of installed.reverse()) {
      await rm(targets.get(filename), {force: true});
    }
    for (const filename of backedUp.reverse()) {
      await rename(path.join(backupDirectory, filename), targets.get(filename));
    }
    throw error;
  } finally {
    await rm(stageDirectory, {recursive: true, force: true});
    if (ownsLock) await rm(lockDirectory, {recursive: true, force: true});
  }
}
