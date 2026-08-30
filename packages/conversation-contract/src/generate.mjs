import { mkdir, rename, writeFile } from 'node:fs/promises';
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
    profile: model.activeProfile,
    definitions: [...model.activeDefinitionIds]
      .sort()
      .map((id) => model.definitions.get(id)),
    owners: [...ownerIds].sort().map((id) => model.owners.get(id)),
    consumers: [...consumerIds].sort().map((id) => model.consumers.get(id)),
    executableTests: [...testIds].sort().map((id) => model.executableTests.get(id)),
    hardRules,
    vectorSets: [...model.vectorSets.values()].sort(byId),
    vectors: [...model.activeVectors].sort(byId),
  };
}

export function generateArtifacts(model) {
  const source = activeSource(model);
  const sourceDigest = digestJson(source);
  const schema = generateSchema(model, sourceDigest);
  const typescript = generateTypeScript(model, sourceDigest);
  const dart = generateDart(model, sourceDigest);
  const artifactDigests = {
    'contract.dart': digestBytes(dart),
    'contract.ts': digestBytes(typescript),
    'schema.json': digestBytes(schema),
  };
  const manifest = canonicalJson({
    formatVersion: 1,
    generator: '@ccpocket/conversation-contract@0.0.0-private',
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
  await mkdir(outputDirectory, {recursive: true});
  for (const filename of GENERATED_FILES) {
    const content = artifacts.get(filename);
    if (content === undefined) throw new Error(`missing generated artifact ${filename}`);
    const destination = path.join(outputDirectory, filename);
    const temporary = `${destination}.tmp`;
    await writeFile(temporary, content, 'utf8');
    await rename(temporary, destination);
  }
}
