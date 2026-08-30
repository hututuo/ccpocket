export const CANONICALIZATION_PROFILE = 'RFC8785-IJSON-SAFE-INTEGER-V1';
export const SHA256_HEX_TYPE_ID = 'Sha256Hex64';

function fail(typeId, message) {
  throw new Error(`digest preimage ${typeId}: ${message}`);
}

function requiredDigestDomain(fields, typeId, branch) {
  const matches = fields.filter((field) => field.name === 'digestDomain');
  if (matches.length !== 1) {
    fail(typeId, `${branch} must declare exactly one digestDomain field`);
  }
  const field = matches[0];
  if (!field.required) {
    fail(typeId, `${branch}.digestDomain must be required`);
  }
  if (field.type.kind !== 'enum' || field.type.values.length !== 1) {
    fail(typeId, `${branch}.digestDomain must be a single-valued enum const`);
  }
  return field.type.values[0];
}

function assertClosedNode(node, model, typeId, path, visitedDefinitions) {
  switch (node.kind) {
    case 'string':
    case 'integer':
    case 'boolean':
    case 'enum':
      return;
    case 'array':
      assertClosedNode(node.items, model, typeId, `${path}[]`, visitedDefinitions);
      return;
    case 'map':
      fail(typeId, `${path} reaches an open map`);
      return;
    case 'object':
      for (const field of node.fields) {
        assertClosedNode(
          field.type,
          model,
          typeId,
          `${path}.${field.name}`,
          visitedDefinitions,
        );
      }
      return;
    case 'union':
      for (const variant of node.variants) {
        for (const field of variant.fields) {
          assertClosedNode(
            field.type,
            model,
            typeId,
            `${path}<${variant.tag}>.${field.name}`,
            visitedDefinitions,
          );
        }
      }
      return;
    case 'ref': {
      if (visitedDefinitions.has(node.target)) return;
      const target = model.definitions.get(node.target);
      if (!target || !model.activeDefinitionIds.has(node.target)) {
        fail(typeId, `${path} references inactive definition ${node.target}`);
      }
      visitedDefinitions.add(node.target);
      assertClosedNode(
        target.node,
        model,
        typeId,
        `${path}->${node.target}`,
        visitedDefinitions,
      );
      return;
    }
    default:
      fail(typeId, `${path} has unsupported node kind ${node.kind}`);
  }
}

/**
 * Finds the only definition family authorized for generated JCS hashing.
 * Active reachability has already been computed by validateInputs().
 */
export function discoverDigestPreimages(model) {
  const preimages = [];
  for (const typeId of [...model.activeDefinitionIds].sort()) {
    if (!typeId.endsWith('PreimageV1')) continue;
    const definition = model.definitions.get(typeId);
    const node = definition?.node;
    if (!node || (node.kind !== 'object' && node.kind !== 'union')) {
      fail(typeId, 'the named preimage root must be a closed object or union');
    }
    assertClosedNode(node, model, typeId, '$', new Set([typeId]));
    if (node.kind === 'object') {
      preimages.push({
        typeId,
        domainRule: {
          kind: 'object',
          value: requiredDigestDomain(node.fields, typeId, '$'),
        },
      });
      continue;
    }
    preimages.push({
      typeId,
      domainRule: {
        kind: 'union',
        discriminator: node.discriminator,
        variants: node.variants.map((variant) => ({
          tag: variant.tag,
          value: requiredDigestDomain(
            variant.fields,
            typeId,
            `$<${variant.tag}>`,
          ),
        })),
      },
    });
  }
  return preimages;
}
