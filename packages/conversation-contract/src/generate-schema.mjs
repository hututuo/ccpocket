import { canonicalJson } from './canonical.mjs';

function objectSchema(fields, schemaForNode, extraProperties = {}) {
  const properties = {...extraProperties};
  const required = Object.keys(extraProperties);
  for (const field of fields) {
    properties[field.name] = schemaForNode(field.type);
    if (field.required) required.push(field.name);
  }
  return {
    type: 'object',
    properties,
    required: [...new Set(required)].sort(),
    additionalProperties: false,
  };
}

export function generateSchema(model, sourceDigest) {
  const schemaForNode = (node) => {
    switch (node.kind) {
      case 'string': return {type: 'string'};
      case 'integer':
        return {
          type: 'integer',
          minimum: Number.MIN_SAFE_INTEGER,
          maximum: Number.MAX_SAFE_INTEGER,
        };
      case 'boolean': return {type: 'boolean'};
      case 'enum': return {type: 'string', enum: [...node.values]};
      case 'ref': return {$ref: `#/$defs/${node.target}`};
      case 'array': return {type: 'array', items: schemaForNode(node.items)};
      case 'map': return {type: 'object', additionalProperties: schemaForNode(node.values)};
      case 'object': return objectSchema(node.fields, schemaForNode);
      case 'union':
        return {
          oneOf: node.variants.map((variant) => objectSchema(
            variant.fields,
            schemaForNode,
            {[node.discriminator]: {const: variant.tag}},
          )),
        };
      default:
        throw new Error(`unsupported schema node kind ${node.kind}`);
    }
  };

  const definitionIds = [...model.activeDefinitionIds].sort();
  const definitions = Object.fromEntries(
    definitionIds.map((id) => [id, schemaForNode(model.definitions.get(id).node)]),
  );
  const roots = [...model.activeProfile.rootTypeRefs].sort().map((id) => ({$ref: `#/$defs/${id}`}));
  const document = {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: `urn:ccpocket:conversation-contract:${model.activeProfileId}:${sourceDigest}`,
    title: `CC Pocket conversation contract (${model.activeProfileId})`,
    oneOf: roots,
    $defs: definitions,
  };
  return canonicalJson(document);
}
