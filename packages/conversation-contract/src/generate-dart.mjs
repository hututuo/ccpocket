import {
  SHA256_HEX_TYPE_ID,
  discoverDigestPreimages,
} from './digest-preimages.mjs';
import { dartMemberName, enumMemberName, pascalName } from './names.mjs';

function dartString(value) {
  return JSON.stringify(value).replace(/\$/g, '\\$');
}

function hasOwn(value, key) {
  return Object.hasOwn(value, key);
}

function collectDeclarations(node, name, declarations) {
  if (['object', 'enum', 'union', 'oneOf'].includes(node.kind)) {
    if (declarations.has(name)) throw new Error(`Dart declaration name collision: ${name}`);
    declarations.set(name, node);
  }
  if (node.kind === 'object') {
    for (const field of node.fields) collectDeclarations(field.type, `${name}${pascalName(field.name)}`, declarations);
  } else if (node.kind === 'union') {
    for (const variant of node.variants) {
      const variantName = `${name}${pascalName(variant.tag)}`;
      for (const field of variant.fields) {
        collectDeclarations(field.type, `${variantName}${pascalName(field.name)}`, declarations);
      }
    }
  } else if (node.kind === 'oneOf') {
    for (const [index, variant] of node.variants.entries()) {
      collectDeclarations(variant, `${name}Variant${index + 1}Value`, declarations);
    }
  } else if (node.kind === 'array') {
    collectDeclarations(node.items, `${name}Item`, declarations);
  } else if (node.kind === 'nullable') {
    collectDeclarations(node.inner, `${name}Value`, declarations);
  } else if (node.kind === 'map') {
    collectDeclarations(node.values, `${name}Value`, declarations);
  }
}

function dartType(node, name) {
  switch (node.kind) {
    case 'string': return 'String';
    case 'integer': return 'int';
    case 'boolean': return 'bool';
    case 'enum':
    case 'object':
    case 'oneOf':
    case 'union': return name;
    case 'ref': return pascalName(node.target);
    case 'nullable': return `${dartType(node.inner, `${name}Value`)}?`;
    case 'array': return `List<${dartType(node.items, `${name}Item`)}>`;
    case 'map': return `Map<String, ${dartType(node.values, `${name}Value`)}>`;
    default: throw new Error(`unsupported Dart node kind ${node.kind}`);
  }
}

function dereferenceNode(node, definitions) {
  let current = node;
  const seen = new Set();
  while (current.kind === 'ref') {
    if (seen.has(current.target)) throw new Error(`Dart selector reference cycle through ${current.target}`);
    seen.add(current.target);
    current = definitions.get(current.target).node;
  }
  return current;
}

function selectedFieldNodes(itemNode, selector, definitions) {
  if (selector === '$') return [dereferenceNode(itemNode, definitions)];
  let nodes = [itemNode];
  for (const segment of selector.split('.')) {
    const next = [];
    for (const rawNode of nodes) {
      const node = dereferenceNode(rawNode, definitions);
      if (node.kind === 'object') {
        next.push(node.fields.find((field) => field.name === segment).type);
      } else if (node.kind === 'union') {
        if (segment === node.discriminator) {
          next.push({kind: 'enum', values: node.variants.map((variant) => variant.tag)});
        } else {
          for (const variant of node.variants) {
            next.push(variant.fields.find((field) => field.name === segment).type);
          }
        }
      } else if (node.kind === 'oneOf') {
        for (const variant of node.variants) {
          next.push(...selectedFieldNodes(variant, segment, definitions));
        }
      } else {
        throw new Error(`Dart collection selector ${selector} does not resolve through an object`);
      }
    }
    nodes = next;
  }
  return nodes;
}

function selectorEnumOrder(itemNode, selector, definitions) {
  const values = [];
  const seen = new Set();
  for (const rawNode of selectedFieldNodes(itemNode, selector, definitions)) {
    let node = dereferenceNode(rawNode, definitions);
    if (node.kind === 'nullable') node = dereferenceNode(node.inner, definitions);
    if (node.kind !== 'enum') continue;
    for (const value of node.values) {
      if (seen.has(value)) continue;
      seen.add(value);
      values.push(value);
    }
  }
  return values;
}

function dartStringList(values) {
  return `[${values.map(dartString).join(', ')}]`;
}

function dartArrayConstraintArguments(node, name, definitions) {
  const argumentsList = [];
  if (node.minItems !== undefined) argumentsList.push(`minItems: ${node.minItems}`);
  if (node.maxItems !== undefined) argumentsList.push(`maxItems: ${node.maxItems}`);
  if (node.uniqueItems !== undefined) argumentsList.push(`uniqueItems: ${node.uniqueItems}`);
  if (node.uniqueBy !== undefined) {
    argumentsList.push(`uniqueBy: const ${dartStringList(node.uniqueBy)}`);
  }
  if (node.orderBy !== undefined) {
    const selectors = node.orderBy.map((selector) => {
      const enumOrder = selectorEnumOrder(node.items, selector, definitions);
      return `_CollectionSelector(${dartString(selector)}${enumOrder.length > 0 ? `, ${dartStringList(enumOrder)}` : ''})`;
    });
    argumentsList.push(`orderBy: const [${selectors.join(', ')}]`);
  }
  if (node.uniqueItems || node.uniqueBy !== undefined || node.orderBy !== undefined) {
    argumentsList.push(`snapshot: (value) => ${encodeExpression(node.items, 'value', `${name}Item`, definitions)}`);
  }
  return argumentsList.length > 0 ? `, ${argumentsList.join(', ')}` : '';
}

