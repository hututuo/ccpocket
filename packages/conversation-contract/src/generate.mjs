import { randomUUID } from 'node:crypto';
import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
} from 'node:fs';
import {
  lstat,
  link,
  mkdir,
  open,
  readFile,
  readdir,
  realpath,
  rename,
  rmdir,
  unlink,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {canonicalJson, compareUtf16, digestBytes, digestJson} from './canonical.mjs';
import { digestAuthoritySource } from './b1-digest-authority.mjs';
import {
  combineFailures,
  finishWithCleanup,
  runWithCleanup,
  runWithCleanupSync,
} from './cleanup.mjs';
import {
  CANONICALIZATION_PROFILE,
  discoverDigestPreimages,
} from './digest-preimages.mjs';
import { generateDart } from './generate-dart.mjs';
import {machineAuthoritySource} from './machine-semantics.mjs';
import { generateSchema } from './generate-schema.mjs';
import { generateTypeScript } from './generate-typescript.mjs';
import {transactionAuthoritySource} from './transaction-semantics.mjs';

export const GENERATED_FILES = [
  'schema.json',
  'contract.ts',
  'contract.dart',
  'profile-manifest.json',
];
const TRUSTED_GENERATION_CANONICAL_LIMITS = Object.freeze({
  maxDepth: 512,
  maxNodes: 1_000_000,
});
const GENERATOR_SOURCE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const GENERATOR_SOURCE_PATH_PREFIX = 'packages/conversation-contract/src';

function normalizeArtifactTargets(artifactTargets) {
  const targets = artifactTargets ?? Object.fromEntries(
    GENERATED_FILES.map((filename) => [filename, filename]),
  );
  const actual = Object.keys(targets).sort();
  const expected = [...GENERATED_FILES].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new TypeError(`artifact targets must map exactly ${expected.join(', ')}`);
  }
  return Object.fromEntries(GENERATED_FILES.map((filename) => {
    const target = targets[filename];
    if (typeof target !== 'string' || target.length === 0 || path.isAbsolute(target)) {
      throw new TypeError(`${filename} artifact target must be a non-empty relative path`);
    }
    const normalized = target.split(path.sep).join('/');
    if (normalized === '..' || normalized.startsWith('../')) {
      throw new TypeError(`${filename} artifact target escapes its provenance root`);
    }
    return [filename, normalized];
  }));
}

function generatorSourceCatalog() {
  const entries = readdirSync(GENERATOR_SOURCE_DIRECTORY, {withFileTypes: true})
    .filter((entry) => entry.name.endsWith('.mjs'))
    .sort((left, right) => compareUtf16(left.name, right.name));
  if (entries.length === 0) {
    throw new Error(`generator source closure is empty: ${GENERATOR_SOURCE_DIRECTORY}`);
  }
  return entries.map((entry) => {
    const filename = path.join(GENERATOR_SOURCE_DIRECTORY, entry.name);
    if (entry.isSymbolicLink() || !entry.isFile()) {
      throw new Error(`generator source must be a regular file: ${filename}`);
    }
    const lexicalBefore = lstatSync(filename, {bigint: true});
    if (lexicalBefore.isSymbolicLink() || !lexicalBefore.isFile()) {
      throw new Error(`generator source must be a regular file: ${filename}`);
    }
    let descriptor;
    return runWithCleanupSync(() => {
      descriptor = openSync(
        filename,
        fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0),
      );
      const handleBefore = fstatSync(descriptor, {bigint: true});
      const bytes = readFileSync(descriptor);
      const handleAfter = fstatSync(descriptor, {bigint: true});
      const lexicalAfter = lstatSync(filename, {bigint: true});
      const statuses = [handleBefore, handleAfter, lexicalAfter];
      if (statuses.some((status) => !status.isFile()) ||
          lexicalAfter.isSymbolicLink() ||
          statuses.some((status) => status.dev !== lexicalBefore.dev ||
            status.ino !== lexicalBefore.ino ||
            status.mode !== lexicalBefore.mode ||
            status.size !== lexicalBefore.size ||
            status.mtimeNs !== lexicalBefore.mtimeNs ||
            status.ctimeNs !== lexicalBefore.ctimeNs) ||
          BigInt(bytes.byteLength) !== lexicalBefore.size) {
        throw new Error(`generator source changed while it was read: ${filename}`);
      }
      return {
        path: `${GENERATOR_SOURCE_PATH_PREFIX}/${entry.name}`,
        byteLength: bytes.byteLength,
        sha256: digestBytes(bytes),
      };
    }, () => {
      if (descriptor !== undefined) closeSync(descriptor);
    }, 'generator source read and descriptor cleanup both failed');
  });
}

function renderProfileManifest(
  base,
  artifacts,
  artifactTargets,
  generatorSourceFiles,
  generatorExecutionBinding,
) {
  const normalizedTargets = normalizeArtifactTargets(artifactTargets);
  const sourceFiles = generatorSourceFiles ?? generatorSourceCatalog();
  const generationProvenance = {
    generatorExecutionBinding: generatorExecutionBinding ??
      'LIVE_FILESYSTEM_CATALOG_UNBOUND_V1',
    generatorSourceDigestAlgorithm: 'SHA-256-JCS-FILE-CATALOG-V1',
    generatorSourceDigest: digestJson(
      sourceFiles,
      TRUSTED_GENERATION_CANONICAL_LIMITS,
    ),
    generatorSourceFiles: sourceFiles,
    targetMapDigestAlgorithm: 'SHA-256-JCS-NORMALIZED-TARGET-MAP-V1',
    targetMapDigest: digestJson(
      {formatVersion: 1, artifacts: normalizedTargets},
      TRUSTED_GENERATION_CANONICAL_LIMITS,
    ),
  };
  let manifestByteLength = 0;
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const artifactCatalog = GENERATED_FILES.map((logicalName) => {
      if (logicalName === 'profile-manifest.json') {
        return {
          logicalName,
          path: normalizedTargets[logicalName],
          byteLength: manifestByteLength,
          integrityScope: 'SELF_PATH_AND_SIZE_ONLY',
        };
      }
      const bytes = artifacts.get(logicalName);
      return {
        logicalName,
        path: normalizedTargets[logicalName],
        byteLength: Buffer.byteLength(bytes, 'utf8'),
        sha256: digestBytes(bytes),
        integrityScope: 'SHA256',
      };
    });
    const rendered = canonicalJson({
      ...base,
      artifactCatalog,
      generationProvenance,
    }, 2, TRUSTED_GENERATION_CANONICAL_LIMITS);
    const actualByteLength = Buffer.byteLength(rendered, 'utf8');
    if (actualByteLength === manifestByteLength) return rendered;
    manifestByteLength = actualByteLength;
  }
  throw new Error('profile manifest byte length did not converge');
}

