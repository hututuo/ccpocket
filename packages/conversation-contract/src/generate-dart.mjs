import {
  SHA256_HEX_TYPE_ID,
  discoverDigestPreimages,
} from './digest-preimages.mjs';
import { dartMemberName, enumMemberName, pascalName } from './names.mjs';

function dartString(value) {
  return JSON.stringify(value).replace(/\$/g, '\\$');
}

function collectDeclarations(node, name, declarations) {
  if (['object', 'enum', 'union'].includes(node.kind)) {
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
  } else if (node.kind === 'array') {
    collectDeclarations(node.items, `${name}Item`, declarations);
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
    case 'union': return name;
    case 'ref': return pascalName(node.target);
    case 'array': return `List<${dartType(node.items, `${name}Item`)}>`;
    case 'map': return `Map<String, ${dartType(node.values, `${name}Value`)}>`;
    default: throw new Error(`unsupported Dart node kind ${node.kind}`);
  }
}

function refNode(node, definitions) {
  return node.kind === 'ref' ? definitions.get(node.target).node : node;
}

function decodeExpression(node, expression, name, path, definitions) {
  switch (node.kind) {
    case 'string': return `_expectString(${expression}, ${dartString(path)})`;
    case 'integer': return `_expectInt(${expression}, ${dartString(path)})`;
    case 'boolean': return `_expectBool(${expression}, ${dartString(path)})`;
    case 'enum': return `${name}.fromWire(_expectString(${expression}, ${dartString(path)}))`;
    case 'object':
    case 'union': return `${name}.fromJson(_expectMap(${expression}, ${dartString(path)}))`;
    case 'ref': {
      if (node.target === SHA256_HEX_TYPE_ID) {
        return `_expectSha256Hex64(${expression}, ${dartString(path)})`;
      }
      const target = definitions.get(node.target);
      return decodeExpression(target.node, expression, pascalName(node.target), path, definitions);
    }
    case 'array':
      return `_expectList(${expression}, ${dartString(path)}).map((value) => ${decodeExpression(node.items, 'value', `${name}Item`, `${path}[]`, definitions)}).toList(growable: false)`;
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
    case 'union': return `${expression}.toJson()`;
    case 'ref': {
      const target = definitions.get(node.target);
      return encodeExpression(target.node, expression, pascalName(node.target), definitions);
    }
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
    return `  final ${type}${field.required ? '' : '?'} ${member};`;
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

function declaration(name, node, definitions) {
  switch (node.kind) {
    case 'enum': return enumDeclaration(name, node);
    case 'object': return objectDeclaration(name, node, definitions);
    case 'union': return unionDeclaration(name, node, definitions);
    default: return `typedef ${name} = ${dartType(node, name)};`;
  }
}

function digestDomainCase(preimage) {
  const rule = preimage.domainRule;
  if (rule.kind === 'object') {
    return `    case ${dartString(preimage.typeId)}:\n` +
      `      if (json['digestDomain'] != ${dartString(rule.value)}) throw FormatException('${preimage.typeId}.digestDomain: invalid digest domain');\n` +
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
  return `// @generated from conversation contract ${sourceDigest}; DO NOT EDIT.\n` +
    `// ignore_for_file: unnecessary_cast\n\n` +
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
    `bool _expectBool(Object? value, String path) {\n` +
    `  if (value is! bool) throw FormatException('$path: expected boolean');\n` +
    `  return value;\n` +
    `}\n\n` +
    `List<Object?> _expectList(Object? value, String path) {\n` +
    `  if (value is! List) throw FormatException('$path: expected array');\n` +
    `  return value.cast<Object?>();\n` +
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
    (digests ? `\n${digests}\n` : '');
}