function decodeExpression(node, expression, name, path, definitions) {
  switch (node.kind) {
    case 'string': {
      if (!hasOwn(node, 'const') && node.pattern === undefined) {
        return `_expectString(${expression}, ${dartString(path)})`;
      }
      const argumentsList = [expression, dartString(path)];
      if (hasOwn(node, 'const')) argumentsList.push(`constValue: ${dartString(node.const)}`);
      if (node.pattern !== undefined) argumentsList.push(`pattern: ${dartString(node.pattern)}`);
      return `_expectConstrainedString(${argumentsList.join(', ')})`;
    }
    case 'integer': {
      if (!hasOwn(node, 'const') && node.minimum === undefined && node.maximum === undefined) {
        return `_expectInt(${expression}, ${dartString(path)})`;
      }
      const argumentsList = [expression, dartString(path)];
      if (hasOwn(node, 'const')) argumentsList.push(`constValue: ${node.const}`);
      if (node.minimum !== undefined) argumentsList.push(`minimum: ${node.minimum}`);
      if (node.maximum !== undefined) argumentsList.push(`maximum: ${node.maximum}`);
      return `_expectConstrainedInt(${argumentsList.join(', ')})`;
    }
    case 'boolean': return hasOwn(node, 'const')
      ? `_expectConstBool(${expression}, ${dartString(path)}, ${node.const})`
      : `_expectBool(${expression}, ${dartString(path)})`;
    case 'enum': {
      const decoded = hasOwn(node, 'const')
        ? `_expectConstString(${expression}, ${dartString(path)}, ${dartString(node.const)})`
        : `_expectString(${expression}, ${dartString(path)})`;
      return `${name}.fromWire(${decoded})`;
    }
    case 'object':
    case 'union': return `${name}.fromJson(_expectMap(${expression}, ${dartString(path)}))`;
    case 'oneOf': return `${name}.fromJsonValue(${expression})`;
    case 'ref': {
      if (node.target === SHA256_HEX_TYPE_ID) {
        return `_expectSha256Hex64(${expression}, ${dartString(path)})`;
      }
      const target = definitions.get(node.target);
      return decodeExpression(target.node, expression, pascalName(node.target), path, definitions);
    }
    case 'nullable':
      return `(${expression} == null ? null : ${decodeExpression(node.inner, expression, `${name}Value`, path, definitions)})`;
    case 'array':
      return `_decodeList<${dartType(node.items, `${name}Item`)}>(${expression}, ${dartString(path)}, (value) => ${decodeExpression(node.items, 'value', `${name}Item`, `${path}[]`, definitions)}${dartArrayConstraintArguments(node, name, definitions)})`;
    case 'map':
      return `_expectMap(${expression}, ${dartString(path)}).map((key, value) => MapEntry(key, ${decodeExpression(node.values, 'value', `${name}Value`, `${path}.*`, definitions)}))`;
    default: throw new Error(`unsupported Dart decode node kind ${node.kind}`);
  }
}

function encodeExpression(node, expression, name, definitions) {
  switch (node.kind) {
    case 'string':
    case 'integer':
    case 'boolean': return expression;
    case 'enum': return `${expression}.wire`;
    case 'object':
    case 'oneOf':
    case 'union': return `${expression}.toJson()`;
    case 'ref': {
      const target = definitions.get(node.target);
      return encodeExpression(target.node, expression, pascalName(node.target), definitions);
    }
    case 'nullable':
      return `(${expression} == null ? null : ${encodeExpression(node.inner, `${expression}!`, `${name}Value`, definitions)})`;
    case 'array':
      return `${expression}.map((value) => ${encodeExpression(node.items, 'value', `${name}Item`, definitions)}).toList(growable: false)`;
    case 'map':
      return `${expression}.map((key, value) => MapEntry(key, ${encodeExpression(node.values, 'value', `${name}Value`, definitions)}))`;
    default: throw new Error(`unsupported Dart encode node kind ${node.kind}`);
  }
}

function assertMemberNames(fields, name) {
  const seen = new Set();
  for (const field of fields) {
    const member = dartMemberName(field.name);
    if (seen.has(member)) throw new Error(`Dart member collision in ${name}: ${member}`);
    seen.add(member);
  }
}

function enumDeclaration(name, node) {
  const memberNames = new Set();
  const members = node.values.map((value) => {
    const member = enumMemberName(value);
    if (memberNames.has(member)) throw new Error(`Dart enum member collision in ${name}: ${member}`);
    memberNames.add(member);
    return `  ${member}(${dartString(value)})`;
  });
  return `enum ${name} {\n${members.join(',\n')};\n\n` +
    `  const ${name}(this.wire);\n\n` +
    `  final String wire;\n\n` +
    `  static ${name} fromWire(String value) {\n` +
    `    for (final item in values) {\n` +
    `      if (item.wire == value) return item;\n` +
    `    }\n` +
    `    throw FormatException('Unknown ${name} value: $value');\n` +
    `  }\n` +
    `}`;
}

function objectMembers(name, fields, definitions) {
  assertMemberNames(fields, name);
  const declarations = fields.map((field) => {
    const member = dartMemberName(field.name);
    const type = dartType(field.type, `${name}${pascalName(field.name)}`);
    return `  final ${type}${field.required || field.type.kind === 'nullable' ? '' : '?'} ${member};`;
  }).join('\n');
  const parameters = fields.map((field) => {
    const member = dartMemberName(field.name);
    return `    ${field.required ? 'required ' : ''}this.${member},`;
  }).join('\n');
  const requiredKeys = fields.filter((field) => field.required).map((field) => dartString(field.name));
  const allowedKeys = fields.map((field) => dartString(field.name));
  const decoders = fields.map((field) => {
    const member = dartMemberName(field.name);
    const fieldName = `${name}${pascalName(field.name)}`;
    const expression = decodeExpression(field.type, `json[${dartString(field.name)}]`, fieldName, `${name}.${field.name}`, definitions);
    return field.required
      ? `      ${member}: ${expression},`
      : `      ${member}: json.containsKey(${dartString(field.name)}) ? ${expression} : null,`;
  }).join('\n');
  const encoders = fields.map((field) => {
    const member = dartMemberName(field.name);
    const fieldName = `${name}${pascalName(field.name)}`;
    if (field.required) {
      return `      ${dartString(field.name)}: ${encodeExpression(field.type, member, fieldName, definitions)},`;
    }
    return `      if (${member} != null) ${dartString(field.name)}: ${encodeExpression(field.type, `${member}!`, fieldName, definitions)},`;
  }).join('\n');
  return {declarations, parameters, requiredKeys, allowedKeys, decoders, encoders};
}

