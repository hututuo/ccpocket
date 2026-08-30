import { randomUUID } from 'node:crypto';
import {
  lstat,
  link,
  mkdir,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  rmdir,
  unlink,
  writeFile,
} from 'node:fs/promises';
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

async function pathStatus(filename) {
  try {
    return await lstat(filename);
  } catch (error) {
    if (error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

export async function assertOutputDirectory(outputDirectory) {
  const outputStatus = await pathStatus(outputDirectory);
  if (outputStatus === undefined) {
    throw new Error(`output directory does not exist: ${outputDirectory}`);
  }
  if (outputStatus.isSymbolicLink()) {
    throw new Error(`output directory must not be a symbolic link: ${outputDirectory}`);
  }
  if (!outputStatus.isDirectory()) {
    throw new Error(`output path is not a directory: ${outputDirectory}`);
  }
  return realpath(outputDirectory);
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

export async function resolveRealProjectRoot(configuredRoot) {
  const resolved = path.resolve(configuredRoot);
  let canonical;
  try {
    canonical = await realpath(resolved);
  } catch (error) {
    throw new Error(`projectRoot cannot be resolved: ${resolved}: ${error.message}`);
  }
  const status = await lstat(canonical);
  if (!status.isDirectory()) throw new Error(`projectRoot is not a directory: ${resolved}`);
  return canonical;
}

export function resolveProjectTarget(projectRoot, configured, filename) {
  if (typeof configured !== 'string' || configured.length === 0) {
    throw new Error(`${filename} must map to a non-empty path`);
  }
  const target = path.resolve(projectRoot, configured);
  if (!isInside(projectRoot, target)) {
    throw new Error(`${filename} escapes projectRoot`);
  }
  if (path.basename(target) !== filename) {
    throw new Error(`${filename} target must keep its artifact filename`);
  }
  return target;
}

export async function assertSecureDirectory(
  projectRoot,
  directory,
  {create = false} = {},
) {
  const root = path.resolve(projectRoot);
  const target = path.resolve(directory);
  if (!isInside(root, target)) {
    throw new Error(`directory escapes projectRoot: ${target}`);
  }
  const relative = path.relative(root, target);
  let current = root;
  for (const segment of relative === '' ? [] : relative.split(path.sep)) {
    current = path.join(current, segment);
    let status = await pathStatus(current);
    if (status === undefined && create) {
      try {
        await mkdir(current, {mode: 0o700});
      } catch (error) {
        if (error?.code !== 'EEXIST') throw error;
      }
      status = await pathStatus(current);
    }
    if (status === undefined) throw new Error(`output directory does not exist: ${current}`);
    if (status.isSymbolicLink()) {
      throw new Error(`output path contains a symbolic link: ${current}`);
    }
    if (!status.isDirectory()) throw new Error(`output path is not a directory: ${current}`);
    const canonical = await realpath(current);
    if (!isInside(root, canonical)) {
      throw new Error(`output directory resolves outside projectRoot: ${current}`);
    }
  }
  return target;
}

async function prepareStandaloneOutputDirectory(outputDirectory) {
  const requested = path.resolve(outputDirectory);
  const directStatus = await pathStatus(requested);
  if (directStatus?.isSymbolicLink()) {
    throw new Error(`output directory must not be a symbolic link: ${requested}`);
  }
  if (directStatus !== undefined && !directStatus.isDirectory()) {
    throw new Error(`output path is not a directory: ${requested}`);
  }

  const missing = [];
  let ancestor = requested;
  let status = directStatus;
  while (status === undefined) {
    missing.unshift(path.basename(ancestor));
    const parent = path.dirname(ancestor);
    if (parent === ancestor) throw new Error(`cannot resolve output directory: ${requested}`);
    ancestor = parent;
    status = await pathStatus(ancestor);
  }
  if (!status.isDirectory() && !status.isSymbolicLink()) {
    throw new Error(`output ancestor is not a directory: ${ancestor}`);
  }
  const projectRoot = await resolveRealProjectRoot(ancestor);
  const canonicalOutput = path.join(projectRoot, ...missing);
  await assertSecureDirectory(projectRoot, canonicalOutput, {create: true});
  return {projectRoot, outputDirectory: canonicalOutput};
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
  const prepared = await prepareStandaloneOutputDirectory(outputDirectory);
  const targets = new Map(GENERATED_FILES.map((filename) => [
    filename,
    path.join(prepared.outputDirectory, filename),
  ]));
  await writeArtifactTargets(targets, artifacts, {
    projectRoot: prepared.outputDirectory,
  });
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

export const TRANSACTION_LOCK_NAME = '.ccpocket-contract-targets.lock';
export const TRANSACTION_STAGE_PREFIX = '.ccpocket-contract-targets-stage-';

export function transactionRootsForTargets(projectRoot, targets) {
  const transactionRoot = commonAncestor([...targets.values()]);
  if (!isInside(projectRoot, transactionRoot)) {
    throw new Error(`artifact transaction root escapes projectRoot: ${transactionRoot}`);
  }
  return [...new Set([path.resolve(projectRoot), transactionRoot])];
}

export async function findTransactionResidues(roots) {
  const residues = [];
  for (const root of roots) {
    const entries = await readdir(root);
    for (const name of entries) {
      if (name === TRANSACTION_LOCK_NAME || name.startsWith(TRANSACTION_STAGE_PREFIX)) {
        residues.push(path.join(root, name));
      }
    }
  }
  return [...new Set(residues)].sort();
}

function statusKind(status) {
  if (status.isFile()) return 'file';
  if (status.isDirectory()) return 'directory';
  if (status.isSymbolicLink()) return 'symlink';
  if (status.isSocket()) return 'socket';
  if (status.isFIFO()) return 'fifo';
  if (status.isBlockDevice()) return 'block-device';
  if (status.isCharacterDevice()) return 'character-device';
  return 'other';
}

async function pathIdentity(filename) {
  const before = await pathStatus(filename);
  if (before === undefined) return undefined;
  const identity = {
    kind: statusKind(before),
    dev: before.dev,
    ino: before.ino,
  };
  if (before.isFile()) {
    const content = await readFile(filename);
    const after = await lstat(filename);
    if (before.dev !== after.dev ||
        before.ino !== after.ino ||
        before.size !== after.size ||
        content.length !== after.size ||
        !after.isFile()) {
      throw new Error(`artifact changed while its identity was recorded: ${filename}`);
    }
    identity.size = after.size;
    identity.digest = digestBytes(content);
  }
  return identity;
}

function sameIdentity(left, right) {
  if (left === undefined || right === undefined) return left === right;
  return left.kind === right.kind &&
    left.dev === right.dev &&
    left.ino === right.ino &&
    (left.kind !== 'file' || (
      left.size === right.size && left.digest === right.digest
    ));
}

async function runHook(hooks, name, details) {
  const hook = hooks?.[name];
  if (hook !== undefined) await hook(details);
}

async function rollbackTransaction({installed, backedUp, hooks}) {
  for (const record of [...installed].reverse()) {
    await runHook(hooks, 'beforeRollbackRemove', record);
    const current = await pathIdentity(record.target);
    if (current === undefined) continue;
    if (!sameIdentity(current, record.identity)) {
      throw new Error(`installed artifact was externally replaced: ${record.target}`);
    }
    await unlink(record.target);
  }
  for (const record of [...backedUp].reverse()) {
    await runHook(hooks, 'beforeRollbackRestore', record);
    if (await pathStatus(record.target)) {
      throw new Error(`rollback target is occupied: ${record.target}`);
    }
    const currentBackup = await pathIdentity(record.backup);
    if (!sameIdentity(currentBackup, record.identity)) {
      throw new Error(`artifact backup was externally replaced: ${record.backup}`);
    }
    await link(record.backup, record.target);
    if (!sameIdentity(await pathIdentity(record.target), record.identity)) {
      throw new Error(`artifact changed while its backup was restored: ${record.target}`);
    }
    await unlink(record.backup);
  }
}

async function cleanupTransaction({stageDirectory, stageIdentity, lockDirectory, lockIdentity, hooks}) {
  await runHook(hooks, 'beforeStageCleanup', {stageDirectory, lockDirectory});
  const currentStage = await pathIdentity(stageDirectory);
  if (!sameIdentity(currentStage, stageIdentity)) {
    throw new Error(`transaction stage was externally replaced: ${stageDirectory}`);
  }
  if (currentStage !== undefined) await rm(stageDirectory, {recursive: true});
  await runHook(hooks, 'beforeLockCleanup', {stageDirectory, lockDirectory});
  const currentLock = await pathIdentity(lockDirectory);
  if (!sameIdentity(currentLock, lockIdentity)) {
    throw new Error(`transaction lock was externally replaced: ${lockDirectory}`);
  }
  await rmdir(lockDirectory);
}

function recoveryError(stageDirectory, original, recoveryFailure) {
  return new Error(
    `artifact transaction failed and automatic recovery stopped; ` +
    `evidence retained at ${stageDirectory}: ${recoveryFailure.message}`,
    {cause: original},
  );
}

export async function writeArtifactTargets(
  targets,
  artifacts,
  {projectRoot, hooks} = {},
) {
  if (projectRoot === undefined) {
    throw new Error('projectRoot is required for mapped artifact generation');
  }
  const configuredProjectRoot = path.resolve(projectRoot);
  const realProjectRoot = await resolveRealProjectRoot(projectRoot);
  const targetPaths = GENERATED_FILES.map((filename) => {
    const target = targets.get(filename);
    if (target === undefined) throw new Error(`missing artifact target ${filename}`);
    const configuredTarget = path.resolve(target);
    const resolved = isInside(realProjectRoot, configuredTarget)
      ? configuredTarget
      : isInside(configuredProjectRoot, configuredTarget)
        ? path.join(
            realProjectRoot,
            path.relative(configuredProjectRoot, configuredTarget),
          )
        : configuredTarget;
    if (!isInside(realProjectRoot, resolved)) {
      throw new Error(`artifact target escapes projectRoot: ${resolved}`);
    }
    return resolved;
  });
  if (new Set(targetPaths).size !== GENERATED_FILES.length) {
    throw new Error('artifact targets must be unique');
  }
  const normalizedTargets = new Map(
    GENERATED_FILES.map((filename, index) => [filename, targetPaths[index]]),
  );
  for (const target of normalizedTargets.values()) {
    await assertSecureDirectory(realProjectRoot, path.dirname(target), {create: true});
    const status = await pathStatus(target);
    if (status?.isDirectory()) throw new Error(`artifact target is a directory: ${target}`);
    if (status !== undefined && !status.isFile() && !status.isSymbolicLink()) {
      throw new Error(`artifact target has an unsupported file type: ${target}`);
    }
  }

  const transactionRoots = transactionRootsForTargets(realProjectRoot, normalizedTargets);
  const transactionRoot = transactionRoots.at(-1);
  await assertSecureDirectory(realProjectRoot, transactionRoot);
  const residues = await findTransactionResidues(transactionRoots);
  if (residues.length > 0) {
    throw new Error(`unfinished artifact transaction: ${residues.join(', ')}`);
  }
  const lockDirectory = path.join(transactionRoot, TRANSACTION_LOCK_NAME);
  const stageDirectory = path.join(
    transactionRoot,
    `${TRANSACTION_STAGE_PREFIX}${randomUUID()}`,
  );
  const newDirectory = path.join(stageDirectory, 'new');
  const backupDirectory = path.join(stageDirectory, 'backup');
  const backedUp = [];
  const installed = [];
  try {
    await mkdir(lockDirectory, {mode: 0o700});
  } catch (error) {
    if (error?.code === 'EEXIST') {
      throw new Error(`artifact generation is already locked: ${transactionRoot}`);
    }
    throw error;
  }
  const lockIdentity = await pathIdentity(lockDirectory);
  let stageIdentity;
  let transactionFailure;
  try {
    await mkdir(stageDirectory, {mode: 0o700});
    stageIdentity = await pathIdentity(stageDirectory);
    await mkdir(newDirectory, {mode: 0o700});
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
      const target = normalizedTargets.get(filename);
      if (await pathStatus(target)) {
        const backup = path.join(backupDirectory, filename);
        const record = {
          filename,
          target,
          backup,
          identity: await pathIdentity(target),
        };
        await rename(target, backup);
        backedUp.push(record);
        if (!sameIdentity(await pathIdentity(backup), record.identity)) {
          throw new Error(`artifact changed while it was backed up: ${target}`);
        }
        await runHook(hooks, 'afterBackup', record);
      }
    }
    for (const filename of GENERATED_FILES) {
      const target = normalizedTargets.get(filename);
      const staged = path.join(newDirectory, filename);
      const record = {
        filename,
        target,
        identity: await pathIdentity(staged),
      };
      await link(staged, target);
      installed.push(record);
      if (!sameIdentity(await pathIdentity(target), record.identity)) {
        throw new Error(`artifact changed while it was installed: ${target}`);
      }
      await unlink(staged);
      await runHook(hooks, 'afterInstall', record);
    }
  } catch (error) {
    transactionFailure = error;
  }

  if (transactionFailure !== undefined) {
    try {
      await rollbackTransaction({installed, backedUp, hooks});
    } catch (rollbackFailure) {
      throw recoveryError(stageDirectory, transactionFailure, rollbackFailure);
    }
    try {
      await cleanupTransaction({
        stageDirectory,
        stageIdentity,
        lockDirectory,
        lockIdentity,
        hooks,
      });
    } catch (cleanupFailure) {
      throw recoveryError(stageDirectory, transactionFailure, cleanupFailure);
    }
    throw transactionFailure;
  }

  try {
    await cleanupTransaction({
      stageDirectory,
      stageIdentity,
      lockDirectory,
      lockIdentity,
      hooks,
    });
  } catch (cleanupFailure) {
    throw recoveryError(stageDirectory, cleanupFailure, cleanupFailure);
  }
}