const DIRECTORY_OPEN_FLAGS = fsConstants.O_RDONLY |
  (fsConstants.O_DIRECTORY ?? 0) |
  (fsConstants.O_NOFOLLOW ?? 0);

async function pathStatus(filename) {
  try {
    return await lstat(filename, {bigint: true});
  } catch (error) {
    if (error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

export async function assertOutputDirectory(outputDirectory) {
  const prepared = await walkStandaloneOutputDirectory(outputDirectory, {
    create: false,
    keepBinding: false,
  });
  return prepared.outputDirectory;
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

function directoryIdentity(status) {
  return {
    dev: status.dev,
    ino: status.ino,
  };
}

function sameDirectoryIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

async function createDirectoryWithIdentity(directory, {onCreated} = {}) {
  await mkdir(directory, {mode: 0o700});
  onCreated?.();
  const status = await lstat(directory, {bigint: true});
  if (status.isSymbolicLink() || !status.isDirectory()) {
    throw new Error(`created path is not a directory: ${directory}`);
  }
  return directoryIdentity(status);
}

async function bindDirectory(directory, {projectRoot, expectedIdentity} = {}) {
  const resolved = path.resolve(directory);
  const before = await pathStatus(resolved);
  if (before === undefined) throw new Error(`bound directory does not exist: ${resolved}`);
  if (before.isSymbolicLink()) {
    throw new Error(`bound directory must not be a symbolic link: ${resolved}`);
  }
  if (!before.isDirectory()) throw new Error(`bound path is not a directory: ${resolved}`);
  const handle = await open(resolved, DIRECTORY_OPEN_FLAGS);
  try {
    const handleStatus = await handle.stat({bigint: true});
    const canonical = await realpath(resolved);
    const after = await lstat(resolved, {bigint: true});
    const identity = directoryIdentity(handleStatus);
    if (!handleStatus.isDirectory() ||
        !after.isDirectory() ||
        after.isSymbolicLink() ||
        !sameDirectoryIdentity(directoryIdentity(before), identity) ||
        !sameDirectoryIdentity(directoryIdentity(after), identity) ||
        (expectedIdentity !== undefined &&
          !sameDirectoryIdentity(expectedIdentity, identity))) {
      throw new Error(`directory changed while it was bound: ${resolved}`);
    }
    if (projectRoot !== undefined && !isInside(path.resolve(projectRoot), canonical)) {
      throw new Error(`bound directory resolves outside projectRoot: ${resolved}`);
    }
    return {path: resolved, canonical, handle, identity};
  } catch (error) {
    await finishWithCleanup(
      error,
      () => handle.close(),
      'directory binding and handle cleanup both failed',
    );
  }
}

async function assertBoundDirectory(binding, {projectRoot} = {}) {
  const handleBefore = await binding.handle.stat({bigint: true});
  const lexicalBefore = await pathStatus(binding.path);
  if (lexicalBefore === undefined ||
      lexicalBefore.isSymbolicLink() ||
      !lexicalBefore.isDirectory()) {
    throw new Error(`bound directory was externally replaced: ${binding.path}`);
  }
  const canonical = await realpath(binding.path);
  const lexicalAfter = await lstat(binding.path, {bigint: true});
  const handleAfter = await binding.handle.stat({bigint: true});
  for (const status of [handleBefore, lexicalBefore, lexicalAfter, handleAfter]) {
    if (!status.isDirectory() ||
        !sameDirectoryIdentity(directoryIdentity(status), binding.identity)) {
      throw new Error(`bound directory was externally replaced: ${binding.path}`);
    }
  }
  if (canonical !== binding.canonical ||
      (projectRoot !== undefined && !isInside(path.resolve(projectRoot), canonical))) {
    throw new Error(`bound directory was externally replaced: ${binding.path}`);
  }
}

async function assertBoundDirectories(bindings, options) {
  for (const binding of [...new Set(bindings)]) {
    await assertBoundDirectory(binding, options);
  }
}

async function withBoundDirectories(bindings, options, action) {
  await assertBoundDirectories(bindings, options);
  let value;
  let actionFailure;
  try {
    value = await action();
  } catch (error) {
    actionFailure = error;
  }
  try {
    await assertBoundDirectories(bindings, options);
  } catch (bindingFailure) {
    throw combineFailures(
      actionFailure,
      bindingFailure,
      'directory-bound action and final verification both failed',
    );
  }
  if (actionFailure !== undefined) throw actionFailure;
  return value;
}

async function guardedMutation({
  bindings,
  afterBindings = bindings,
  hooks,
  operation,
  details = {},
  projectRoot,
}, action) {
  // Node has no renameat/linkat/unlinkat. Keep directory handles as identity
  // anchors and fail closed on lexical/realpath/dev+ino drift around each call.
  await assertBoundDirectories(bindings, {projectRoot});
  await runHook(hooks, 'beforeMutation', {operation, ...details});
  await assertBoundDirectories(bindings, {projectRoot});
  let value;
  let mutationFailure;
  let mutationCompleted = false;
  try {
    value = await action();
    mutationCompleted = true;
    await runHook(hooks, 'afterMutation', {operation, ...details});
  } catch (error) {
    mutationFailure = error;
  }
  try {
    await assertBoundDirectories(
      mutationCompleted ? afterBindings : bindings,
      {projectRoot},
    );
  } catch (bindingFailure) {
    throw combineFailures(
      mutationFailure,
      bindingFailure,
      'directory-bound mutation and final verification both failed',
    );
  }
  if (mutationFailure !== undefined) throw mutationFailure;
  return value;
}

async function closeBindings(bindings, {hooks, operation} = {}) {
  const failures = [];
  for (const binding of [...new Set(bindings)].reverse()) {
    try {
      await binding.handle.close();
    } catch (error) {
      failures.push(error);
    }
    try {
      await runHook(hooks, 'afterBindingClose', {
        operation,
        directory: binding.path,
      });
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length > 0) throw new AggregateError(failures, 'failed to close directory bindings');
}

async function canonicalizeTrustedSystemAlias(requested) {
  const parsed = path.parse(requested);
  const relative = path.relative(parsed.root, requested);
  if (relative === '') return requested;
  const segments = relative.split(path.sep);
  const alias = path.join(parsed.root, segments[0]);
  const status = await pathStatus(alias);
  if (!status?.isSymbolicLink()) return requested;
  const canonical = await realpath(alias);
  const trustedMacAlias = process.platform === 'darwin' &&
    status.uid === 0n &&
    canonical === path.join(parsed.root, 'private', segments[0]);
  if (!trustedMacAlias) {
    throw new Error(`output path must not be a symbolic link: ${alias}`);
  }
  return path.join(canonical, ...segments.slice(1));
}

async function walkStandaloneOutputDirectory(outputDirectory, {create, keepBinding}) {
  const requested = path.resolve(outputDirectory);
  const canonicalRequest = await canonicalizeTrustedSystemAlias(requested);
  const parsed = path.parse(canonicalRequest);
  const relative = path.relative(parsed.root, canonicalRequest);
  const segments = relative === '' ? [] : relative.split(path.sep);
  const bindings = [];
  let current = parsed.root;
  let currentBinding = await bindDirectory(current);
  let retainedBinding;
  bindings.push(currentBinding);
  return runWithCleanup(async () => {
    for (const segment of segments) {
      const child = path.join(current, segment);
      let status = await withBoundDirectories([currentBinding], {}, () => pathStatus(child));
      let createdIdentity;
      if (status === undefined) {
        if (!create) throw new Error(`output directory does not exist: ${requested}`);
        createdIdentity = await guardedMutation({
          bindings: [currentBinding],
          operation: 'create-standalone-directory',
          details: {directory: child},
        }, () => createDirectoryWithIdentity(child));
        status = await withBoundDirectories([currentBinding], {}, () => pathStatus(child));
      }
      if (status.isSymbolicLink()) {
        throw new Error(`output path must not be a symbolic link: ${child}`);
      }
      if (!status.isDirectory()) throw new Error(`output path is not a directory: ${child}`);
      const childBinding = await bindDirectory(child, {
        expectedIdentity: createdIdentity ?? directoryIdentity(status),
      });
      bindings.push(childBinding);
      current = child;
      currentBinding = childBinding;
    }
    await assertBoundDirectory(currentBinding);
    if (keepBinding) {
      await closeBindings(bindings.filter((binding) => binding !== currentBinding));
      retainedBinding = currentBinding;
      return {outputDirectory: currentBinding.canonical, binding: currentBinding};
    }
    return {outputDirectory: currentBinding.canonical};
  }, async () => {
    if (!keepBinding || retainedBinding === undefined) await closeBindings(bindings);
  }, 'standalone directory traversal and binding cleanup both failed');
}

export async function resolveRealProjectRoot(configuredRoot) {
  const resolved = path.resolve(configuredRoot);
  let canonical;
  try {
    canonical = await realpath(resolved);
  } catch (error) {
    throw new Error(`projectRoot cannot be resolved: ${resolved}: ${error.message}`);
  }
  const status = await lstat(canonical, {bigint: true});
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

async function traverseSecureDirectory(
  projectRoot,
  directory,
  {create = false, retainBindings = false} = {},
) {
  const root = path.resolve(projectRoot);
  const target = path.resolve(directory);
  if (!isInside(root, target)) {
    throw new Error(`directory escapes projectRoot: ${target}`);
  }
  const relative = path.relative(root, target);
  const bindings = [];
  let retained = false;
  let current = root;
  let currentBinding = await bindDirectory(root, {projectRoot: root});
  bindings.push(currentBinding);
  return runWithCleanup(async () => {
    for (const segment of relative === '' ? [] : relative.split(path.sep)) {
      const child = path.join(current, segment);
      let status = await withBoundDirectories(
        [currentBinding],
        {projectRoot: root},
        () => pathStatus(child),
      );
      let createdIdentity;
      if (status === undefined && create) {
        try {
          createdIdentity = await guardedMutation({
            bindings: [currentBinding],
            operation: 'create-mapped-directory',
            details: {directory: child},
            projectRoot: root,
          }, () => createDirectoryWithIdentity(child));
        } catch (error) {
          if (error?.code !== 'EEXIST') throw error;
        }
        status = await withBoundDirectories(
          [currentBinding],
          {projectRoot: root},
          () => pathStatus(child),
        );
      }
      if (status === undefined) throw new Error(`output directory does not exist: ${child}`);
      if (status.isSymbolicLink()) {
        throw new Error(`output path contains a symbolic link: ${child}`);
      }
      if (!status.isDirectory()) throw new Error(`output path is not a directory: ${child}`);
      const childBinding = await bindDirectory(child, {
        projectRoot: root,
        expectedIdentity: createdIdentity ?? directoryIdentity(status),
      });
      bindings.push(childBinding);
      current = child;
      currentBinding = childBinding;
    }
    await assertBoundDirectory(currentBinding, {projectRoot: root});
    if (retainBindings) {
      retained = true;
      let closed = false;
      return {
        path: target,
        canonical: currentBinding.canonical,
        assertCurrent: () => assertBoundDirectories(bindings, {projectRoot: root}),
        close: async () => {
          if (closed) return;
          await closeBindings(bindings);
          closed = true;
        },
      };
    }
    return target;
  }, async () => {
    if (!retained) await closeBindings(bindings);
  }, 'secure directory traversal and binding cleanup both failed');
}

export async function assertSecureDirectory(
  projectRoot,
  directory,
  {create = false} = {},
) {
  return traverseSecureDirectory(projectRoot, directory, {create});
}

export async function bindSecureDirectory(projectRoot, directory) {
  return traverseSecureDirectory(projectRoot, directory, {
    retainBindings: true,
  });
}

async function prepareStandaloneOutputDirectory(outputDirectory) {
  const prepared = await walkStandaloneOutputDirectory(outputDirectory, {
    create: true,
    keepBinding: true,
  });
  return {
    projectRoot: prepared.outputDirectory,
    outputDirectory: prepared.outputDirectory,
    projectRootBinding: prepared.binding,
  };
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
    ...digestAuthoritySource(model),
    ...(model.machineAuthority === null
      ? {}
      : machineAuthoritySource(model.machineAuthority)),
    ...(model.transactionAuthority === null
      ? {}
      : transactionAuthoritySource(model.transactionAuthority)),
  };
}

export function generateArtifacts(
  model,
  {
    artifactTargets,
    dartSource,
    dartFormatterVersion,
    generatorExecutionBinding,
    generatorSourceFiles,
  } = {},
) {
  const source = activeSource(model);
  const sourceDigest = digestJson(source, TRUSTED_GENERATION_CANONICAL_LIMITS);
  const digestPreimageTypeIds = discoverDigestPreimages(model).map(
    (preimage) => preimage.typeId,
  );
  const schema = generateSchema(model, sourceDigest);
  const typescript = generateTypeScript(model, sourceDigest);
  const dart = dartSource ?? generateDart(model, sourceDigest);
  const artifactDigests = {
    'contract.dart': digestBytes(dart),
    'contract.ts': digestBytes(typescript),
    'schema.json': digestBytes(schema),
  };
  const manifestBase = {
    formatVersion: 1,
    generator: '@ccpocket/conversation-contract@0.0.0-private',
    ...(dartFormatterVersion ? {dartFormatterVersion} : {}),
    profileId: model.activeProfileId,
    profileDigest: sourceDigest,
    canonicalizationProfile: CANONICALIZATION_PROFILE,
    digestPreimageTypeIds,
    typeIds: [...model.activeDefinitionIds].sort(),
    hardRuleIds: [...model.hardRules.keys()].sort(),
    vectorSetIds: [...model.vectorSets.keys()].sort(),
    vectorIds: model.activeVectors.map((vector) => vector.id).sort(),
    ...(model.machineAuthority === null ? {} : {
      machineCounts: {
        machines: model.machineAuthority.machineAuthority.machineCount,
        stateOccurrences: model.machineAuthority.machineAuthority.stateOccurrenceCount,
        edges: model.machineAuthority.machineAuthority.edgeCount,
        terminals: model.machineAuthority.machineAuthority.terminalCount,
        forbiddenEdges: model.machineAuthority.machineAuthority.forbiddenEdgeCount,
      },
      durableRouteIds: model.machineAuthority.projectionRoutes.map((route) =>
        route.registryId),
      machineTransitionSql: model.machineAuthority.machineTransitionSql.manifest,
    }),
    ...(model.transactionAuthority === null ? {} : {
      transactionCounts: {
        manifests: model.transactionAuthority.transactionManifests.length,
        applicabilityCases: model.transactionAuthority.transactionManifests.reduce(
          (count, transactionManifest) =>
            count + transactionManifest.applicabilityCases.length,
          0,
        ),
        segments: model.transactionAuthority.transactionManifests.reduce(
          (count, transactionManifest) => count + transactionManifest.segments.length,
          0,
        ),
        steps: model.transactionAuthority.transactionSteps.length,
        killPoints: model.transactionAuthority.transactionKillPoints.length,
        bridgeRoutePoints: model.transactionAuthority.bridgeRoutePointBindings.length,
      },
      transactionManifestIds: model.transactionAuthority.transactionManifests
        .map((transactionManifest) => transactionManifest.manifestId)
        .sort(),
      transactionKillPointIds: model.transactionAuthority.transactionKillPoints
        .map((killPoint) => killPoint.killPointId)
        .sort(),
    }),
    artifactDigests,
  };
  const manifest = renderProfileManifest(
    manifestBase,
    new Map([
      ['schema.json', schema],
      ['contract.ts', typescript],
      ['contract.dart', dart],
    ]),
    artifactTargets,
    generatorSourceFiles,
    generatorExecutionBinding,
  );
  return new Map([
    ['schema.json', schema],
    ['contract.ts', typescript],
    ['contract.dart', dart],
    ['profile-manifest.json', manifest],
  ]);
}

export async function writeArtifacts(
  outputDirectory,
  artifacts,
  {beforeCommit, hooks} = {},
) {
  const prepared = await prepareStandaloneOutputDirectory(outputDirectory);
  let operationFailure;
  try {
    const targets = new Map(GENERATED_FILES.map((filename) => [
      filename,
      path.join(prepared.outputDirectory, filename),
    ]));
    await writeArtifactTargets(targets, artifacts, {
      projectRoot: prepared.outputDirectory,
      projectRootBinding: prepared.projectRootBinding,
      beforeCommit,
      hooks,
    });
  } catch (error) {
    operationFailure = error;
  }
  await finishWithCleanup(
    operationFailure,
    () => closeBindings([prepared.projectRootBinding], {
      hooks,
      operation: 'close-standalone-project-root-binding',
    }),
    'artifact transaction and standalone directory binding cleanup both failed',
  );
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

export function transactionRootForTargets(projectRoot, targets) {
  const transactionRoot = commonAncestor([...targets.values()]);
  if (!isInside(projectRoot, transactionRoot)) {
    throw new Error(`artifact transaction root escapes projectRoot: ${transactionRoot}`);
  }
  return transactionRoot;
}

export function transactionRootsForTargets(projectRoot, targets) {
  const root = path.resolve(projectRoot);
  const transactionRoot = transactionRootForTargets(root, targets);
  const roots = new Set([root, transactionRoot]);
  for (const target of targets.values()) {
    const directory = path.dirname(path.resolve(target));
    if (!isInside(root, directory)) {
      throw new Error(`artifact target directory escapes projectRoot: ${directory}`);
    }
    const relative = path.relative(root, directory);
    let current = root;
    for (const segment of relative === '' ? [] : relative.split(path.sep)) {
      current = path.join(current, segment);
      roots.add(current);
    }
  }
  return [...roots].sort((left, right) => {
    const depth = (value) => path.relative(root, value).split(path.sep).filter(Boolean).length;
    return depth(left) - depth(right) || left.localeCompare(right);
  });
}

export async function findTransactionResidues(roots) {
  const residues = [];
  for (const root of roots) {
    let entries;
    try {
      entries = await readdir(root);
    } catch (error) {
      if (error?.code === 'ENOENT') continue;
      throw error;
    }
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

function hasExecutableMode(status) {
  if (process.platform === 'win32') return false;
  return (status.mode & 0o111n) !== 0n;
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
    const after = await lstat(filename, {bigint: true});
    if (before.dev !== after.dev ||
        before.ino !== after.ino ||
        before.size !== after.size ||
        hasExecutableMode(before) !== hasExecutableMode(after) ||
        BigInt(content.length) !== after.size ||
        !after.isFile()) {
      throw new Error(`artifact changed while its identity was recorded: ${filename}`);
    }
    identity.size = after.size;
    identity.digest = digestBytes(content);
    identity.executable = hasExecutableMode(after);
  }
  return identity;
}

function sameIdentity(left, right) {
  if (left === undefined || right === undefined) return left === right;
  return left.kind === right.kind &&
    left.dev === right.dev &&
    left.ino === right.ino &&
    (left.kind !== 'file' || (
      left.size === right.size &&
      left.digest === right.digest &&
      left.executable === right.executable
    ));
}

async function runHook(hooks, name, details) {
  const hook = hooks?.[name];
  if (hook !== undefined) await hook(details);
}

async function stablePathIdentity(filename, binding, projectRoot) {
  return withBoundDirectories(
    [binding],
    {projectRoot},
    () => pathIdentity(filename),
  );
}

async function assertInstalledArtifacts(installed, projectRoot) {
  const targetParentBindings = [
    ...new Set(installed.map((record) => record.targetParentBinding)),
  ];
  await assertBoundDirectories(targetParentBindings, {projectRoot});
  for (const record of installed) {
    const current = await stablePathIdentity(
      record.target,
      record.targetParentBinding,
      projectRoot,
    );
    if (!sameIdentity(current, record.identity) || current?.executable === true) {
      throw new Error(`installed artifact changed before commit: ${record.target}`);
    }
  }
  await assertBoundDirectories(targetParentBindings, {projectRoot});
}

async function rollbackTransaction({installed, backedUp, hooks, projectRoot}) {
  for (const record of [...installed].reverse()) {
    await runHook(hooks, 'beforeRollbackRemove', record);
    const current = await stablePathIdentity(
      record.target,
      record.targetParentBinding,
      projectRoot,
    );
    if (current === undefined) continue;
    if (!sameIdentity(current, record.identity)) {
      throw new Error(`installed artifact was externally replaced: ${record.target}`);
    }
    await guardedMutation({
      bindings: [record.targetParentBinding],
      hooks,
      operation: 'rollback-remove-installed',
      details: {filename: record.filename, target: record.target},
      projectRoot,
    }, async () => {
      if (!sameIdentity(await pathIdentity(record.target), record.identity)) {
        throw new Error(`installed artifact was externally replaced: ${record.target}`);
      }
      await unlink(record.target);
    });
    if (await stablePathIdentity(record.target, record.targetParentBinding, projectRoot)) {
      throw new Error(`installed artifact reappeared during rollback: ${record.target}`);
    }
  }
  for (const record of [...backedUp].reverse()) {
    await runHook(hooks, 'beforeRollbackRestore', record);
    if (await stablePathIdentity(record.target, record.targetParentBinding, projectRoot)) {
      throw new Error(`rollback target is occupied: ${record.target}`);
    }
    const currentBackup = await stablePathIdentity(
      record.backup,
      record.backupBinding,
      projectRoot,
    );
    if (!sameIdentity(currentBackup, record.identity)) {
      throw new Error(`artifact backup was externally replaced: ${record.backup}`);
    }
    await guardedMutation({
      bindings: [record.backupBinding, record.targetParentBinding],
      hooks,
      operation: 'rollback-restore-backup',
      details: {
        filename: record.filename,
        target: record.target,
        backup: record.backup,
      },
      projectRoot,
    }, async () => {
      if (await pathStatus(record.target)) {
        throw new Error(`rollback target is occupied: ${record.target}`);
      }
      if (!sameIdentity(await pathIdentity(record.backup), record.identity)) {
        throw new Error(`artifact backup was externally replaced: ${record.backup}`);
      }
      await rename(record.backup, record.target);
    });
    if (!sameIdentity(
      await stablePathIdentity(record.target, record.targetParentBinding, projectRoot),
      record.identity,
    )) {
      throw new Error(`artifact changed while its backup was restored: ${record.target}`);
    }
    if (await stablePathIdentity(record.backup, record.backupBinding, projectRoot)) {
      throw new Error(`artifact backup remained after restore: ${record.backup}`);
    }
  }
}

async function readBoundDirectory(binding, projectRoot) {
  return withBoundDirectories(
    [binding],
    {projectRoot},
    () => readdir(binding.path),
  );
}

async function removeRecordedEntry({
  filename,
  expectedIdentity,
  parentBinding,
  hooks,
  operation,
  projectRoot,
}) {
  const current = await stablePathIdentity(filename, parentBinding, projectRoot);
  if (!sameIdentity(current, expectedIdentity)) {
    throw new Error(`transaction entry was externally replaced: ${filename}`);
  }
  await guardedMutation({
    bindings: [parentBinding],
    hooks,
    operation,
    details: {path: filename},
    projectRoot,
  }, async () => {
    if (!sameIdentity(await pathIdentity(filename), expectedIdentity)) {
      throw new Error(`transaction entry was externally replaced: ${filename}`);
    }
    await unlink(filename);
  });
  if (await stablePathIdentity(filename, parentBinding, projectRoot)) {
    throw new Error(`transaction entry reappeared during cleanup: ${filename}`);
  }
}

async function removeBoundDirectory({
  binding,
  parentBinding,
  hooks,
  operation,
  projectRoot,
}) {
  if ((await readBoundDirectory(binding, projectRoot)).length !== 0) {
    throw new Error(`transaction directory is not empty: ${binding.path}`);
  }
  await guardedMutation({
    bindings: [parentBinding, binding],
    afterBindings: [parentBinding],
    hooks,
    operation,
    details: {directory: binding.path},
    projectRoot,
  }, async () => {
    const current = await pathStatus(binding.path);
    if (current === undefined ||
        !current.isDirectory() ||
        !sameDirectoryIdentity(directoryIdentity(current), binding.identity)) {
      throw new Error(`transaction directory was externally replaced: ${binding.path}`);
    }
    if ((await readdir(binding.path)).length !== 0) {
      throw new Error(`transaction directory is not empty: ${binding.path}`);
    }
    await rmdir(binding.path);
  });
  if (await withBoundDirectories(
    [parentBinding],
    {projectRoot},
    () => pathStatus(binding.path),
  )) {
    throw new Error(`transaction directory reappeared during cleanup: ${binding.path}`);
  }
}

async function cleanupTransaction({
  transactionRootBinding,
  stageBinding,
  newBinding,
  backupBinding,
  lockBinding,
  stagedRecords,
  backedUp,
  hooks,
  projectRoot,
}) {
  const stageDirectory = stageBinding.path;
  const lockDirectory = lockBinding.path;
  await runHook(hooks, 'beforeStageCleanup', {stageDirectory, lockDirectory});
  await assertBoundDirectories(
    [transactionRootBinding, stageBinding, newBinding, backupBinding, lockBinding],
    {projectRoot},
  );
  const stageEntries = (await readBoundDirectory(stageBinding, projectRoot)).sort();
  if (JSON.stringify(stageEntries) !== JSON.stringify(['backup', 'new'])) {
    throw new Error(`transaction stage contains unexpected entries: ${stageDirectory}`);
  }
  const newEntries = await readBoundDirectory(newBinding, projectRoot);
  const backupEntries = await readBoundDirectory(backupBinding, projectRoot);
  for (const filename of [...newEntries, ...backupEntries]) {
    if (!GENERATED_FILES.includes(filename)) {
      throw new Error(`transaction stage contains unexpected entry: ${filename}`);
    }
  }
  const backupsByFilename = new Map(backedUp.map((record) => [record.filename, record]));
  for (const filename of newEntries) {
    const record = stagedRecords.get(filename);
    if (record === undefined || !sameIdentity(
      await stablePathIdentity(record.staged, newBinding, projectRoot),
      record.identity,
    )) {
      throw new Error(`transaction stage has invalid artifact: ${filename}`);
    }
  }
  for (const filename of backupEntries) {
    const record = backupsByFilename.get(filename);
    if (record === undefined || !sameIdentity(
      await stablePathIdentity(record.backup, backupBinding, projectRoot),
      record.identity,
    )) {
      throw new Error(`transaction stage has invalid backup: ${filename}`);
    }
  }

  await runHook(hooks, 'beforeLockCleanup', {stageDirectory, lockDirectory});
  await removeBoundDirectory({
    binding: lockBinding,
    parentBinding: transactionRootBinding,
    hooks,
    operation: 'cleanup-lock-directory',
    projectRoot,
  });

  for (const filename of newEntries) {
    const record = stagedRecords.get(filename);
    await removeRecordedEntry({
      filename: record.staged,
      expectedIdentity: record.identity,
      parentBinding: newBinding,
      hooks,
      operation: 'cleanup-staged-artifact',
      projectRoot,
    });
  }
  for (const filename of backupEntries) {
    const record = backupsByFilename.get(filename);
    await removeRecordedEntry({
      filename: record.backup,
      expectedIdentity: record.identity,
      parentBinding: backupBinding,
      hooks,
      operation: 'cleanup-backup-artifact',
      projectRoot,
    });
  }
  await removeBoundDirectory({
    binding: newBinding,
    parentBinding: stageBinding,
    hooks,
    operation: 'cleanup-new-directory',
    projectRoot,
  });
  await removeBoundDirectory({
    binding: backupBinding,
    parentBinding: stageBinding,
    hooks,
    operation: 'cleanup-backup-directory',
    projectRoot,
  });
  await removeBoundDirectory({
    binding: stageBinding,
    parentBinding: transactionRootBinding,
    hooks,
    operation: 'cleanup-stage-directory',
    projectRoot,
  });
}

function recoveryError(
  {transactionRoot, stageDirectory, lockDirectory},
  original,
  recoveryFailure,
) {
  const errors = original === recoveryFailure
    ? [original]
    : [original, recoveryFailure];
  return new AggregateError(
    errors,
    `artifact transaction failed and automatic recovery stopped; ` +
    `inspect last-known transaction locations under ${transactionRoot} ` +
    `(stage ${stageDirectory}; lock ${lockDirectory}; either may already be absent): ` +
    `original failure: ${original.message}; ` +
    `recovery/cleanup failure: ${recoveryFailure.message}`,
  );
}

export async function writeArtifactTargets(
  targets,
  artifacts,
  {projectRoot, projectRootBinding, hooks, beforeCommit} = {},
) {
  if (projectRoot === undefined) {
    throw new Error('projectRoot is required for mapped artifact generation');
  }
  const configuredProjectRoot = path.resolve(projectRoot);
  const realProjectRoot = projectRootBinding?.canonical ??
    await resolveRealProjectRoot(projectRoot);
  if (projectRootBinding !== undefined) {
    if (projectRootBinding.path !== configuredProjectRoot ||
        projectRootBinding.canonical !== realProjectRoot) {
      throw new Error('provided projectRoot binding does not match projectRoot');
    }
    await assertBoundDirectory(projectRootBinding, {projectRoot: realProjectRoot});
  }
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
  const ownedBindings = [];
  const bindingsByPath = new Map();
  if (projectRootBinding !== undefined) {
    bindingsByPath.set(projectRootBinding.path, projectRootBinding);
  }
  async function bindingFor(directory, {expectedIdentity} = {}) {
    const resolved = path.resolve(directory);
    const existing = bindingsByPath.get(resolved);
    if (existing !== undefined) {
      if (expectedIdentity !== undefined &&
          !sameDirectoryIdentity(existing.identity, expectedIdentity)) {
        throw new Error(`directory changed before it was rebound: ${resolved}`);
      }
      return existing;
    }
    const binding = await bindDirectory(resolved, {
      projectRoot: realProjectRoot,
      expectedIdentity,
    });
    bindingsByPath.set(resolved, binding);
    ownedBindings.push(binding);
    return binding;
  }

  let operationFailure;
  try {
    const targetParentBindings = new Map();
    for (const target of normalizedTargets.values()) {
      const parent = path.dirname(target);
      await assertSecureDirectory(realProjectRoot, parent, {create: true});
      const parentBinding = await bindingFor(parent);
      targetParentBindings.set(parent, parentBinding);
      const status = await withBoundDirectories(
        [parentBinding],
        {projectRoot: realProjectRoot},
        () => pathStatus(target),
      );
      if (status?.isDirectory()) throw new Error(`artifact target is a directory: ${target}`);
      if (status !== undefined && !status.isFile() && !status.isSymbolicLink()) {
        throw new Error(`artifact target has an unsupported file type: ${target}`);
      }
    }

    const transactionRoots = transactionRootsForTargets(realProjectRoot, normalizedTargets);
    const transactionRoot = transactionRootForTargets(realProjectRoot, normalizedTargets);
    for (const root of transactionRoots) {
      await assertSecureDirectory(realProjectRoot, root);
    }
    const residues = await findTransactionResidues(transactionRoots);
    if (residues.length > 0) {
      throw new Error(`unfinished artifact transaction: ${residues.join(', ')}`);
    }
    const transactionRootBinding = await bindingFor(transactionRoot);
    const lockDirectory = path.join(transactionRoot, TRANSACTION_LOCK_NAME);
    const stageDirectory = path.join(
      transactionRoot,
      `${TRANSACTION_STAGE_PREFIX}${randomUUID()}`,
    );
    const newDirectory = path.join(stageDirectory, 'new');
    const backupDirectory = path.join(stageDirectory, 'backup');
    const recoveryLocations = {transactionRoot, stageDirectory, lockDirectory};
    const backedUp = [];
    const installed = [];
    const stagedRecords = new Map();

    let lockBinding;
    let lockCreated = false;
    try {
      const createdLockIdentity = await guardedMutation({
        bindings: [transactionRootBinding],
        hooks,
        operation: 'create-lock-directory',
        details: {lockDirectory},
        projectRoot: realProjectRoot,
      }, () => createDirectoryWithIdentity(lockDirectory, {
        onCreated() {
          lockCreated = true;
        },
      }));
      lockBinding = await bindingFor(lockDirectory, {
        expectedIdentity: createdLockIdentity,
      });
    } catch (error) {
      if (error?.code === 'EEXIST') {
        throw new Error(`artifact generation is already locked: ${transactionRoot}`);
      }
      if (lockCreated) throw recoveryError(recoveryLocations, error, error);
      throw error;
    }

    let stageBinding;
    let newBinding;
    let backupBinding;
    try {
      const createdStageIdentity = await guardedMutation({
        bindings: [transactionRootBinding],
        hooks,
        operation: 'create-stage-directory',
        details: {stageDirectory},
        projectRoot: realProjectRoot,
      }, () => createDirectoryWithIdentity(stageDirectory));
      stageBinding = await bindingFor(stageDirectory, {
        expectedIdentity: createdStageIdentity,
      });
      const createdNewIdentity = await guardedMutation({
        bindings: [stageBinding],
        hooks,
        operation: 'create-stage-new-directory',
        details: {newDirectory},
        projectRoot: realProjectRoot,
      }, () => createDirectoryWithIdentity(newDirectory));
      newBinding = await bindingFor(newDirectory, {
        expectedIdentity: createdNewIdentity,
      });
      const createdBackupIdentity = await guardedMutation({
        bindings: [stageBinding],
        hooks,
        operation: 'create-stage-backup-directory',
        details: {backupDirectory},
        projectRoot: realProjectRoot,
      }, () => createDirectoryWithIdentity(backupDirectory));
      backupBinding = await bindingFor(backupDirectory, {
        expectedIdentity: createdBackupIdentity,
      });
    } catch (setupFailure) {
      throw recoveryError(recoveryLocations, setupFailure, setupFailure);
    }

    let transactionFailure;
    try {
      for (const filename of GENERATED_FILES) {
        const content = artifacts.get(filename);
        if (content === undefined) throw new Error(`missing generated artifact ${filename}`);
        const staged = path.join(newDirectory, filename);
        await guardedMutation({
          bindings: [newBinding],
          hooks,
          operation: 'write-staged-artifact',
          details: {filename, staged, newDirectory, backupDirectory, stageDirectory},
          projectRoot: realProjectRoot,
        }, () => writeFile(staged, content, {encoding: 'utf8', flag: 'wx'}));
        const identity = await stablePathIdentity(staged, newBinding, realProjectRoot);
        if (identity === undefined || identity.kind !== 'file') {
          throw new Error(`staged artifact is not a regular file: ${staged}`);
        }
        stagedRecords.set(filename, {filename, staged, identity});
      }

      for (const filename of GENERATED_FILES) {
        const target = normalizedTargets.get(filename);
        const targetParentBinding = targetParentBindings.get(path.dirname(target));
        const identity = await stablePathIdentity(
          target,
          targetParentBinding,
          realProjectRoot,
        );
        if (identity === undefined) continue;
        const backup = path.join(backupDirectory, filename);
        const record = {
          filename,
          target,
          backup,
          identity,
          targetParentBinding,
          backupBinding,
        };
        await guardedMutation({
          bindings: [targetParentBinding, backupBinding],
          hooks,
          operation: 'backup-target',
          details: {filename, target, backup, newDirectory, backupDirectory, stageDirectory},
          projectRoot: realProjectRoot,
        }, async () => {
          if (!sameIdentity(await pathIdentity(target), identity)) {
            throw new Error(`artifact changed before it was backed up: ${target}`);
          }
          if (await pathStatus(backup)) {
            throw new Error(`artifact backup path is occupied: ${backup}`);
          }
          await rename(target, backup);
        });
        backedUp.push(record);
        if (!sameIdentity(
          await stablePathIdentity(backup, backupBinding, realProjectRoot),
          identity,
        ) || await stablePathIdentity(target, targetParentBinding, realProjectRoot)) {
          throw new Error(`artifact changed while it was backed up: ${target}`);
        }
        await runHook(hooks, 'afterBackup', record);
      }
      for (const filename of GENERATED_FILES) {
        const target = normalizedTargets.get(filename);
        const targetParentBinding = targetParentBindings.get(path.dirname(target));
        const stagedRecord = stagedRecords.get(filename);
        const record = {
          filename,
          target,
          identity: stagedRecord.identity,
          targetParentBinding,
        };
        await guardedMutation({
          bindings: [newBinding, targetParentBinding],
          hooks,
          operation: 'install-target',
          details: {
            filename,
            target,
            staged: stagedRecord.staged,
            newDirectory,
            backupDirectory,
            stageDirectory,
          },
          projectRoot: realProjectRoot,
        }, async () => {
          if (!sameIdentity(await pathIdentity(stagedRecord.staged), stagedRecord.identity)) {
            throw new Error(`staged artifact was externally replaced: ${stagedRecord.staged}`);
          }
          if (await pathStatus(target)) {
            throw new Error(`artifact target is occupied during install: ${target}`);
          }
          await link(stagedRecord.staged, target);
        });
        installed.push(record);
        if (!sameIdentity(
          await stablePathIdentity(target, targetParentBinding, realProjectRoot),
          record.identity,
        )) {
          throw new Error(`artifact changed while it was installed: ${target}`);
        }
        await guardedMutation({
          bindings: [newBinding],
          hooks,
          operation: 'remove-staged-link',
          details: {filename, staged: stagedRecord.staged},
          projectRoot: realProjectRoot,
        }, async () => {
          if (!sameIdentity(await pathIdentity(stagedRecord.staged), stagedRecord.identity)) {
            throw new Error(`staged artifact was externally replaced: ${stagedRecord.staged}`);
          }
          await unlink(stagedRecord.staged);
        });
        if (await stablePathIdentity(stagedRecord.staged, newBinding, realProjectRoot)) {
          throw new Error(`staged artifact reappeared after install: ${stagedRecord.staged}`);
        }
        await runHook(hooks, 'afterInstall', record);
      }
      // The new targets are visible, but their exact prior objects remain in
      // the transaction backup. Final provenance verification belongs here so
      // a failure follows the ordinary rollback path before cleanup commits
      // the artifact set by deleting those backups.
      if (beforeCommit !== undefined) await beforeCommit();
      // beforeCommit may perform asynchronous source verification while the
      // installed targets are already visible. Rebind the successful result
      // to the exact target objects and their retained parent directories
      // before cleanup deletes the recoverable old artifact set.
      await assertInstalledArtifacts(installed, realProjectRoot);
    } catch (error) {
      transactionFailure = error;
    }

    if (transactionFailure !== undefined) {
      try {
        await rollbackTransaction({
          installed,
          backedUp,
          hooks,
          projectRoot: realProjectRoot,
        });
      } catch (rollbackFailure) {
        throw recoveryError(recoveryLocations, transactionFailure, rollbackFailure);
      }
      try {
        await cleanupTransaction({
          transactionRootBinding,
          stageBinding,
          newBinding,
          backupBinding,
          lockBinding,
          stagedRecords,
          backedUp,
          hooks,
          projectRoot: realProjectRoot,
        });
      } catch (cleanupFailure) {
        throw recoveryError(recoveryLocations, transactionFailure, cleanupFailure);
      }
      throw transactionFailure;
    }

    try {
      await cleanupTransaction({
        transactionRootBinding,
        stageBinding,
        newBinding,
        backupBinding,
        lockBinding,
        stagedRecords,
        backedUp,
        hooks,
        projectRoot: realProjectRoot,
      });
    } catch (cleanupFailure) {
      throw recoveryError(recoveryLocations, cleanupFailure, cleanupFailure);
    }
  } catch (error) {
    operationFailure = error;
  }
  await finishWithCleanup(
    operationFailure,
    () => closeBindings(ownedBindings, {
      hooks,
      operation: 'close-owned-bindings',
    }),
    'artifact transaction and directory binding cleanup both failed',
  );
}