function objectDeclaration(name, node, definitions) {
  const members = objectMembers(name, node.fields, definitions);
  const constructor = members.parameters.length > 0
    ? `  const ${name}({\n${members.parameters}\n  });`
    : `  const ${name}();`;
  const construction = members.decoders.length > 0
    ? `    return ${name}(\n${members.decoders}\n    );`
    : `    return ${name}();`;
  return `final class ${name} {\n` +
    `${constructor}\n\n` +
    `${members.declarations}\n\n` +
    `  factory ${name}.fromJson(Map<String, Object?> json) {\n` +
    `    _expectKeys(json, const {${members.requiredKeys.join(', ')}}, const {${members.allowedKeys.join(', ')}}, ${dartString(name)});\n` +
    `${construction}\n` +
    `  }\n\n` +
    `  Map<String, Object?> toJson() => {\n${members.encoders}\n  };\n` +
    `}`;
}

function unionDeclaration(name, node, definitions) {
  const cases = node.variants.map((variant) =>
    `      ${dartString(variant.tag)} => ${name}${pascalName(variant.tag)}.fromJson(json),`).join('\n');
  const base = `sealed class ${name} {\n` +
    `  const ${name}();\n\n` +
    `  factory ${name}.fromJson(Map<String, Object?> json) {\n` +
    `    final tag = _expectString(json[${dartString(node.discriminator)}], ${dartString(`${name}.${node.discriminator}`)});\n` +
    `    return switch (tag) {\n${cases}\n` +
    `      _ => throw FormatException('Unknown ${name} discriminator: $tag'),\n` +
    `    };\n` +
    `  }\n\n` +
    `  Map<String, Object?> toJson();\n` +
    `}`;

  const variants = node.variants.map((variant) => {
    const variantName = `${name}${pascalName(variant.tag)}`;
    const members = objectMembers(variantName, variant.fields, definitions);
    const required = [dartString(node.discriminator), ...members.requiredKeys];
    const allowed = [dartString(node.discriminator), ...members.allowedKeys];
    const constructor = members.parameters.length > 0
      ? `  const ${variantName}({\n${members.parameters}\n  });`
      : `  const ${variantName}();`;
    const construction = members.decoders.length > 0
      ? `    return ${variantName}(\n${members.decoders}\n    );`
      : `    return ${variantName}();`;
    return `final class ${variantName} extends ${name} {\n` +
      `${constructor}\n\n` +
      `${members.declarations}\n\n` +
      `  factory ${variantName}.fromJson(Map<String, Object?> json) {\n` +
      `    _expectKeys(json, const {${required.join(', ')}}, const {${allowed.join(', ')}}, ${dartString(variantName)});\n` +
      `    if (json[${dartString(node.discriminator)}] != ${dartString(variant.tag)}) throw const FormatException('Union discriminator mismatch');\n` +
      `${construction}\n` +
      `  }\n\n` +
      `  @override\n` +
      `  Map<String, Object?> toJson() => {\n` +
      `      ${dartString(node.discriminator)}: ${dartString(variant.tag)},\n${members.encoders}\n  };\n` +
      `}`;
  }).join('\n\n');
  return `${base}\n\n${variants}`;
}

function oneOfDeclaration(name, node, definitions) {
  const attempts = node.variants.map((variant, index) => {
    const variantName = `${name}Variant${index + 1}`;
    const valueName = `${variantName}Value`;
    return `    try {\n` +
      `      final decoded = ${decodeExpression(variant, 'value', valueName, `${name}<oneOf:${index + 1}>`, definitions)};\n` +
      `      matched = ${variantName}(decoded);\n` +
      `      matchCount += 1;\n` +
      `    } on FormatException {\n` +
      `      // A different closed branch may still match.\n` +
      `    }`;
  }).join('\n');
  const base = `sealed class ${name} {\n` +
    `  const ${name}();\n\n` +
    `  factory ${name}.fromJsonValue(Object? value) {\n` +
    `    ${name}? matched;\n` +
    `    var matchCount = 0;\n` +
    `${attempts}\n` +
    `    if (matchCount == 0) throw const FormatException('${name}: NO_ONE_OF_VARIANT');\n` +
    `    if (matchCount > 1) throw const FormatException('${name}: AMBIGUOUS_ONE_OF_VARIANT');\n` +
    `    return matched!;\n` +
    `  }\n\n` +
    `  Object? toJson();\n` +
    `}`;
  const variants = node.variants.map((variant, index) => {
    const variantName = `${name}Variant${index + 1}`;
    const valueName = `${variantName}Value`;
    const type = dartType(variant, valueName);
    return `final class ${variantName} extends ${name} {\n` +
      `  const ${variantName}(this.value);\n\n` +
      `  final ${type} value;\n\n` +
      `  @override\n` +
      `  Object? toJson() => ${encodeExpression(variant, 'value', valueName, definitions)};\n` +
      `}`;
  }).join('\n\n');
  return `${base}\n\n${variants}`;
}

function declaration(name, node, definitions) {
  switch (node.kind) {
    case 'enum': return enumDeclaration(name, node);
    case 'object': return objectDeclaration(name, node, definitions);
    case 'oneOf': return oneOfDeclaration(name, node, definitions);
    case 'union': return unionDeclaration(name, node, definitions);
    default: return `typedef ${name} = ${dartType(node, name)};`;
  }
}

function digestDomainCase(preimage) {
  const rule = preimage.domainRule;
  if (rule === null) {
    return `    case ${dartString(preimage.typeId)}:\n` +
      `      return;`;
  }
  if (rule.kind === 'object') {
    return `    case ${dartString(preimage.typeId)}:\n` +
      `      if (json['digestDomain'] != ${dartString(rule.value)}) throw FormatException('${preimage.typeId}.digestDomain: invalid digest domain');\n` +
      `      return;`;
  }
  if (rule.kind === 'oneOf') {
    return `    case ${dartString(preimage.typeId)}:\n` +
      `      if (!(const ${dartStringList(rule.values)}).contains(json['digestDomain'])) throw FormatException('${preimage.typeId}.digestDomain: invalid digest domain');\n` +
      `      return;`;
  }
  const variants = rule.variants.map((variant) =>
    `        case ${dartString(variant.tag)}:\n` +
    `          if (json['digestDomain'] != ${dartString(variant.value)}) throw FormatException('${preimage.typeId}.digestDomain: invalid digest domain');\n` +
    `          return;`).join('\n');
  return `    case ${dartString(preimage.typeId)}:\n` +
    `      switch (json[${dartString(rule.discriminator)}]) {\n${variants}\n` +
    `        default:\n` +
    `          throw FormatException('${preimage.typeId}.${rule.discriminator}: invalid discriminator');\n` +
    `      }`;
}

function digestHelpers(preimage) {
  const name = pascalName(preimage.typeId);
  return `Uint8List canonicalBytes${name}(${name} value) {\n` +
    `  final snapshot = decode${name}(encode${name}(value));\n` +
    `  final json = _expectMap(encode${name}(snapshot), ${dartString(name)});\n` +
    `  _expectDigestDomain(${dartString(preimage.typeId)}, json);\n` +
    `  return _canonicalBytes(json);\n` +
    `}\n\n` +
    `String digest${name}(${name} value) => sha256.convert(canonicalBytes${name}(value)).toString();`;
}

function pvmc1AuthorityExports(model) {
  if (model.machineAuthority === null) return '';
  const machineRecordsJson = JSON.stringify(model.machineAuthority.machineRecords);
  const machineEdgeAuthoritiesJson = JSON.stringify(
    model.machineAuthority.machineEdgeAuthorities,
  );
  const routes = model.machineAuthority.projectionRoutes.map((row) => row.registryId);
  const sql = model.machineAuthority.machineTransitionSql.manifest;
  const transactionManifestIds = model.transactionAuthority?.transactionManifests.map((row) =>
    row.manifestId) ?? [];
  const transactionKillPointIds = model.transactionAuthority?.transactionKillPoints.map((row) =>
    row.killPointId).sort() ?? [];
  const bridgeRoutePointIds = model.transactionAuthority?.bridgeRoutePointBindings.map((row) =>
    row.bridgeMarkerId) ?? [];
  return `class Pvmc1MachineTransition {\n` +
    `  const Pvmc1MachineTransition({required this.from, required this.to});\n\n` +
    `  final String from;\n` +
    `  final String to;\n\n` +
    `  factory Pvmc1MachineTransition.fromJson(Object? value) {\n` +
    `    final json = _expectMap(value, 'Pvmc1MachineTransition');\n` +
    `    _expectKeys(json, const {'from', 'to'}, const {'from', 'to'}, 'Pvmc1MachineTransition');\n` +
    `    return Pvmc1MachineTransition(\n` +
    `      from: _expectString(json['from'], 'Pvmc1MachineTransition.from'),\n` +
    `      to: _expectString(json['to'], 'Pvmc1MachineTransition.to'),\n` +
    `    );\n` +
    `  }\n` +
    `}\n\n` +
    `class Pvmc1MachineRecord {\n` +
    `  const Pvmc1MachineRecord({\n` +
    `    required this.machineOrdinal,\n` +
    `    required this.machineId,\n` +
    `    required this.stateTypeRef,\n` +
    `    required this.states,\n` +
    `    required this.initialState,\n` +
    `    required this.terminalStates,\n` +
    `    required this.allowedEdges,\n` +
    `    required this.semanticOwnerRef,\n` +
    `    required this.authoritativeWriterRef,\n` +
    `    required this.eventFactOwnerSelectorRef,\n` +
    `    required this.replicaWriterBindings,\n` +
    `    required this.storageBindingRef,\n` +
    `    required this.authoritativeRouteRefs,\n` +
    `    required this.wireProjectionRef,\n` +
    `    required this.unknownPolicyRef,\n` +
    `    required this.ownerFeature,\n` +
    `  });\n\n` +
    `  final int machineOrdinal;\n` +
    `  final String machineId;\n` +
    `  final String stateTypeRef;\n` +
    `  final List<String> states;\n` +
    `  final String initialState;\n` +
    `  final List<String> terminalStates;\n` +
    `  final List<Pvmc1MachineTransition> allowedEdges;\n` +
    `  final SemanticOwnerSelectorRefV1 semanticOwnerRef;\n` +
    `  final AuthoritativeWriterRefV1 authoritativeWriterRef;\n` +
    `  final EventFactOwnerSelectorRefV1? eventFactOwnerSelectorRef;\n` +
    `  final List<ReplicaWriterBindingV1> replicaWriterBindings;\n` +
    `  final StorageBindingRefV1 storageBindingRef;\n` +
    `  final List<ProjectionRouteRefV1> authoritativeRouteRefs;\n` +
    `  final WireProjectionRefV1 wireProjectionRef;\n` +
    `  final UnknownPolicyRefV1 unknownPolicyRef;\n` +
    `  final String? ownerFeature;\n\n` +
    `  factory Pvmc1MachineRecord.fromJson(Object? value) {\n` +
    `    final json = _expectMap(value, 'Pvmc1MachineRecord');\n` +
    `    const keys = {'machineOrdinal', 'machineId', 'stateTypeRef', 'states', ` +
    `'initialState', 'terminalStates', 'allowedEdges', 'semanticOwnerRef', ` +
    `'authoritativeWriterRef', 'eventFactOwnerSelectorRef', 'replicaWriterBindings', ` +
    `'storageBindingRef', 'authoritativeRouteRefs', 'wireProjectionRef', ` +
    `'unknownPolicyRef', 'ownerFeature'};\n` +
    `    _expectKeys(json, keys, keys, 'Pvmc1MachineRecord');\n` +
    `    return Pvmc1MachineRecord(\n` +
    `      machineOrdinal: _expectInt(json['machineOrdinal'], 'Pvmc1MachineRecord.machineOrdinal'),\n` +
    `      machineId: _expectString(json['machineId'], 'Pvmc1MachineRecord.machineId'),\n` +
    `      stateTypeRef: _expectString(json['stateTypeRef'], 'Pvmc1MachineRecord.stateTypeRef'),\n` +
    `      states: _decodeList<String>(json['states'], 'Pvmc1MachineRecord.states', (value) => _expectString(value, 'Pvmc1MachineRecord.states[]')),\n` +
    `      initialState: _expectString(json['initialState'], 'Pvmc1MachineRecord.initialState'),\n` +
    `      terminalStates: _decodeList<String>(json['terminalStates'], 'Pvmc1MachineRecord.terminalStates', (value) => _expectString(value, 'Pvmc1MachineRecord.terminalStates[]')),\n` +
    `      allowedEdges: _decodeList<Pvmc1MachineTransition>(json['allowedEdges'], 'Pvmc1MachineRecord.allowedEdges', Pvmc1MachineTransition.fromJson),\n` +
    `      semanticOwnerRef: SemanticOwnerSelectorRefV1.fromJson(_expectMap(json['semanticOwnerRef'], 'Pvmc1MachineRecord.semanticOwnerRef')),\n` +
    `      authoritativeWriterRef: AuthoritativeWriterRefV1.fromJson(_expectMap(json['authoritativeWriterRef'], 'Pvmc1MachineRecord.authoritativeWriterRef')),\n` +
    `      eventFactOwnerSelectorRef: json['eventFactOwnerSelectorRef'] == null ? null : EventFactOwnerSelectorRefV1.fromJson(_expectMap(json['eventFactOwnerSelectorRef'], 'Pvmc1MachineRecord.eventFactOwnerSelectorRef')),\n` +
    `      replicaWriterBindings: _decodeList<ReplicaWriterBindingV1>(json['replicaWriterBindings'], 'Pvmc1MachineRecord.replicaWriterBindings', (value) => ReplicaWriterBindingV1.fromJson(_expectMap(value, 'Pvmc1MachineRecord.replicaWriterBindings[]'))),\n` +
    `      storageBindingRef: StorageBindingRefV1.fromJson(_expectMap(json['storageBindingRef'], 'Pvmc1MachineRecord.storageBindingRef')),\n` +
    `      authoritativeRouteRefs: _decodeList<ProjectionRouteRefV1>(json['authoritativeRouteRefs'], 'Pvmc1MachineRecord.authoritativeRouteRefs', (value) => ProjectionRouteRefV1.fromJson(_expectMap(value, 'Pvmc1MachineRecord.authoritativeRouteRefs[]'))),\n` +
    `      wireProjectionRef: WireProjectionRefV1.fromJson(_expectMap(json['wireProjectionRef'], 'Pvmc1MachineRecord.wireProjectionRef')),\n` +
    `      unknownPolicyRef: UnknownPolicyRefV1.fromJson(_expectMap(json['unknownPolicyRef'], 'Pvmc1MachineRecord.unknownPolicyRef')),\n` +
    `      ownerFeature: json['ownerFeature'] == null ? null : _expectString(json['ownerFeature'], 'Pvmc1MachineRecord.ownerFeature'),\n` +
    `    );\n` +
    `  }\n` +
    `}\n\n` +
    `const String _pvmc1MachineRecordsJson = ${dartString(machineRecordsJson)};\n` +
    `const String _pvmc1MachineEdgeAuthoritiesJson = ${dartString(machineEdgeAuthoritiesJson)};\n\n` +
    `final List<Pvmc1MachineRecord> pvmc1MachineRecords = List<Pvmc1MachineRecord>.unmodifiable(\n` +
    `  _decodeList<Pvmc1MachineRecord>(jsonDecode(_pvmc1MachineRecordsJson), 'pvmc1MachineRecords', Pvmc1MachineRecord.fromJson, minItems: 17, maxItems: 17),\n` +
    `);\n\n` +
    `final List<MachineEdgeAuthorityV1> pvmc1MachineEdgeAuthorities = List<MachineEdgeAuthorityV1>.unmodifiable(\n` +
    `  _decodeList<MachineEdgeAuthorityV1>(jsonDecode(_pvmc1MachineEdgeAuthoritiesJson), 'pvmc1MachineEdgeAuthorities', (value) => MachineEdgeAuthorityV1.fromJson(_expectMap(value, 'pvmc1MachineEdgeAuthorities[]')), minItems: 151, maxItems: 151),\n` +
    `);\n\n` +
    `const List<String> pvmc1DurableRouteIds = ${dartStringList(routes)};\n\n` +
    `String _pvmc1MachineEdgeKey(MachineEdgeAuthorityV1 row) {\n` +
    `  final coordinate = row.coordinate.toJson();\n` +
    `  return _expectString(coordinate['machineId'], 'pvmc1MachineEdge.machineId') + '\\u0000' +\n` +
    `      _expectString(coordinate['from'], 'pvmc1MachineEdge.from') + '\\u0000' +\n` +
    `      _expectString(coordinate['to'], 'pvmc1MachineEdge.to');\n` +
    `}\n\n` +
    `final Set<String> _pvmc1AllowedMachineEdgeKeys = Set<String>.unmodifiable(\n` +
    `  pvmc1MachineEdgeAuthorities.map(_pvmc1MachineEdgeKey),\n` +
    `);\n\n` +
    `bool isAllowedPvmc1MachineEdge(String machineId, String from, String to) =>\n` +
    `    _pvmc1AllowedMachineEdgeKeys.contains('$machineId\\u0000$from\\u0000$to');\n\n` +
    `const int pvmc1MachineTransitionSqlRowCount = ${sql.rowCount};\n` +
    `const String pvmc1MachineTransitionSqlSha256 = ${dartString(sql.sqlSha256)};\n` +
    `const String pvmc1MachineTransitionSqlUtf8Base64 = ${dartString(sql.sqlUtf8Base64)};\n\n` +
    `Uint8List pvmc1MachineTransitionSqlBytes() {\n` +
    `  final bytes = Uint8List.fromList(base64Decode(pvmc1MachineTransitionSqlUtf8Base64));\n` +
    `  if (sha256.convert(bytes).toString() != pvmc1MachineTransitionSqlSha256) {\n` +
    `    throw StateError('PVMC1 machine SQL digest mismatch');\n` +
    `  }\n` +
    `  return bytes;\n` +
    `}\n\n` +
    `const List<String> pvmc1TransactionManifestIds = ${dartStringList(transactionManifestIds)};\n\n` +
    `const List<String> pvmc1TransactionKillPointIds = ${dartStringList(transactionKillPointIds)};\n\n` +
    `const List<String> pvmc1BridgeRoutePointIds = ${dartStringList(bridgeRoutePointIds)};`;
}

export function generateDart(model, sourceDigest) {
  const ids = [...model.activeDefinitionIds].sort();
  const preimages = discoverDigestPreimages(model);
  const declarations = new Map();
  for (const id of ids) collectDeclarations(model.definitions.get(id).node, pascalName(id), declarations);
  const blocks = [];
  for (const id of ids) {
    const name = pascalName(id);
    const node = model.definitions.get(id).node;
    blocks.push(declaration(name, node, model.definitions));
  }
  for (const [name, node] of declarations) {
    if (!ids.some((id) => pascalName(id) === name)) {
      blocks.push(declaration(name, node, model.definitions));
    }
  }
  const codecs = ids.map((id) => {
    const name = pascalName(id);
    const node = model.definitions.get(id).node;
    const decoder = id === SHA256_HEX_TYPE_ID
      ? `_expectSha256Hex64(value, ${dartString(name)})`
      : decodeExpression(node, 'value', name, name, model.definitions);
    return `${name} decode${name}(Object? value) => ${decoder};\n` +
      `Object? encode${name}(${name} value) => ${encodeExpression(node, 'value', name, model.definitions)};`;
  }).join('\n\n');
  const domainCases = preimages.map(digestDomainCase).join('\n');
  const digests = preimages.map(digestHelpers).join('\n\n');
  const authorityExports = pvmc1AuthorityExports(model);
  return `// @generated from conversation contract ${sourceDigest}; DO NOT EDIT.\n` +
    `// ignore_for_file: unnecessary_cast, unused_element, unused_element_parameter\n\n` +
    `import 'dart:convert';\n` +
    `import 'dart:typed_data';\n\n` +
    `import 'package:crypto/crypto.dart';\n\n` +
    `final RegExp _sha256Hex64 = RegExp(r'^[0-9a-f]{64}$');\n\n` +
    `void _expectUnicodeScalarString(String value, String path) {\n` +
    `  final units = value.codeUnits;\n` +
    `  for (var index = 0; index < units.length; index += 1) {\n` +
    `    final code = units[index];\n` +
    `    if (code >= 0xd800 && code <= 0xdbff) {\n` +
    `      if (index + 1 >= units.length) throw FormatException('$path: lone high surrogate');\n` +
    `      final low = units[index + 1];\n` +
    `      if (low < 0xdc00 || low > 0xdfff) throw FormatException('$path: lone high surrogate');\n` +
    `      index += 1;\n` +
    `    } else if (code >= 0xdc00 && code <= 0xdfff) {\n` +
    `      throw FormatException('$path: lone low surrogate');\n` +
    `    }\n` +
    `  }\n` +
    `}\n\n` +
    `String _expectString(Object? value, String path) {\n` +
    `  if (value is! String) throw FormatException('$path: expected string');\n` +
    `  _expectUnicodeScalarString(value, path);\n` +
    `  return value;\n` +
    `}\n\n` +
    `String _expectConstrainedString(Object? value, String path, {String? constValue, String? pattern}) {\n` +
    `  final text = _expectString(value, path);\n` +
    `  if (constValue != null && text != constValue) throw FormatException('$path: invalid const');\n` +
    `  if (pattern != null && !RegExp(pattern).hasMatch(text)) throw FormatException('$path: pattern mismatch');\n` +
    `  return text;\n` +
    `}\n\n` +
    `String _expectConstString(Object? value, String path, String constValue) =>\n` +
    `    _expectConstrainedString(value, path, constValue: constValue);\n\n` +
    `String _expectSha256Hex64(Object? value, String path) {\n` +
    `  final text = _expectString(value, path);\n` +
    `  if (!_sha256Hex64.hasMatch(text)) throw FormatException('$path: expected lowercase SHA-256 hex64');\n` +
    `  return text;\n` +
    `}\n\n` +
    `int _expectInt(Object? value, String path) {\n` +
    `  const minimum = -9007199254740991;\n` +
    `  const maximum = 9007199254740991;\n` +
    `  if (value is int && value >= minimum && value <= maximum) return value;\n` +
    `  if (value is double && value.isFinite && value.truncateToDouble() == value && value >= minimum && value <= maximum) {\n` +
    `    return value.toInt();\n` +
    `  }\n` +
    `  throw FormatException('$path: expected safe integer');\n` +
    `}\n\n` +
    `int _expectConstrainedInt(\n` +
    `  Object? value,\n` +
    `  String path, {\n` +
    `  int? constValue,\n` +
    `  int minimum = -9007199254740991,\n` +
    `  int maximum = 9007199254740991,\n` +
    `}) {\n` +
    `  final integer = _expectInt(value, path);\n` +
    `  if (integer < minimum || integer > maximum) throw FormatException('$path: integer outside bounds');\n` +
    `  if (constValue != null && integer != constValue) throw FormatException('$path: invalid const');\n` +
    `  return integer;\n` +
    `}\n\n` +
    `bool _expectBool(Object? value, String path) {\n` +
    `  if (value is! bool) throw FormatException('$path: expected boolean');\n` +
    `  return value;\n` +
    `}\n\n` +
    `bool _expectConstBool(Object? value, String path, bool constValue) {\n` +
    `  final boolean = _expectBool(value, path);\n` +
    `  if (boolean != constValue) throw FormatException('$path: invalid const');\n` +
    `  return boolean;\n` +
    `}\n\n` +
    `List<Object?> _expectList(Object? value, String path) {\n` +
    `  if (value is! List) throw FormatException('$path: expected array');\n` +
    `  return value.cast<Object?>();\n` +
    `}\n\n` +
    `final class _CollectionSelector {\n` +
    `  const _CollectionSelector(this.path, [this.enumOrder]);\n\n` +
    `  final String path;\n` +
    `  final List<String>? enumOrder;\n` +
    `}\n\n` +
    `Object? _selectorValue(Object? value, String selector, String path) {\n` +
    `  var current = value;\n` +
    `  for (final segment in selector.split('.')) {\n` +
    `    final object = _expectMap(current, path);\n` +
    `    if (!object.containsKey(segment)) throw FormatException('$path.$segment: required collection selector');\n` +
    `    current = object[segment];\n` +
    `  }\n` +
    `  return current;\n` +
    `}\n\n` +
    `int _compareConstraintScalar(Object? left, Object? right, List<String>? enumOrder) {\n` +
    `  if (left == right) return 0;\n` +
    `  if (left == null) return -1;\n` +
    `  if (right == null) return 1;\n` +
    `  if (enumOrder != null && left is String && right is String) {\n` +
    `    final leftRank = enumOrder.indexOf(left);\n` +
    `    final rightRank = enumOrder.indexOf(right);\n` +
    `    if (leftRank >= 0 && rightRank >= 0) return leftRank.compareTo(rightRank);\n` +
    `  }\n` +
    `  if (left is int && right is int) return left.compareTo(right);\n` +
    `  if (left is bool && right is bool) return left ? 1 : -1;\n` +
    `  if (left is String && right is String) return _compareUtf16(left, right);\n` +
    `  throw const FormatException('orderBy values have incompatible scalar types');\n` +
    `}\n\n` +
    `int _compareCollectionEntries(\n` +
    `  Object? left,\n` +
    `  Object? right,\n` +
    `  List<_CollectionSelector> selectors,\n` +
    `  String path,\n` +
    `) {\n` +
    `  for (final selector in selectors) {\n` +
    `    final comparison = selector.path == r'$'\n` +
    `        ? _compareCanonicalBytes(left, right)\n` +
    `        : _compareConstraintScalar(\n` +
    `            _selectorValue(left, selector.path, path),\n` +
    `            _selectorValue(right, selector.path, path),\n` +
    `            selector.enumOrder,\n` +
    `          );\n` +
    `    if (comparison != 0) return comparison;\n` +
    `  }\n` +
    `  return 0;\n` +
    `}\n\n` +
    `int _compareCanonicalBytes(Object? left, Object? right) {\n` +
    `  final leftBytes = utf8.encode(_canonicalJson(left, 0, _CanonicalBudget()));\n` +
    `  final rightBytes = utf8.encode(_canonicalJson(right, 0, _CanonicalBudget()));\n` +
    `  final length = leftBytes.length < rightBytes.length ? leftBytes.length : rightBytes.length;\n` +
    `  for (var index = 0; index < length; index += 1) {\n` +
    `    final difference = leftBytes[index] - rightBytes[index];\n` +
    `    if (difference != 0) return difference;\n` +
    `  }\n` +
    `  return leftBytes.length.compareTo(rightBytes.length);\n` +
    `}\n\n` +
    `List<T> _decodeList<T>(\n` +
    `  Object? value,\n` +
    `  String path,\n` +
    `  T Function(Object?) decode, {\n` +
    `  int minItems = 0,\n` +
    `  int maxItems = 9007199254740991,\n` +
    `  bool uniqueItems = false,\n` +
    `  List<String> uniqueBy = const [],\n` +
    `  List<_CollectionSelector> orderBy = const [],\n` +
    `  Object? Function(T)? snapshot,\n` +
    `}) {\n` +
    `  final input = _expectList(value, path);\n` +
    `  if (input.length < minItems || input.length > maxItems) {\n` +
    `    throw FormatException('$path: expected between $minItems and $maxItems items');\n` +
    `  }\n` +
    `  final result = input.map(decode).toList(growable: false);\n` +
    `  if (!uniqueItems && uniqueBy.isEmpty && orderBy.isEmpty) return result;\n` +
    `  if (snapshot == null) throw StateError('$path: collection constraint snapshot is missing');\n` +
    `  final snapshots = result.map(snapshot).toList(growable: false);\n` +
    `  if (uniqueItems) {\n` +
    `    final seen = <String>{};\n` +
    `    for (var index = 0; index < snapshots.length; index += 1) {\n` +
    `      final key = _canonicalJson(snapshots[index], 0, _CanonicalBudget());\n` +
    `      if (!seen.add(key)) throw FormatException('$path[$index]: duplicate array item');\n` +
    `    }\n` +
    `  }\n` +
    `  if (uniqueBy.isNotEmpty) {\n` +
    `    final seen = <String>{};\n` +
    `    for (var index = 0; index < snapshots.length; index += 1) {\n` +
    `      final fields = uniqueBy.map((selector) => _selectorValue(snapshots[index], selector, '$path[$index]')).toList(growable: false);\n` +
    `      final key = _canonicalJson(fields, 0, _CanonicalBudget());\n` +
    `      if (!seen.add(key)) throw FormatException('$path[$index]: duplicate uniqueBy fields');\n` +
    `    }\n` +
    `  }\n` +
    `  if (orderBy.isNotEmpty) {\n` +
    `    for (var index = 1; index < snapshots.length; index += 1) {\n` +
    `      if (_compareCollectionEntries(snapshots[index - 1], snapshots[index], orderBy, '$path[$index]') > 0) {\n` +
    `        throw FormatException('$path[$index]: collection is out of order');\n` +
    `      }\n` +
    `    }\n` +
    `  }\n` +
    `  return result;\n` +
    `}\n\n` +
    `Map<String, Object?> _expectMap(Object? value, String path) {\n` +
    `  if (value is! Map) throw FormatException('$path: expected object');\n` +
    `  final result = <String, Object?>{};\n` +
    `  for (final entry in value.entries) {\n` +
    `    final key = entry.key;\n` +
    `    if (key is! String) throw FormatException('$path: expected string-key object');\n` +
    `    result[key] = entry.value;\n` +
    `  }\n` +
    `  return result;\n` +
    `}\n\n` +
    `void _expectKeys(Map<String, Object?> json, Set<String> required, Set<String> allowed, String path) {\n` +
    `  for (final key in required) { if (!json.containsKey(key)) throw FormatException('$path.$key: required'); }\n` +
    `  for (final key in json.keys) {\n` +
    `    _expectUnicodeScalarString(key, '$path.<key>');\n` +
    `    if (!allowed.contains(key)) throw FormatException('$path.$key: unknown field');\n` +
    `  }\n` +
    `}\n\n` +
    `int _compareUtf16(String left, String right) {\n` +
    `  final leftUnits = left.codeUnits;\n` +
    `  final rightUnits = right.codeUnits;\n` +
    `  final length = leftUnits.length < rightUnits.length ? leftUnits.length : rightUnits.length;\n` +
    `  for (var index = 0; index < length; index += 1) {\n` +
    `    final comparison = leftUnits[index].compareTo(rightUnits[index]);\n` +
    `    if (comparison != 0) return comparison;\n` +
    `  }\n` +
    `  return leftUnits.length.compareTo(rightUnits.length);\n` +
    `}\n\n` +
    `String _canonicalString(String value) {\n` +
    `  _expectUnicodeScalarString(value, r'\$');\n` +
    `  final buffer = StringBuffer()..writeCharCode(0x22);\n` +
    `  final units = value.codeUnits;\n` +
    `  for (var index = 0; index < units.length; index += 1) {\n` +
    `    final code = units[index];\n` +
    `    if (code == 0x22 || code == 0x5c) {\n` +
    `      buffer.writeCharCode(0x5c);\n` +
    `      buffer.writeCharCode(code);\n` +
    `    } else if (code == 0x08 || code == 0x09 || code == 0x0a || code == 0x0c || code == 0x0d) {\n` +
    `      buffer.writeCharCode(0x5c);\n` +
    `      buffer.writeCharCode(switch (code) { 0x08 => 0x62, 0x09 => 0x74, 0x0a => 0x6e, 0x0c => 0x66, _ => 0x72 });\n` +
    `    } else if (code <= 0x1f) {\n` +
    `      buffer\n` +
    `        ..writeCharCode(0x5c)\n` +
    `        ..writeCharCode(0x75)\n` +
    `        ..write(code.toRadixString(16).padLeft(4, '0'));\n` +
    `    } else if (code >= 0xd800 && code <= 0xdbff) {\n` +
    `      buffer.write(String.fromCharCodes([code, units[index + 1]]));\n` +
    `      index += 1;\n` +
    `    } else {\n` +
    `      buffer.writeCharCode(code);\n` +
    `    }\n` +
    `  }\n` +
    `  buffer.writeCharCode(0x22);\n` +
    `  return buffer.toString();\n` +
    `}\n\n` +
    `final class _CanonicalBudget {\n` +
    `  var nodes = 0;\n\n` +
    `  void enter(int depth) {\n` +
    `    if (depth > 512) throw const FormatException('Canonical JSON nesting is too deep');\n` +
    `    nodes += 1;\n` +
    `    if (nodes > 100000) throw const FormatException('Canonical JSON node limit exceeded');\n` +
    `  }\n` +
    `}\n\n` +
    `String _canonicalJson(Object? value, int depth, _CanonicalBudget budget) {\n` +
    `  budget.enter(depth);\n` +
    `  if (value == null) return 'null';\n` +
    `  if (value is String) return _canonicalString(value);\n` +
    `  if (value is int) return _expectInt(value, r'\$').toString();\n` +
    `  if (value is bool) return value ? 'true' : 'false';\n` +
    `  if (value is List) return '[\${value.map((entry) => _canonicalJson(entry, depth + 1, budget)).join(',')}]';\n` +
    `  if (value is Map) {\n` +
    `    final json = _expectMap(value, r'\$');\n` +
    `    final keys = json.keys.toList(growable: false)..sort(_compareUtf16);\n` +
    `    return '{\${keys.map((key) => '\${_canonicalString(key)}:\${_canonicalJson(json[key], depth + 1, budget)}').join(',')}}';\n` +
    `  }\n` +
    `  throw FormatException('Unsupported canonical JSON value: \${value.runtimeType}');\n` +
    `}\n\n` +
    `Uint8List _canonicalBytes(Object? value) => Uint8List.fromList(utf8.encode(_canonicalJson(value, 0, _CanonicalBudget())));\n\n` +
    `void _expectDigestDomain(String typeId, Map<String, Object?> json) {\n` +
    `  switch (typeId) {\n${domainCases}\n` +
    `    default:\n` +
    `      throw StateError('Unknown digest preimage type: $typeId');\n` +
    `  }\n` +
    `}\n\n` +
    `${blocks.join('\n\n')}\n\n` +
    `${codecs}\n` +
    (digests ? `\n${digests}\n` : '') +
    (authorityExports ? `\n${authorityExports}\n` : '');
}
