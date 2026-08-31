// @generated from conversation contract cdd9b5622b7af2917865f30af72cb96a976289ab0569f5464b5dba1b9ba15d6d; DO NOT EDIT.
// ignore_for_file: unnecessary_cast, unused_element, unused_element_parameter

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final RegExp _sha256Hex64 = RegExp(r'^[0-9a-f]{64}$');

void _expectUnicodeScalarString(String value, String path) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index += 1) {
    final code = units[index];
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= units.length)
        throw FormatException('$path: lone high surrogate');
      final low = units[index + 1];
      if (low < 0xdc00 || low > 0xdfff)
        throw FormatException('$path: lone high surrogate');
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      throw FormatException('$path: lone low surrogate');
    }
  }
}

String _expectString(Object? value, String path) {
  if (value is! String) throw FormatException('$path: expected string');
  _expectUnicodeScalarString(value, path);
  return value;
}

String _expectConstrainedString(
  Object? value,
  String path, {
  String? constValue,
  String? pattern,
}) {
  final text = _expectString(value, path);
  if (constValue != null && text != constValue)
    throw FormatException('$path: invalid const');
  if (pattern != null && !RegExp(pattern).hasMatch(text))
    throw FormatException('$path: pattern mismatch');
  return text;
}

String _expectConstString(Object? value, String path, String constValue) =>
    _expectConstrainedString(value, path, constValue: constValue);

String _expectSha256Hex64(Object? value, String path) {
  final text = _expectString(value, path);
  if (!_sha256Hex64.hasMatch(text))
    throw FormatException('$path: expected lowercase SHA-256 hex64');
  return text;
}

int _expectInt(Object? value, String path) {
  const minimum = -9007199254740991;
  const maximum = 9007199254740991;
  if (value is int && value >= minimum && value <= maximum) return value;
  if (value is double &&
      value.isFinite &&
      value.truncateToDouble() == value &&
      value >= minimum &&
      value <= maximum) {
    return value.toInt();
  }
  throw FormatException('$path: expected safe integer');
}

int _expectConstrainedInt(
  Object? value,
  String path, {
  int? constValue,
  int minimum = -9007199254740991,
  int maximum = 9007199254740991,
}) {
  final integer = _expectInt(value, path);
  if (integer < minimum || integer > maximum)
    throw FormatException('$path: integer outside bounds');
  if (constValue != null && integer != constValue)
    throw FormatException('$path: invalid const');
  return integer;
}

bool _expectBool(Object? value, String path) {
  if (value is! bool) throw FormatException('$path: expected boolean');
  return value;
}

bool _expectConstBool(Object? value, String path, bool constValue) {
  final boolean = _expectBool(value, path);
  if (boolean != constValue) throw FormatException('$path: invalid const');
  return boolean;
}

List<Object?> _expectList(Object? value, String path) {
  if (value is! List) throw FormatException('$path: expected array');
  return value.cast<Object?>();
}

final class _CollectionSelector {
  const _CollectionSelector(this.path, [this.enumOrder]);

  final String path;
  final List<String>? enumOrder;
}

Object? _selectorValue(Object? value, String selector, String path) {
  var current = value;
  for (final segment in selector.split('.')) {
    final object = _expectMap(current, path);
    if (!object.containsKey(segment))
      throw FormatException('$path.$segment: required collection selector');
    current = object[segment];
  }
  return current;
}

int _compareConstraintScalar(
  Object? left,
  Object? right,
  List<String>? enumOrder,
) {
  if (left == right) return 0;
  if (left == null) return -1;
  if (right == null) return 1;
  if (enumOrder != null && left is String && right is String) {
    final leftRank = enumOrder.indexOf(left);
    final rightRank = enumOrder.indexOf(right);
    if (leftRank >= 0 && rightRank >= 0) return leftRank.compareTo(rightRank);
  }
  if (left is int && right is int) return left.compareTo(right);
  if (left is bool && right is bool) return left ? 1 : -1;
  if (left is String && right is String) return _compareUtf16(left, right);
  throw const FormatException('orderBy values have incompatible scalar types');
}

int _compareCollectionEntries(
  Object? left,
  Object? right,
  List<_CollectionSelector> selectors,
  String path,
) {
  for (final selector in selectors) {
    final comparison = selector.path == r'$'
        ? _compareCanonicalBytes(left, right)
        : _compareConstraintScalar(
            _selectorValue(left, selector.path, path),
            _selectorValue(right, selector.path, path),
            selector.enumOrder,
          );
    if (comparison != 0) return comparison;
  }
  return 0;
}

int _compareCanonicalBytes(Object? left, Object? right) {
  final leftBytes = utf8.encode(_canonicalJson(left, 0, _CanonicalBudget()));
  final rightBytes = utf8.encode(_canonicalJson(right, 0, _CanonicalBudget()));
  final length = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < length; index += 1) {
    final difference = leftBytes[index] - rightBytes[index];
    if (difference != 0) return difference;
  }
  return leftBytes.length.compareTo(rightBytes.length);
}

List<T> _decodeList<T>(
  Object? value,
  String path,
  T Function(Object?) decode, {
  int minItems = 0,
  int maxItems = 9007199254740991,
  bool uniqueItems = false,
  List<String> uniqueBy = const [],
  List<_CollectionSelector> orderBy = const [],
  Object? Function(T)? snapshot,
}) {
  final input = _expectList(value, path);
  if (input.length < minItems || input.length > maxItems) {
    throw FormatException(
      '$path: expected between $minItems and $maxItems items',
    );
  }
  final result = input.map(decode).toList(growable: false);
  if (!uniqueItems && uniqueBy.isEmpty && orderBy.isEmpty) return result;
  if (snapshot == null)
    throw StateError('$path: collection constraint snapshot is missing');
  final snapshots = result.map(snapshot).toList(growable: false);
  if (uniqueItems) {
    final seen = <String>{};
    for (var index = 0; index < snapshots.length; index += 1) {
      final key = _canonicalJson(snapshots[index], 0, _CanonicalBudget());
      if (!seen.add(key))
        throw FormatException('$path[$index]: duplicate array item');
    }
  }
  if (uniqueBy.isNotEmpty) {
    final seen = <String>{};
    for (var index = 0; index < snapshots.length; index += 1) {
      final fields = uniqueBy
          .map(
            (selector) =>
                _selectorValue(snapshots[index], selector, '$path[$index]'),
          )
          .toList(growable: false);
      final key = _canonicalJson(fields, 0, _CanonicalBudget());
      if (!seen.add(key))
        throw FormatException('$path[$index]: duplicate uniqueBy fields');
    }
  }
  if (orderBy.isNotEmpty) {
    for (var index = 1; index < snapshots.length; index += 1) {
      if (_compareCollectionEntries(
            snapshots[index - 1],
            snapshots[index],
            orderBy,
            '$path[$index]',
          ) >
          0) {
        throw FormatException('$path[$index]: collection is out of order');
      }
    }
  }
  return result;
}

Map<String, Object?> _expectMap(Object? value, String path) {
  if (value is! Map) throw FormatException('$path: expected object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String)
      throw FormatException('$path: expected string-key object');
    result[key] = entry.value;
  }
  return result;
}

void _expectKeys(
  Map<String, Object?> json,
  Set<String> required,
  Set<String> allowed,
  String path,
) {
  for (final key in required) {
    if (!json.containsKey(key)) throw FormatException('$path.$key: required');
  }
  for (final key in json.keys) {
    _expectUnicodeScalarString(key, '$path.<key>');
    if (!allowed.contains(key))
      throw FormatException('$path.$key: unknown field');
  }
}

int _compareUtf16(String left, String right) {
  final leftUnits = left.codeUnits;
  final rightUnits = right.codeUnits;
  final length = leftUnits.length < rightUnits.length
      ? leftUnits.length
      : rightUnits.length;
  for (var index = 0; index < length; index += 1) {
    final comparison = leftUnits[index].compareTo(rightUnits[index]);
    if (comparison != 0) return comparison;
  }
  return leftUnits.length.compareTo(rightUnits.length);
}

String _canonicalString(String value) {
  _expectUnicodeScalarString(value, r'$');
  final buffer = StringBuffer()..writeCharCode(0x22);
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index += 1) {
    final code = units[index];
    if (code == 0x22 || code == 0x5c) {
      buffer.writeCharCode(0x5c);
      buffer.writeCharCode(code);
    } else if (code == 0x08 ||
        code == 0x09 ||
        code == 0x0a ||
        code == 0x0c ||
        code == 0x0d) {
      buffer.writeCharCode(0x5c);
      buffer.writeCharCode(switch (code) {
        0x08 => 0x62,
        0x09 => 0x74,
        0x0a => 0x6e,
        0x0c => 0x66,
        _ => 0x72,
      });
    } else if (code <= 0x1f) {
      buffer
        ..writeCharCode(0x5c)
        ..writeCharCode(0x75)
        ..write(code.toRadixString(16).padLeft(4, '0'));
    } else if (code >= 0xd800 && code <= 0xdbff) {
      buffer.write(String.fromCharCodes([code, units[index + 1]]));
      index += 1;
    } else {
      buffer.writeCharCode(code);
    }
  }
  buffer.writeCharCode(0x22);
  return buffer.toString();
}

final class _CanonicalBudget {
  var nodes = 0;

  void enter(int depth) {
    if (depth > 512)
      throw const FormatException('Canonical JSON nesting is too deep');
    nodes += 1;
    if (nodes > 100000)
      throw const FormatException('Canonical JSON node limit exceeded');
  }
}

String _canonicalJson(Object? value, int depth, _CanonicalBudget budget) {
  budget.enter(depth);
  if (value == null) return 'null';
  if (value is String) return _canonicalString(value);
  if (value is int) return _expectInt(value, r'$').toString();
  if (value is bool) return value ? 'true' : 'false';
  if (value is List)
    return '[${value.map((entry) => _canonicalJson(entry, depth + 1, budget)).join(',')}]';
  if (value is Map) {
    final json = _expectMap(value, r'$');
    final keys = json.keys.toList(growable: false)..sort(_compareUtf16);
    return '{${keys.map((key) => '${_canonicalString(key)}:${_canonicalJson(json[key], depth + 1, budget)}').join(',')}}';
  }
  throw FormatException(
    'Unsupported canonical JSON value: ${value.runtimeType}',
  );
}

Uint8List _canonicalBytes(Object? value) => Uint8List.fromList(
  utf8.encode(_canonicalJson(value, 0, _CanonicalBudget())),
);

void _expectDigestDomain(String typeId, Map<String, Object?> json) {
  switch (typeId) {
    case "CanonicalProfileProbePreimageV1":
      if (json['digestDomain'] != "ccpocket.canonical-profile-probe.v1")
        throw FormatException(
          'CanonicalProfileProbePreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "FixtureUntaggedPreimageV1":
      if (json['digestDomain'] != "ccpocket.fixture-untagged.v1")
        throw FormatException(
          'FixtureUntaggedPreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "GapRepairIntentPreimageV1":
      if (json['digestDomain'] != "ccpocket.gap-repair-intent.v1")
        throw FormatException(
          'GapRepairIntentPreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "MaterializationBeginHeaderPreimageV1":
      if (json['digestDomain'] != "ccpocket.materialization-begin.v1")
        throw FormatException(
          'MaterializationBeginHeaderPreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "MaterializationCoveragePreimageV1":
      if (json['digestDomain'] != "ccpocket.materialization-coverage.v1")
        throw FormatException(
          'MaterializationCoveragePreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "MaterializationManifestPreimageV1":
      if (json['digestDomain'] != "ccpocket.materialization-manifest.v1")
        throw FormatException(
          'MaterializationManifestPreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "MaterializationOrderPreimageV1":
      switch (json["domain"]) {
        case "CATALOG":
          if (json['digestDomain'] != "ccpocket.materialization-order.v1")
            throw FormatException(
              'MaterializationOrderPreimageV1.digestDomain: invalid digest domain',
            );
          return;
        case "TIMELINE":
          if (json['digestDomain'] != "ccpocket.materialization-order.v1")
            throw FormatException(
              'MaterializationOrderPreimageV1.digestDomain: invalid digest domain',
            );
          return;
        default:
          throw FormatException(
            'MaterializationOrderPreimageV1.domain: invalid discriminator',
          );
      }
    case "MaterializationPagePreimageV1":
      if (json['digestDomain'] != "ccpocket.materialization-page.v1")
        throw FormatException(
          'MaterializationPagePreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "MaterializationReceiptPreimageV1":
      if (json['digestDomain'] != "ccpocket.materialization-receipt.v1")
        throw FormatException(
          'MaterializationReceiptPreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "OperationFingerprintPreimageV1":
      if (json['digestDomain'] != "ccpocket.operation-fingerprint.v1")
        throw FormatException(
          'OperationFingerprintPreimageV1.digestDomain: invalid digest domain',
        );
      return;
    case "ProviderReadEvidencePreimageV1":
      if (json['digestDomain'] != "ccpocket.provider-read-evidence.v1")
        throw FormatException(
          'ProviderReadEvidencePreimageV1.digestDomain: invalid digest domain',
        );
      return;
    default:
      throw StateError('Unknown digest preimage type: $typeId');
  }
}

final class CanonicalProfileProbePreimageV1 {
  const CanonicalProfileProbePreimageV1({
    required this.digestDomain,
    required this.u000d,
    required this.n1,
    required this.u0080,
    required this.u00f6,
    required this.u20ac,
    required this.ud83dde00,
    required this.ufb33,
    required this.escaped,
    required this.lineSeparators,
    required this.nfc,
    required this.nfd,
    required this.minSafe,
    required this.maxSafe,
    required this.negativeZero,
  });

  final CanonicalProfileProbePreimageV1DigestDomain digestDomain;
  final String u000d;
  final String n1;
  final String u0080;
  final String u00f6;
  final String u20ac;
  final String ud83dde00;
  final String ufb33;
  final String escaped;
  final String lineSeparators;
  final String nfc;
  final String nfd;
  final int minSafe;
  final int maxSafe;
  final int negativeZero;

  factory CanonicalProfileProbePreimageV1.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "\r",
        "1",
        "",
        "ö",
        "€",
        "😀",
        "דּ",
        "escaped",
        "lineSeparators",
        "nfc",
        "nfd",
        "minSafe",
        "maxSafe",
        "negativeZero",
      },
      const {
        "digestDomain",
        "\r",
        "1",
        "",
        "ö",
        "€",
        "😀",
        "דּ",
        "escaped",
        "lineSeparators",
        "nfc",
        "nfd",
        "minSafe",
        "maxSafe",
        "negativeZero",
      },
      "CanonicalProfileProbePreimageV1",
    );
    return CanonicalProfileProbePreimageV1(
      digestDomain: CanonicalProfileProbePreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "CanonicalProfileProbePreimageV1.digestDomain",
        ),
      ),
      u000d: _expectString(json["\r"], "CanonicalProfileProbePreimageV1.\r"),
      n1: _expectString(json["1"], "CanonicalProfileProbePreimageV1.1"),
      u0080: _expectString(json[""], "CanonicalProfileProbePreimageV1."),
      u00f6: _expectString(json["ö"], "CanonicalProfileProbePreimageV1.ö"),
      u20ac: _expectString(json["€"], "CanonicalProfileProbePreimageV1.€"),
      ud83dde00: _expectString(
        json["😀"],
        "CanonicalProfileProbePreimageV1.😀",
      ),
      ufb33: _expectString(json["דּ"], "CanonicalProfileProbePreimageV1.דּ"),
      escaped: _expectString(
        json["escaped"],
        "CanonicalProfileProbePreimageV1.escaped",
      ),
      lineSeparators: _expectString(
        json["lineSeparators"],
        "CanonicalProfileProbePreimageV1.lineSeparators",
      ),
      nfc: _expectString(json["nfc"], "CanonicalProfileProbePreimageV1.nfc"),
      nfd: _expectString(json["nfd"], "CanonicalProfileProbePreimageV1.nfd"),
      minSafe: _expectInt(
        json["minSafe"],
        "CanonicalProfileProbePreimageV1.minSafe",
      ),
      maxSafe: _expectInt(
        json["maxSafe"],
        "CanonicalProfileProbePreimageV1.maxSafe",
      ),
      negativeZero: _expectInt(
        json["negativeZero"],
        "CanonicalProfileProbePreimageV1.negativeZero",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "\r": u000d,
    "1": n1,
    "": u0080,
    "ö": u00f6,
    "€": u20ac,
    "😀": ud83dde00,
    "דּ": ufb33,
    "escaped": escaped,
    "lineSeparators": lineSeparators,
    "nfc": nfc,
    "nfd": nfd,
    "minSafe": minSafe,
    "maxSafe": maxSafe,
    "negativeZero": negativeZero,
  };
}

sealed class FixtureAmbiguousOneOf {
  const FixtureAmbiguousOneOf();

  factory FixtureAmbiguousOneOf.fromJsonValue(Object? value) {
    FixtureAmbiguousOneOf? matched;
    var matchCount = 0;
    try {
      final decoded = _expectConstrainedString(
        value,
        "FixtureAmbiguousOneOf<oneOf:1>",
        pattern: "^a",
      );
      matched = FixtureAmbiguousOneOfVariant1(decoded);
      matchCount += 1;
    } on FormatException {
      // A different closed branch may still match.
    }
    try {
      final decoded = _expectConstrainedString(
        value,
        "FixtureAmbiguousOneOf<oneOf:2>",
        pattern: "a\$",
      );
      matched = FixtureAmbiguousOneOfVariant2(decoded);
      matchCount += 1;
    } on FormatException {
      // A different closed branch may still match.
    }
    if (matchCount == 0)
      throw const FormatException('FixtureAmbiguousOneOf: NO_ONE_OF_VARIANT');
    if (matchCount > 1)
      throw const FormatException(
        'FixtureAmbiguousOneOf: AMBIGUOUS_ONE_OF_VARIANT',
      );
    return matched!;
  }

  Object? toJson();
}

final class FixtureAmbiguousOneOfVariant1 extends FixtureAmbiguousOneOf {
  const FixtureAmbiguousOneOfVariant1(this.value);

  final String value;

  @override
  Object? toJson() => value;
}

final class FixtureAmbiguousOneOfVariant2 extends FixtureAmbiguousOneOf {
  const FixtureAmbiguousOneOfVariant2(this.value);

  final String value;

  @override
  Object? toJson() => value;
}

typedef FixtureCanonicalOrderSet = List<FixtureOneOf>;

final class FixtureConstrainedRecord {
  const FixtureConstrainedRecord({
    required this.nullableValue,
    required this.fixed,
    required this.version,
    required this.bounded,
    required this.disabled,
    required this.items,
    required this.tags,
  });

  final String? nullableValue;
  final String fixed;
  final int version;
  final int bounded;
  final bool disabled;
  final List<FixtureConstraintItem> items;
  final List<String> tags;

  factory FixtureConstrainedRecord.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        "nullableValue",
        "fixed",
        "version",
        "bounded",
        "disabled",
        "items",
        "tags",
      },
      const {
        "nullableValue",
        "fixed",
        "version",
        "bounded",
        "disabled",
        "items",
        "tags",
      },
      "FixtureConstrainedRecord",
    );
    return FixtureConstrainedRecord(
      nullableValue: (json["nullableValue"] == null
          ? null
          : _expectConstrainedString(
              json["nullableValue"],
              "FixtureConstrainedRecord.nullableValue",
              pattern: "^value-[0-9]+\$",
            )),
      fixed: _expectConstrainedString(
        json["fixed"],
        "FixtureConstrainedRecord.fixed",
        constValue: "FIXED",
      ),
      version: _expectConstrainedInt(
        json["version"],
        "FixtureConstrainedRecord.version",
        constValue: 1,
      ),
      bounded: _expectConstrainedInt(
        json["bounded"],
        "FixtureConstrainedRecord.bounded",
        minimum: 1,
        maximum: 3,
      ),
      disabled: _expectConstBool(
        json["disabled"],
        "FixtureConstrainedRecord.disabled",
        false,
      ),
      items: _decodeList<FixtureConstraintItem>(
        json["items"],
        "FixtureConstrainedRecord.items",
        (value) => FixtureConstraintItem.fromJson(
          _expectMap(value, "FixtureConstrainedRecord.items[]"),
        ),
        minItems: 1,
        maxItems: 3,
        uniqueBy: const ["identity.id"],
        orderBy: const [_CollectionSelector("ordinal")],
        snapshot: (value) => value.toJson(),
      ),
      tags: _decodeList<String>(
        json["tags"],
        "FixtureConstrainedRecord.tags",
        (value) => _expectConstrainedString(
          value,
          "FixtureConstrainedRecord.tags[]",
          pattern: "^[a-z]+\$",
        ),
        minItems: 1,
        maxItems: 3,
        uniqueItems: true,
        snapshot: (value) => value,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "nullableValue": (nullableValue == null ? null : nullableValue!),
    "fixed": fixed,
    "version": version,
    "bounded": bounded,
    "disabled": disabled,
    "items": items.map((value) => value.toJson()).toList(growable: false),
    "tags": tags.map((value) => value).toList(growable: false),
  };
}

final class FixtureConstraintItem {
  const FixtureConstraintItem({
    required this.identity,
    required this.ordinal,
    required this.label,
  });

  final FixtureConstraintItemIdentity identity;
  final int ordinal;
  final String label;

  factory FixtureConstraintItem.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"identity", "ordinal", "label"},
      const {"identity", "ordinal", "label"},
      "FixtureConstraintItem",
    );
    return FixtureConstraintItem(
      identity: FixtureConstraintItemIdentity.fromJson(
        _expectMap(json["identity"], "FixtureConstraintItem.identity"),
      ),
      ordinal: _expectConstrainedInt(
        json["ordinal"],
        "FixtureConstraintItem.ordinal",
        minimum: 0,
        maximum: 3,
      ),
      label: _expectConstrainedString(
        json["label"],
        "FixtureConstraintItem.label",
        pattern: "^item-[a-z]+\$",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "identity": identity.toJson(),
    "ordinal": ordinal,
    "label": label,
  };
}

final class FixtureEnvelope {
  const FixtureEnvelope({
    required this.id,
    required this.source,
    required this.priority,
    required this.payload,
    this.metadata,
    this.proto,
  });

  final String id;
  final FixtureSourceRef source;
  final FixturePriority priority;
  final FixturePayload payload;
  final Map<String, String>? metadata;
  final String? proto;

  factory FixtureEnvelope.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"id", "source", "priority", "payload"},
      const {"id", "source", "priority", "payload", "metadata", "__proto__"},
      "FixtureEnvelope",
    );
    return FixtureEnvelope(
      id: _expectString(json["id"], "FixtureEnvelope.id"),
      source: FixtureSourceRef.fromJson(
        _expectMap(json["source"], "FixtureEnvelope.source"),
      ),
      priority: FixturePriority.fromWire(
        _expectString(json["priority"], "FixtureEnvelope.priority"),
      ),
      payload: FixturePayload.fromJson(
        _expectMap(json["payload"], "FixtureEnvelope.payload"),
      ),
      metadata: json.containsKey("metadata")
          ? _expectMap(json["metadata"], "FixtureEnvelope.metadata").map(
              (key, value) => MapEntry(
                key,
                _expectString(value, "FixtureEnvelope.metadata.*"),
              ),
            )
          : null,
      proto: json.containsKey("__proto__")
          ? _expectString(json["__proto__"], "FixtureEnvelope.__proto__")
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    "id": id,
    "source": source.toJson(),
    "priority": priority.wire,
    "payload": payload.toJson(),
    if (metadata != null)
      "metadata": metadata!.map((key, value) => MapEntry(key, value)),
    if (proto != null) "__proto__": proto!,
  };
}

sealed class FixtureOneOf {
  const FixtureOneOf();

  factory FixtureOneOf.fromJsonValue(Object? value) {
    FixtureOneOf? matched;
    var matchCount = 0;
    try {
      final decoded = FixtureOneOfVariant1Value.fromJson(
        _expectMap(value, "FixtureOneOf<oneOf:1>"),
      );
      matched = FixtureOneOfVariant1(decoded);
      matchCount += 1;
    } on FormatException {
      // A different closed branch may still match.
    }
    try {
      final decoded = FixtureOneOfVariant2Value.fromJson(
        _expectMap(value, "FixtureOneOf<oneOf:2>"),
      );
      matched = FixtureOneOfVariant2(decoded);
      matchCount += 1;
    } on FormatException {
      // A different closed branch may still match.
    }
    if (matchCount == 0)
      throw const FormatException('FixtureOneOf: NO_ONE_OF_VARIANT');
    if (matchCount > 1)
      throw const FormatException('FixtureOneOf: AMBIGUOUS_ONE_OF_VARIANT');
    return matched!;
  }

  Object? toJson();
}

final class FixtureOneOfVariant1 extends FixtureOneOf {
  const FixtureOneOfVariant1(this.value);

  final FixtureOneOfVariant1Value value;

  @override
  Object? toJson() => value.toJson();
}

final class FixtureOneOfVariant2 extends FixtureOneOf {
  const FixtureOneOfVariant2(this.value);

  final FixtureOneOfVariant2Value value;

  @override
  Object? toJson() => value.toJson();
}

final class FixturePageBodyV1 {
  const FixturePageBodyV1({required this.items, required this.gaps});

  final List<String> items;
  final List<String> gaps;

  factory FixturePageBodyV1.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"items", "gaps"},
      const {"items", "gaps"},
      "FixturePageBodyV1",
    );
    return FixturePageBodyV1(
      items: _decodeList<String>(
        json["items"],
        "FixturePageBodyV1.items",
        (value) => _expectString(value, "FixturePageBodyV1.items[]"),
      ),
      gaps: _decodeList<String>(
        json["gaps"],
        "FixturePageBodyV1.gaps",
        (value) => _expectString(value, "FixturePageBodyV1.gaps[]"),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "items": items.map((value) => value).toList(growable: false),
    "gaps": gaps.map((value) => value).toList(growable: false),
  };
}

sealed class FixturePayload {
  const FixturePayload();

  factory FixturePayload.fromJson(Map<String, Object?> json) {
    final tag = _expectString(json["kind"], "FixturePayload.kind");
    return switch (tag) {
      "text" => FixturePayloadText.fromJson(json),
      "progress" => FixturePayloadProgress.fromJson(json),
      _ => throw FormatException('Unknown FixturePayload discriminator: $tag'),
    };
  }

  Map<String, Object?> toJson();
}

final class FixturePayloadText extends FixturePayload {
  const FixturePayloadText({required this.text});

  final String text;

  factory FixturePayloadText.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"kind", "text"},
      const {"kind", "text"},
      "FixturePayloadText",
    );
    if (json["kind"] != "text")
      throw const FormatException('Union discriminator mismatch');
    return FixturePayloadText(
      text: _expectString(json["text"], "FixturePayloadText.text"),
    );
  }

  @override
  Map<String, Object?> toJson() => {"kind": "text", "text": text};
}

final class FixturePayloadProgress extends FixturePayload {
  const FixturePayloadProgress({required this.complete, this.labels});

  final bool complete;
  final List<String>? labels;

  factory FixturePayloadProgress.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"kind", "complete"},
      const {"kind", "complete", "labels"},
      "FixturePayloadProgress",
    );
    if (json["kind"] != "progress")
      throw const FormatException('Union discriminator mismatch');
    return FixturePayloadProgress(
      complete: _expectBool(
        json["complete"],
        "FixturePayloadProgress.complete",
      ),
      labels: json.containsKey("labels")
          ? _decodeList<String>(
              json["labels"],
              "FixturePayloadProgress.labels",
              (value) =>
                  _expectString(value, "FixturePayloadProgress.labels[]"),
            )
          : null,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    "kind": "progress",
    "complete": complete,
    if (labels != null)
      "labels": labels!.map((value) => value).toList(growable: false),
  };
}

enum FixturePriority {
  normal("normal"),
  highPriority("high_priority"),
  costX("cost\$x"),
  quoteSlashCostX("quote\"slash\\cost\$x");

  const FixturePriority(this.wire);

  final String wire;

  static FixturePriority fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException('Unknown FixturePriority value: $value');
  }
}

final class FixtureSourceRef {
  const FixtureSourceRef({
    required this.bridgeInstanceId,
    required this.sourceOrdinal,
  });

  final String bridgeInstanceId;
  final int sourceOrdinal;

  factory FixtureSourceRef.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"bridgeInstanceId", "sourceOrdinal"},
      const {"bridgeInstanceId", "sourceOrdinal"},
      "FixtureSourceRef",
    );
    return FixtureSourceRef(
      bridgeInstanceId: _expectString(
        json["bridgeInstanceId"],
        "FixtureSourceRef.bridgeInstanceId",
      ),
      sourceOrdinal: _expectInt(
        json["sourceOrdinal"],
        "FixtureSourceRef.sourceOrdinal",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "bridgeInstanceId": bridgeInstanceId,
    "sourceOrdinal": sourceOrdinal,
  };
}

sealed class FixtureUntaggedPreimageV1 {
  const FixtureUntaggedPreimageV1();

  factory FixtureUntaggedPreimageV1.fromJsonValue(Object? value) {
    FixtureUntaggedPreimageV1? matched;
    var matchCount = 0;
    try {
      final decoded = FixtureUntaggedPreimageV1Variant1Value.fromJson(
        _expectMap(value, "FixtureUntaggedPreimageV1<oneOf:1>"),
      );
      matched = FixtureUntaggedPreimageV1Variant1(decoded);
      matchCount += 1;
    } on FormatException {
      // A different closed branch may still match.
    }
    try {
      final decoded = FixtureUntaggedPreimageV1Variant2Value.fromJson(
        _expectMap(value, "FixtureUntaggedPreimageV1<oneOf:2>"),
      );
      matched = FixtureUntaggedPreimageV1Variant2(decoded);
      matchCount += 1;
    } on FormatException {
      // A different closed branch may still match.
    }
    if (matchCount == 0)
      throw const FormatException(
        'FixtureUntaggedPreimageV1: NO_ONE_OF_VARIANT',
      );
    if (matchCount > 1)
      throw const FormatException(
        'FixtureUntaggedPreimageV1: AMBIGUOUS_ONE_OF_VARIANT',
      );
    return matched!;
  }

  Object? toJson();
}

final class FixtureUntaggedPreimageV1Variant1
    extends FixtureUntaggedPreimageV1 {
  const FixtureUntaggedPreimageV1Variant1(this.value);

  final FixtureUntaggedPreimageV1Variant1Value value;

  @override
  Object? toJson() => value.toJson();
}

final class FixtureUntaggedPreimageV1Variant2
    extends FixtureUntaggedPreimageV1 {
  const FixtureUntaggedPreimageV1Variant2(this.value);

  final FixtureUntaggedPreimageV1Variant2Value value;

  @override
  Object? toJson() => value.toJson();
}

final class GapRepairIntentPreimageV1 {
  const GapRepairIntentPreimageV1({
    required this.digestDomain,
    required this.source,
    required this.readSpecDigest,
    required this.boundaryKind,
    required this.repairKind,
  });

  final GapRepairIntentPreimageV1DigestDomain digestDomain;
  final FixtureSourceRef source;
  final Sha256Hex64 readSpecDigest;
  final GapRepairIntentPreimageV1BoundaryKind boundaryKind;
  final GapRepairIntentPreimageV1RepairKind repairKind;

  factory GapRepairIntentPreimageV1.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "source",
        "readSpecDigest",
        "boundaryKind",
        "repairKind",
      },
      const {
        "digestDomain",
        "source",
        "readSpecDigest",
        "boundaryKind",
        "repairKind",
      },
      "GapRepairIntentPreimageV1",
    );
    return GapRepairIntentPreimageV1(
      digestDomain: GapRepairIntentPreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "GapRepairIntentPreimageV1.digestDomain",
        ),
      ),
      source: FixtureSourceRef.fromJson(
        _expectMap(json["source"], "GapRepairIntentPreimageV1.source"),
      ),
      readSpecDigest: _expectSha256Hex64(
        json["readSpecDigest"],
        "GapRepairIntentPreimageV1.readSpecDigest",
      ),
      boundaryKind: GapRepairIntentPreimageV1BoundaryKind.fromWire(
        _expectString(
          json["boundaryKind"],
          "GapRepairIntentPreimageV1.boundaryKind",
        ),
      ),
      repairKind: GapRepairIntentPreimageV1RepairKind.fromWire(
        _expectString(
          json["repairKind"],
          "GapRepairIntentPreimageV1.repairKind",
        ),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "source": source.toJson(),
    "readSpecDigest": readSpecDigest,
    "boundaryKind": boundaryKind.wire,
    "repairKind": repairKind.wire,
  };
}

final class MaterializationBeginHeaderPreimageV1 {
  const MaterializationBeginHeaderPreimageV1({
    required this.digestDomain,
    required this.source,
    required this.manifestDigest,
    required this.coverageDigest,
    required this.pageCount,
  });

  final MaterializationBeginHeaderPreimageV1DigestDomain digestDomain;
  final FixtureSourceRef source;
  final Sha256Hex64 manifestDigest;
  final Sha256Hex64 coverageDigest;
  final int pageCount;

  factory MaterializationBeginHeaderPreimageV1.fromJson(
    Map<String, Object?> json,
  ) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "source",
        "manifestDigest",
        "coverageDigest",
        "pageCount",
      },
      const {
        "digestDomain",
        "source",
        "manifestDigest",
        "coverageDigest",
        "pageCount",
      },
      "MaterializationBeginHeaderPreimageV1",
    );
    return MaterializationBeginHeaderPreimageV1(
      digestDomain: MaterializationBeginHeaderPreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "MaterializationBeginHeaderPreimageV1.digestDomain",
        ),
      ),
      source: FixtureSourceRef.fromJson(
        _expectMap(
          json["source"],
          "MaterializationBeginHeaderPreimageV1.source",
        ),
      ),
      manifestDigest: _expectSha256Hex64(
        json["manifestDigest"],
        "MaterializationBeginHeaderPreimageV1.manifestDigest",
      ),
      coverageDigest: _expectSha256Hex64(
        json["coverageDigest"],
        "MaterializationBeginHeaderPreimageV1.coverageDigest",
      ),
      pageCount: _expectInt(
        json["pageCount"],
        "MaterializationBeginHeaderPreimageV1.pageCount",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "source": source.toJson(),
    "manifestDigest": manifestDigest,
    "coverageDigest": coverageDigest,
    "pageCount": pageCount,
  };
}

final class MaterializationCoveragePreimageV1 {
  const MaterializationCoveragePreimageV1({
    required this.digestDomain,
    required this.structuralCoverage,
    required this.payloadCoverage,
    required this.gapOrdinals,
  });

  final MaterializationCoveragePreimageV1DigestDomain digestDomain;
  final MaterializationCoveragePreimageV1StructuralCoverage structuralCoverage;
  final MaterializationCoveragePreimageV1PayloadCoverage payloadCoverage;
  final List<int> gapOrdinals;

  factory MaterializationCoveragePreimageV1.fromJson(
    Map<String, Object?> json,
  ) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "structuralCoverage",
        "payloadCoverage",
        "gapOrdinals",
      },
      const {
        "digestDomain",
        "structuralCoverage",
        "payloadCoverage",
        "gapOrdinals",
      },
      "MaterializationCoveragePreimageV1",
    );
    return MaterializationCoveragePreimageV1(
      digestDomain: MaterializationCoveragePreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "MaterializationCoveragePreimageV1.digestDomain",
        ),
      ),
      structuralCoverage:
          MaterializationCoveragePreimageV1StructuralCoverage.fromWire(
            _expectString(
              json["structuralCoverage"],
              "MaterializationCoveragePreimageV1.structuralCoverage",
            ),
          ),
      payloadCoverage:
          MaterializationCoveragePreimageV1PayloadCoverage.fromWire(
            _expectString(
              json["payloadCoverage"],
              "MaterializationCoveragePreimageV1.payloadCoverage",
            ),
          ),
      gapOrdinals: _decodeList<int>(
        json["gapOrdinals"],
        "MaterializationCoveragePreimageV1.gapOrdinals",
        (value) => _expectInt(
          value,
          "MaterializationCoveragePreimageV1.gapOrdinals[]",
        ),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "structuralCoverage": structuralCoverage.wire,
    "payloadCoverage": payloadCoverage.wire,
    "gapOrdinals": gapOrdinals.map((value) => value).toList(growable: false),
  };
}

final class MaterializationManifestPreimageV1 {
  const MaterializationManifestPreimageV1({
    required this.digestDomain,
    required this.algorithmVersion,
    required this.pageCount,
    required this.orderedPageDigests,
    required this.orderDigest,
    required this.coverageDigest,
  });

  final MaterializationManifestPreimageV1DigestDomain digestDomain;
  final int algorithmVersion;
  final int pageCount;
  final List<Sha256Hex64> orderedPageDigests;
  final Sha256Hex64 orderDigest;
  final Sha256Hex64 coverageDigest;

  factory MaterializationManifestPreimageV1.fromJson(
    Map<String, Object?> json,
  ) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "algorithmVersion",
        "pageCount",
        "orderedPageDigests",
        "orderDigest",
        "coverageDigest",
      },
      const {
        "digestDomain",
        "algorithmVersion",
        "pageCount",
        "orderedPageDigests",
        "orderDigest",
        "coverageDigest",
      },
      "MaterializationManifestPreimageV1",
    );
    return MaterializationManifestPreimageV1(
      digestDomain: MaterializationManifestPreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "MaterializationManifestPreimageV1.digestDomain",
        ),
      ),
      algorithmVersion: _expectInt(
        json["algorithmVersion"],
        "MaterializationManifestPreimageV1.algorithmVersion",
      ),
      pageCount: _expectInt(
        json["pageCount"],
        "MaterializationManifestPreimageV1.pageCount",
      ),
      orderedPageDigests: _decodeList<Sha256Hex64>(
        json["orderedPageDigests"],
        "MaterializationManifestPreimageV1.orderedPageDigests",
        (value) => _expectSha256Hex64(
          value,
          "MaterializationManifestPreimageV1.orderedPageDigests[]",
        ),
      ),
      orderDigest: _expectSha256Hex64(
        json["orderDigest"],
        "MaterializationManifestPreimageV1.orderDigest",
      ),
      coverageDigest: _expectSha256Hex64(
        json["coverageDigest"],
        "MaterializationManifestPreimageV1.coverageDigest",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "algorithmVersion": algorithmVersion,
    "pageCount": pageCount,
    "orderedPageDigests": orderedPageDigests
        .map((value) => value)
        .toList(growable: false),
    "orderDigest": orderDigest,
    "coverageDigest": coverageDigest,
  };
}

sealed class MaterializationOrderPreimageV1 {
  const MaterializationOrderPreimageV1();

  factory MaterializationOrderPreimageV1.fromJson(Map<String, Object?> json) {
    final tag = _expectString(
      json["domain"],
      "MaterializationOrderPreimageV1.domain",
    );
    return switch (tag) {
      "CATALOG" => MaterializationOrderPreimageV1CATALOG.fromJson(json),
      "TIMELINE" => MaterializationOrderPreimageV1TIMELINE.fromJson(json),
      _ => throw FormatException(
        'Unknown MaterializationOrderPreimageV1 discriminator: $tag',
      ),
    };
  }

  Map<String, Object?> toJson();
}

final class MaterializationOrderPreimageV1CATALOG
    extends MaterializationOrderPreimageV1 {
  const MaterializationOrderPreimageV1CATALOG({
    required this.digestDomain,
    required this.source,
    required this.orderedSessionIds,
  });

  final MaterializationOrderPreimageV1CATALOGDigestDomain digestDomain;
  final FixtureSourceRef source;
  final List<String> orderedSessionIds;

  factory MaterializationOrderPreimageV1CATALOG.fromJson(
    Map<String, Object?> json,
  ) {
    _expectKeys(
      json,
      const {"domain", "digestDomain", "source", "orderedSessionIds"},
      const {"domain", "digestDomain", "source", "orderedSessionIds"},
      "MaterializationOrderPreimageV1CATALOG",
    );
    if (json["domain"] != "CATALOG")
      throw const FormatException('Union discriminator mismatch');
    return MaterializationOrderPreimageV1CATALOG(
      digestDomain: MaterializationOrderPreimageV1CATALOGDigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "MaterializationOrderPreimageV1CATALOG.digestDomain",
        ),
      ),
      source: FixtureSourceRef.fromJson(
        _expectMap(
          json["source"],
          "MaterializationOrderPreimageV1CATALOG.source",
        ),
      ),
      orderedSessionIds: _decodeList<String>(
        json["orderedSessionIds"],
        "MaterializationOrderPreimageV1CATALOG.orderedSessionIds",
        (value) => _expectString(
          value,
          "MaterializationOrderPreimageV1CATALOG.orderedSessionIds[]",
        ),
      ),
    );
  }

  @override
  Map<String, Object?> toJson() => {
    "domain": "CATALOG",
    "digestDomain": digestDomain.wire,
    "source": source.toJson(),
    "orderedSessionIds": orderedSessionIds
        .map((value) => value)
        .toList(growable: false),
  };
}

final class MaterializationOrderPreimageV1TIMELINE
    extends MaterializationOrderPreimageV1 {
  const MaterializationOrderPreimageV1TIMELINE({
    required this.digestDomain,
    required this.source,
    required this.orderedTimelineIds,
  });

  final MaterializationOrderPreimageV1TIMELINEDigestDomain digestDomain;
  final FixtureSourceRef source;
  final List<String> orderedTimelineIds;

  factory MaterializationOrderPreimageV1TIMELINE.fromJson(
    Map<String, Object?> json,
  ) {
    _expectKeys(
      json,
      const {"domain", "digestDomain", "source", "orderedTimelineIds"},
      const {"domain", "digestDomain", "source", "orderedTimelineIds"},
      "MaterializationOrderPreimageV1TIMELINE",
    );
    if (json["domain"] != "TIMELINE")
      throw const FormatException('Union discriminator mismatch');
    return MaterializationOrderPreimageV1TIMELINE(
      digestDomain: MaterializationOrderPreimageV1TIMELINEDigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "MaterializationOrderPreimageV1TIMELINE.digestDomain",
        ),
      ),
      source: FixtureSourceRef.fromJson(
        _expectMap(
          json["source"],
          "MaterializationOrderPreimageV1TIMELINE.source",
        ),
      ),
      orderedTimelineIds: _decodeList<String>(
        json["orderedTimelineIds"],
        "MaterializationOrderPreimageV1TIMELINE.orderedTimelineIds",
        (value) => _expectString(
          value,
          "MaterializationOrderPreimageV1TIMELINE.orderedTimelineIds[]",
        ),
      ),
    );
  }

  @override
  Map<String, Object?> toJson() => {
    "domain": "TIMELINE",
    "digestDomain": digestDomain.wire,
    "source": source.toJson(),
    "orderedTimelineIds": orderedTimelineIds
        .map((value) => value)
        .toList(growable: false),
  };
}

final class MaterializationPagePreimageV1 {
  const MaterializationPagePreimageV1({
    required this.digestDomain,
    required this.source,
    required this.pageIndex,
    required this.pageCount,
    this.previousPageDigest,
    required this.body,
  });

  final MaterializationPagePreimageV1DigestDomain digestDomain;
  final FixtureSourceRef source;
  final int pageIndex;
  final int pageCount;
  final Sha256Hex64? previousPageDigest;
  final FixturePageBodyV1 body;

  factory MaterializationPagePreimageV1.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"digestDomain", "source", "pageIndex", "pageCount", "body"},
      const {
        "digestDomain",
        "source",
        "pageIndex",
        "pageCount",
        "previousPageDigest",
        "body",
      },
      "MaterializationPagePreimageV1",
    );
    return MaterializationPagePreimageV1(
      digestDomain: MaterializationPagePreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "MaterializationPagePreimageV1.digestDomain",
        ),
      ),
      source: FixtureSourceRef.fromJson(
        _expectMap(json["source"], "MaterializationPagePreimageV1.source"),
      ),
      pageIndex: _expectInt(
        json["pageIndex"],
        "MaterializationPagePreimageV1.pageIndex",
      ),
      pageCount: _expectInt(
        json["pageCount"],
        "MaterializationPagePreimageV1.pageCount",
      ),
      previousPageDigest: json.containsKey("previousPageDigest")
          ? _expectSha256Hex64(
              json["previousPageDigest"],
              "MaterializationPagePreimageV1.previousPageDigest",
            )
          : null,
      body: FixturePageBodyV1.fromJson(
        _expectMap(json["body"], "MaterializationPagePreimageV1.body"),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "source": source.toJson(),
    "pageIndex": pageIndex,
    "pageCount": pageCount,
    if (previousPageDigest != null) "previousPageDigest": previousPageDigest!,
    "body": body.toJson(),
  };
}

final class MaterializationReceiptPreimageV1 {
  const MaterializationReceiptPreimageV1({
    required this.digestDomain,
    required this.receiptId,
    required this.beginHeaderDigest,
    required this.manifestDigest,
    required this.status,
    required this.stagedBytes,
  });

  final MaterializationReceiptPreimageV1DigestDomain digestDomain;
  final String receiptId;
  final Sha256Hex64 beginHeaderDigest;
  final Sha256Hex64 manifestDigest;
  final MaterializationReceiptPreimageV1Status status;
  final int stagedBytes;

  factory MaterializationReceiptPreimageV1.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "receiptId",
        "beginHeaderDigest",
        "manifestDigest",
        "status",
        "stagedBytes",
      },
      const {
        "digestDomain",
        "receiptId",
        "beginHeaderDigest",
        "manifestDigest",
        "status",
        "stagedBytes",
      },
      "MaterializationReceiptPreimageV1",
    );
    return MaterializationReceiptPreimageV1(
      digestDomain: MaterializationReceiptPreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "MaterializationReceiptPreimageV1.digestDomain",
        ),
      ),
      receiptId: _expectString(
        json["receiptId"],
        "MaterializationReceiptPreimageV1.receiptId",
      ),
      beginHeaderDigest: _expectSha256Hex64(
        json["beginHeaderDigest"],
        "MaterializationReceiptPreimageV1.beginHeaderDigest",
      ),
      manifestDigest: _expectSha256Hex64(
        json["manifestDigest"],
        "MaterializationReceiptPreimageV1.manifestDigest",
      ),
      status: MaterializationReceiptPreimageV1Status.fromWire(
        _expectString(
          json["status"],
          "MaterializationReceiptPreimageV1.status",
        ),
      ),
      stagedBytes: _expectInt(
        json["stagedBytes"],
        "MaterializationReceiptPreimageV1.stagedBytes",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "receiptId": receiptId,
    "beginHeaderDigest": beginHeaderDigest,
    "manifestDigest": manifestDigest,
    "status": status.wire,
    "stagedBytes": stagedBytes,
  };
}

final class OperationFingerprintPreimageV1 {
  const OperationFingerprintPreimageV1({
    required this.digestDomain,
    required this.operationCode,
    required this.source,
    required this.payloadDigest,
    required this.preconditionDigest,
    required this.sequence,
  });

  final OperationFingerprintPreimageV1DigestDomain digestDomain;
  final OperationFingerprintPreimageV1OperationCode operationCode;
  final FixtureSourceRef source;
  final Sha256Hex64 payloadDigest;
  final Sha256Hex64 preconditionDigest;
  final int sequence;

  factory OperationFingerprintPreimageV1.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "operationCode",
        "source",
        "payloadDigest",
        "preconditionDigest",
        "sequence",
      },
      const {
        "digestDomain",
        "operationCode",
        "source",
        "payloadDigest",
        "preconditionDigest",
        "sequence",
      },
      "OperationFingerprintPreimageV1",
    );
    return OperationFingerprintPreimageV1(
      digestDomain: OperationFingerprintPreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "OperationFingerprintPreimageV1.digestDomain",
        ),
      ),
      operationCode: OperationFingerprintPreimageV1OperationCode.fromWire(
        _expectString(
          json["operationCode"],
          "OperationFingerprintPreimageV1.operationCode",
        ),
      ),
      source: FixtureSourceRef.fromJson(
        _expectMap(json["source"], "OperationFingerprintPreimageV1.source"),
      ),
      payloadDigest: _expectSha256Hex64(
        json["payloadDigest"],
        "OperationFingerprintPreimageV1.payloadDigest",
      ),
      preconditionDigest: _expectSha256Hex64(
        json["preconditionDigest"],
        "OperationFingerprintPreimageV1.preconditionDigest",
      ),
      sequence: _expectInt(
        json["sequence"],
        "OperationFingerprintPreimageV1.sequence",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "operationCode": operationCode.wire,
    "source": source.toJson(),
    "payloadDigest": payloadDigest,
    "preconditionDigest": preconditionDigest,
    "sequence": sequence,
  };
}

final class ProviderReadEvidencePreimageV1 {
  const ProviderReadEvidencePreimageV1({
    required this.digestDomain,
    required this.providerMethod,
    required this.codexBuildDigest,
    required this.readGeneration,
    required this.resultDigest,
    required this.resultCount,
  });

  final ProviderReadEvidencePreimageV1DigestDomain digestDomain;
  final ProviderReadEvidencePreimageV1ProviderMethod providerMethod;
  final Sha256Hex64 codexBuildDigest;
  final int readGeneration;
  final Sha256Hex64 resultDigest;
  final int resultCount;

  factory ProviderReadEvidencePreimageV1.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        "digestDomain",
        "providerMethod",
        "codexBuildDigest",
        "readGeneration",
        "resultDigest",
        "resultCount",
      },
      const {
        "digestDomain",
        "providerMethod",
        "codexBuildDigest",
        "readGeneration",
        "resultDigest",
        "resultCount",
      },
      "ProviderReadEvidencePreimageV1",
    );
    return ProviderReadEvidencePreimageV1(
      digestDomain: ProviderReadEvidencePreimageV1DigestDomain.fromWire(
        _expectString(
          json["digestDomain"],
          "ProviderReadEvidencePreimageV1.digestDomain",
        ),
      ),
      providerMethod: ProviderReadEvidencePreimageV1ProviderMethod.fromWire(
        _expectString(
          json["providerMethod"],
          "ProviderReadEvidencePreimageV1.providerMethod",
        ),
      ),
      codexBuildDigest: _expectSha256Hex64(
        json["codexBuildDigest"],
        "ProviderReadEvidencePreimageV1.codexBuildDigest",
      ),
      readGeneration: _expectInt(
        json["readGeneration"],
        "ProviderReadEvidencePreimageV1.readGeneration",
      ),
      resultDigest: _expectSha256Hex64(
        json["resultDigest"],
        "ProviderReadEvidencePreimageV1.resultDigest",
      ),
      resultCount: _expectInt(
        json["resultCount"],
        "ProviderReadEvidencePreimageV1.resultCount",
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain.wire,
    "providerMethod": providerMethod.wire,
    "codexBuildDigest": codexBuildDigest,
    "readGeneration": readGeneration,
    "resultDigest": resultDigest,
    "resultCount": resultCount,
  };
}

typedef Sha256Hex64 = String;

enum CanonicalProfileProbePreimageV1DigestDomain {
  ccpocketCanonicalProfileProbeV1("ccpocket.canonical-profile-probe.v1");

  const CanonicalProfileProbePreimageV1DigestDomain(this.wire);

  final String wire;

  static CanonicalProfileProbePreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown CanonicalProfileProbePreimageV1DigestDomain value: $value',
    );
  }
}

final class FixtureConstraintItemIdentity {
  const FixtureConstraintItemIdentity({required this.id});

  final String id;

  factory FixtureConstraintItemIdentity.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"id"},
      const {"id"},
      "FixtureConstraintItemIdentity",
    );
    return FixtureConstraintItemIdentity(
      id: _expectConstrainedString(
        json["id"],
        "FixtureConstraintItemIdentity.id",
        pattern: "^[a-z]+\$",
      ),
    );
  }

  Map<String, Object?> toJson() => {"id": id};
}

final class FixtureOneOfVariant1Value {
  const FixtureOneOfVariant1Value({required this.left});

  final String left;

  factory FixtureOneOfVariant1Value.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"left"},
      const {"left"},
      "FixtureOneOfVariant1Value",
    );
    return FixtureOneOfVariant1Value(
      left: _expectString(json["left"], "FixtureOneOfVariant1Value.left"),
    );
  }

  Map<String, Object?> toJson() => {"left": left};
}

final class FixtureOneOfVariant2Value {
  const FixtureOneOfVariant2Value({required this.right});

  final int right;

  factory FixtureOneOfVariant2Value.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {"right"},
      const {"right"},
      "FixtureOneOfVariant2Value",
    );
    return FixtureOneOfVariant2Value(
      right: _expectInt(json["right"], "FixtureOneOfVariant2Value.right"),
    );
  }

  Map<String, Object?> toJson() => {"right": right};
}

final class FixtureUntaggedPreimageV1Variant1Value {
  const FixtureUntaggedPreimageV1Variant1Value({
    required this.digestDomain,
    required this.left,
  });

  final String digestDomain;
  final String? left;

  factory FixtureUntaggedPreimageV1Variant1Value.fromJson(
    Map<String, Object?> json,
  ) {
    _expectKeys(
      json,
      const {"digestDomain", "left"},
      const {"digestDomain", "left"},
      "FixtureUntaggedPreimageV1Variant1Value",
    );
    return FixtureUntaggedPreimageV1Variant1Value(
      digestDomain: _expectConstrainedString(
        json["digestDomain"],
        "FixtureUntaggedPreimageV1Variant1Value.digestDomain",
        constValue: "ccpocket.fixture-untagged.v1",
      ),
      left: (json["left"] == null
          ? null
          : _expectString(
              json["left"],
              "FixtureUntaggedPreimageV1Variant1Value.left",
            )),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain,
    "left": (left == null ? null : left!),
  };
}

final class FixtureUntaggedPreimageV1Variant2Value {
  const FixtureUntaggedPreimageV1Variant2Value({
    required this.digestDomain,
    required this.right,
  });

  final String digestDomain;
  final int right;

  factory FixtureUntaggedPreimageV1Variant2Value.fromJson(
    Map<String, Object?> json,
  ) {
    _expectKeys(
      json,
      const {"digestDomain", "right"},
      const {"digestDomain", "right"},
      "FixtureUntaggedPreimageV1Variant2Value",
    );
    return FixtureUntaggedPreimageV1Variant2Value(
      digestDomain: _expectConstrainedString(
        json["digestDomain"],
        "FixtureUntaggedPreimageV1Variant2Value.digestDomain",
        constValue: "ccpocket.fixture-untagged.v1",
      ),
      right: _expectConstrainedInt(
        json["right"],
        "FixtureUntaggedPreimageV1Variant2Value.right",
        minimum: 0,
        maximum: 9,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    "digestDomain": digestDomain,
    "right": right,
  };
}

enum GapRepairIntentPreimageV1DigestDomain {
  ccpocketGapRepairIntentV1("ccpocket.gap-repair-intent.v1");

  const GapRepairIntentPreimageV1DigestDomain(this.wire);

  final String wire;

  static GapRepairIntentPreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown GapRepairIntentPreimageV1DigestDomain value: $value',
    );
  }
}

enum GapRepairIntentPreimageV1BoundaryKind {
  bEFORE("BEFORE"),
  aFTER("AFTER"),
  bETWEEN("BETWEEN");

  const GapRepairIntentPreimageV1BoundaryKind(this.wire);

  final String wire;

  static GapRepairIntentPreimageV1BoundaryKind fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown GapRepairIntentPreimageV1BoundaryKind value: $value',
    );
  }
}

enum GapRepairIntentPreimageV1RepairKind {
  nEXTPROVIDERPAGE("NEXT_PROVIDER_PAGE"),
  fULLBOUNDEDREREAD("FULL_BOUNDED_REREAD"),
  nONE("NONE");

  const GapRepairIntentPreimageV1RepairKind(this.wire);

  final String wire;

  static GapRepairIntentPreimageV1RepairKind fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown GapRepairIntentPreimageV1RepairKind value: $value',
    );
  }
}

enum MaterializationBeginHeaderPreimageV1DigestDomain {
  ccpocketMaterializationBeginV1("ccpocket.materialization-begin.v1");

  const MaterializationBeginHeaderPreimageV1DigestDomain(this.wire);

  final String wire;

  static MaterializationBeginHeaderPreimageV1DigestDomain fromWire(
    String value,
  ) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationBeginHeaderPreimageV1DigestDomain value: $value',
    );
  }
}

enum MaterializationCoveragePreimageV1DigestDomain {
  ccpocketMaterializationCoverageV1("ccpocket.materialization-coverage.v1");

  const MaterializationCoveragePreimageV1DigestDomain(this.wire);

  final String wire;

  static MaterializationCoveragePreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationCoveragePreimageV1DigestDomain value: $value',
    );
  }
}

enum MaterializationCoveragePreimageV1StructuralCoverage {
  cOMPLETE("COMPLETE"),
  pARTIAL("PARTIAL"),
  eMPTYPROVEN("EMPTY_PROVEN");

  const MaterializationCoveragePreimageV1StructuralCoverage(this.wire);

  final String wire;

  static MaterializationCoveragePreimageV1StructuralCoverage fromWire(
    String value,
  ) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationCoveragePreimageV1StructuralCoverage value: $value',
    );
  }
}

enum MaterializationCoveragePreimageV1PayloadCoverage {
  cOMPLETE("COMPLETE"),
  pARTIAL("PARTIAL");

  const MaterializationCoveragePreimageV1PayloadCoverage(this.wire);

  final String wire;

  static MaterializationCoveragePreimageV1PayloadCoverage fromWire(
    String value,
  ) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationCoveragePreimageV1PayloadCoverage value: $value',
    );
  }
}

enum MaterializationManifestPreimageV1DigestDomain {
  ccpocketMaterializationManifestV1("ccpocket.materialization-manifest.v1");

  const MaterializationManifestPreimageV1DigestDomain(this.wire);

  final String wire;

  static MaterializationManifestPreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationManifestPreimageV1DigestDomain value: $value',
    );
  }
}

enum MaterializationOrderPreimageV1CATALOGDigestDomain {
  ccpocketMaterializationOrderV1("ccpocket.materialization-order.v1");

  const MaterializationOrderPreimageV1CATALOGDigestDomain(this.wire);

  final String wire;

  static MaterializationOrderPreimageV1CATALOGDigestDomain fromWire(
    String value,
  ) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationOrderPreimageV1CATALOGDigestDomain value: $value',
    );
  }
}

enum MaterializationOrderPreimageV1TIMELINEDigestDomain {
  ccpocketMaterializationOrderV1("ccpocket.materialization-order.v1");

  const MaterializationOrderPreimageV1TIMELINEDigestDomain(this.wire);

  final String wire;

  static MaterializationOrderPreimageV1TIMELINEDigestDomain fromWire(
    String value,
  ) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationOrderPreimageV1TIMELINEDigestDomain value: $value',
    );
  }
}

enum MaterializationPagePreimageV1DigestDomain {
  ccpocketMaterializationPageV1("ccpocket.materialization-page.v1");

  const MaterializationPagePreimageV1DigestDomain(this.wire);

  final String wire;

  static MaterializationPagePreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationPagePreimageV1DigestDomain value: $value',
    );
  }
}

enum MaterializationReceiptPreimageV1DigestDomain {
  ccpocketMaterializationReceiptV1("ccpocket.materialization-receipt.v1");

  const MaterializationReceiptPreimageV1DigestDomain(this.wire);

  final String wire;

  static MaterializationReceiptPreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationReceiptPreimageV1DigestDomain value: $value',
    );
  }
}

enum MaterializationReceiptPreimageV1Status {
  vERIFIED("VERIFIED");

  const MaterializationReceiptPreimageV1Status(this.wire);

  final String wire;

  static MaterializationReceiptPreimageV1Status fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown MaterializationReceiptPreimageV1Status value: $value',
    );
  }
}

enum OperationFingerprintPreimageV1DigestDomain {
  ccpocketOperationFingerprintV1("ccpocket.operation-fingerprint.v1");

  const OperationFingerprintPreimageV1DigestDomain(this.wire);

  final String wire;

  static OperationFingerprintPreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown OperationFingerprintPreimageV1DigestDomain value: $value',
    );
  }
}

enum OperationFingerprintPreimageV1OperationCode {
  sTARTTURN("START_TURN"),
  eDITQUEUE("EDIT_QUEUE");

  const OperationFingerprintPreimageV1OperationCode(this.wire);

  final String wire;

  static OperationFingerprintPreimageV1OperationCode fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown OperationFingerprintPreimageV1OperationCode value: $value',
    );
  }
}

enum ProviderReadEvidencePreimageV1DigestDomain {
  ccpocketProviderReadEvidenceV1("ccpocket.provider-read-evidence.v1");

  const ProviderReadEvidencePreimageV1DigestDomain(this.wire);

  final String wire;

  static ProviderReadEvidencePreimageV1DigestDomain fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown ProviderReadEvidencePreimageV1DigestDomain value: $value',
    );
  }
}

enum ProviderReadEvidencePreimageV1ProviderMethod {
  tHREADTURNSLIST("THREAD_TURNS_LIST");

  const ProviderReadEvidencePreimageV1ProviderMethod(this.wire);

  final String wire;

  static ProviderReadEvidencePreimageV1ProviderMethod fromWire(String value) {
    for (final item in values) {
      if (item.wire == value) return item;
    }
    throw FormatException(
      'Unknown ProviderReadEvidencePreimageV1ProviderMethod value: $value',
    );
  }
}

CanonicalProfileProbePreimageV1 decodeCanonicalProfileProbePreimageV1(
  Object? value,
) => CanonicalProfileProbePreimageV1.fromJson(
  _expectMap(value, "CanonicalProfileProbePreimageV1"),
);
Object? encodeCanonicalProfileProbePreimageV1(
  CanonicalProfileProbePreimageV1 value,
) => value.toJson();

FixtureAmbiguousOneOf decodeFixtureAmbiguousOneOf(Object? value) =>
    FixtureAmbiguousOneOf.fromJsonValue(value);
Object? encodeFixtureAmbiguousOneOf(FixtureAmbiguousOneOf value) =>
    value.toJson();

FixtureCanonicalOrderSet decodeFixtureCanonicalOrderSet(Object? value) =>
    _decodeList<FixtureOneOf>(
      value,
      "FixtureCanonicalOrderSet",
      (value) => FixtureOneOf.fromJsonValue(value),
      minItems: 1,
      maxItems: 3,
      orderBy: const [_CollectionSelector("\$")],
      snapshot: (value) => value.toJson(),
    );
Object? encodeFixtureCanonicalOrderSet(FixtureCanonicalOrderSet value) =>
    value.map((value) => value.toJson()).toList(growable: false);

FixtureConstrainedRecord decodeFixtureConstrainedRecord(Object? value) =>
    FixtureConstrainedRecord.fromJson(
      _expectMap(value, "FixtureConstrainedRecord"),
    );
Object? encodeFixtureConstrainedRecord(FixtureConstrainedRecord value) =>
    value.toJson();

FixtureConstraintItem decodeFixtureConstraintItem(Object? value) =>
    FixtureConstraintItem.fromJson(_expectMap(value, "FixtureConstraintItem"));
Object? encodeFixtureConstraintItem(FixtureConstraintItem value) =>
    value.toJson();

FixtureEnvelope decodeFixtureEnvelope(Object? value) =>
    FixtureEnvelope.fromJson(_expectMap(value, "FixtureEnvelope"));
Object? encodeFixtureEnvelope(FixtureEnvelope value) => value.toJson();

FixtureOneOf decodeFixtureOneOf(Object? value) =>
    FixtureOneOf.fromJsonValue(value);
Object? encodeFixtureOneOf(FixtureOneOf value) => value.toJson();

FixturePageBodyV1 decodeFixturePageBodyV1(Object? value) =>
    FixturePageBodyV1.fromJson(_expectMap(value, "FixturePageBodyV1"));
Object? encodeFixturePageBodyV1(FixturePageBodyV1 value) => value.toJson();

FixturePayload decodeFixturePayload(Object? value) =>
    FixturePayload.fromJson(_expectMap(value, "FixturePayload"));
Object? encodeFixturePayload(FixturePayload value) => value.toJson();

FixturePriority decodeFixturePriority(Object? value) =>
    FixturePriority.fromWire(_expectString(value, "FixturePriority"));
Object? encodeFixturePriority(FixturePriority value) => value.wire;

FixtureSourceRef decodeFixtureSourceRef(Object? value) =>
    FixtureSourceRef.fromJson(_expectMap(value, "FixtureSourceRef"));
Object? encodeFixtureSourceRef(FixtureSourceRef value) => value.toJson();

FixtureUntaggedPreimageV1 decodeFixtureUntaggedPreimageV1(Object? value) =>
    FixtureUntaggedPreimageV1.fromJsonValue(value);
Object? encodeFixtureUntaggedPreimageV1(FixtureUntaggedPreimageV1 value) =>
    value.toJson();

GapRepairIntentPreimageV1 decodeGapRepairIntentPreimageV1(Object? value) =>
    GapRepairIntentPreimageV1.fromJson(
      _expectMap(value, "GapRepairIntentPreimageV1"),
    );
Object? encodeGapRepairIntentPreimageV1(GapRepairIntentPreimageV1 value) =>
    value.toJson();

MaterializationBeginHeaderPreimageV1 decodeMaterializationBeginHeaderPreimageV1(
  Object? value,
) => MaterializationBeginHeaderPreimageV1.fromJson(
  _expectMap(value, "MaterializationBeginHeaderPreimageV1"),
);
Object? encodeMaterializationBeginHeaderPreimageV1(
  MaterializationBeginHeaderPreimageV1 value,
) => value.toJson();

MaterializationCoveragePreimageV1 decodeMaterializationCoveragePreimageV1(
  Object? value,
) => MaterializationCoveragePreimageV1.fromJson(
  _expectMap(value, "MaterializationCoveragePreimageV1"),
);
Object? encodeMaterializationCoveragePreimageV1(
  MaterializationCoveragePreimageV1 value,
) => value.toJson();

MaterializationManifestPreimageV1 decodeMaterializationManifestPreimageV1(
  Object? value,
) => MaterializationManifestPreimageV1.fromJson(
  _expectMap(value, "MaterializationManifestPreimageV1"),
);
Object? encodeMaterializationManifestPreimageV1(
  MaterializationManifestPreimageV1 value,
) => value.toJson();

MaterializationOrderPreimageV1 decodeMaterializationOrderPreimageV1(
  Object? value,
) => MaterializationOrderPreimageV1.fromJson(
  _expectMap(value, "MaterializationOrderPreimageV1"),
);
Object? encodeMaterializationOrderPreimageV1(
  MaterializationOrderPreimageV1 value,
) => value.toJson();

MaterializationPagePreimageV1 decodeMaterializationPagePreimageV1(
  Object? value,
) => MaterializationPagePreimageV1.fromJson(
  _expectMap(value, "MaterializationPagePreimageV1"),
);
Object? encodeMaterializationPagePreimageV1(
  MaterializationPagePreimageV1 value,
) => value.toJson();

MaterializationReceiptPreimageV1 decodeMaterializationReceiptPreimageV1(
  Object? value,
) => MaterializationReceiptPreimageV1.fromJson(
  _expectMap(value, "MaterializationReceiptPreimageV1"),
);
Object? encodeMaterializationReceiptPreimageV1(
  MaterializationReceiptPreimageV1 value,
) => value.toJson();

OperationFingerprintPreimageV1 decodeOperationFingerprintPreimageV1(
  Object? value,
) => OperationFingerprintPreimageV1.fromJson(
  _expectMap(value, "OperationFingerprintPreimageV1"),
);
Object? encodeOperationFingerprintPreimageV1(
  OperationFingerprintPreimageV1 value,
) => value.toJson();

ProviderReadEvidencePreimageV1 decodeProviderReadEvidencePreimageV1(
  Object? value,
) => ProviderReadEvidencePreimageV1.fromJson(
  _expectMap(value, "ProviderReadEvidencePreimageV1"),
);
Object? encodeProviderReadEvidencePreimageV1(
  ProviderReadEvidencePreimageV1 value,
) => value.toJson();

Sha256Hex64 decodeSha256Hex64(Object? value) =>
    _expectSha256Hex64(value, "Sha256Hex64");
Object? encodeSha256Hex64(Sha256Hex64 value) => value;

Uint8List canonicalBytesCanonicalProfileProbePreimageV1(
  CanonicalProfileProbePreimageV1 value,
) {
  final snapshot = decodeCanonicalProfileProbePreimageV1(
    encodeCanonicalProfileProbePreimageV1(value),
  );
  final json = _expectMap(
    encodeCanonicalProfileProbePreimageV1(snapshot),
    "CanonicalProfileProbePreimageV1",
  );
  _expectDigestDomain("CanonicalProfileProbePreimageV1", json);
  return _canonicalBytes(json);
}

String digestCanonicalProfileProbePreimageV1(
  CanonicalProfileProbePreimageV1 value,
) => sha256
    .convert(canonicalBytesCanonicalProfileProbePreimageV1(value))
    .toString();

Uint8List canonicalBytesFixtureUntaggedPreimageV1(
  FixtureUntaggedPreimageV1 value,
) {
  final snapshot = decodeFixtureUntaggedPreimageV1(
    encodeFixtureUntaggedPreimageV1(value),
  );
  final json = _expectMap(
    encodeFixtureUntaggedPreimageV1(snapshot),
    "FixtureUntaggedPreimageV1",
  );
  _expectDigestDomain("FixtureUntaggedPreimageV1", json);
  return _canonicalBytes(json);
}

String digestFixtureUntaggedPreimageV1(FixtureUntaggedPreimageV1 value) =>
    sha256.convert(canonicalBytesFixtureUntaggedPreimageV1(value)).toString();

Uint8List canonicalBytesGapRepairIntentPreimageV1(
  GapRepairIntentPreimageV1 value,
) {
  final snapshot = decodeGapRepairIntentPreimageV1(
    encodeGapRepairIntentPreimageV1(value),
  );
  final json = _expectMap(
    encodeGapRepairIntentPreimageV1(snapshot),
    "GapRepairIntentPreimageV1",
  );
  _expectDigestDomain("GapRepairIntentPreimageV1", json);
  return _canonicalBytes(json);
}

String digestGapRepairIntentPreimageV1(GapRepairIntentPreimageV1 value) =>
    sha256.convert(canonicalBytesGapRepairIntentPreimageV1(value)).toString();

Uint8List canonicalBytesMaterializationBeginHeaderPreimageV1(
  MaterializationBeginHeaderPreimageV1 value,
) {
  final snapshot = decodeMaterializationBeginHeaderPreimageV1(
    encodeMaterializationBeginHeaderPreimageV1(value),
  );
  final json = _expectMap(
    encodeMaterializationBeginHeaderPreimageV1(snapshot),
    "MaterializationBeginHeaderPreimageV1",
  );
  _expectDigestDomain("MaterializationBeginHeaderPreimageV1", json);
  return _canonicalBytes(json);
}

String digestMaterializationBeginHeaderPreimageV1(
  MaterializationBeginHeaderPreimageV1 value,
) => sha256
    .convert(canonicalBytesMaterializationBeginHeaderPreimageV1(value))
    .toString();

Uint8List canonicalBytesMaterializationCoveragePreimageV1(
  MaterializationCoveragePreimageV1 value,
) {
  final snapshot = decodeMaterializationCoveragePreimageV1(
    encodeMaterializationCoveragePreimageV1(value),
  );
  final json = _expectMap(
    encodeMaterializationCoveragePreimageV1(snapshot),
    "MaterializationCoveragePreimageV1",
  );
  _expectDigestDomain("MaterializationCoveragePreimageV1", json);
  return _canonicalBytes(json);
}

String digestMaterializationCoveragePreimageV1(
  MaterializationCoveragePreimageV1 value,
) => sha256
    .convert(canonicalBytesMaterializationCoveragePreimageV1(value))
    .toString();

Uint8List canonicalBytesMaterializationManifestPreimageV1(
  MaterializationManifestPreimageV1 value,
) {
  final snapshot = decodeMaterializationManifestPreimageV1(
    encodeMaterializationManifestPreimageV1(value),
  );
  final json = _expectMap(
    encodeMaterializationManifestPreimageV1(snapshot),
    "MaterializationManifestPreimageV1",
  );
  _expectDigestDomain("MaterializationManifestPreimageV1", json);
  return _canonicalBytes(json);
}

String digestMaterializationManifestPreimageV1(
  MaterializationManifestPreimageV1 value,
) => sha256
    .convert(canonicalBytesMaterializationManifestPreimageV1(value))
    .toString();

Uint8List canonicalBytesMaterializationOrderPreimageV1(
  MaterializationOrderPreimageV1 value,
) {
  final snapshot = decodeMaterializationOrderPreimageV1(
    encodeMaterializationOrderPreimageV1(value),
  );
  final json = _expectMap(
    encodeMaterializationOrderPreimageV1(snapshot),
    "MaterializationOrderPreimageV1",
  );
  _expectDigestDomain("MaterializationOrderPreimageV1", json);
  return _canonicalBytes(json);
}

String digestMaterializationOrderPreimageV1(
  MaterializationOrderPreimageV1 value,
) => sha256
    .convert(canonicalBytesMaterializationOrderPreimageV1(value))
    .toString();

Uint8List canonicalBytesMaterializationPagePreimageV1(
  MaterializationPagePreimageV1 value,
) {
  final snapshot = decodeMaterializationPagePreimageV1(
    encodeMaterializationPagePreimageV1(value),
  );
  final json = _expectMap(
    encodeMaterializationPagePreimageV1(snapshot),
    "MaterializationPagePreimageV1",
  );
  _expectDigestDomain("MaterializationPagePreimageV1", json);
  return _canonicalBytes(json);
}

String digestMaterializationPagePreimageV1(
  MaterializationPagePreimageV1 value,
) => sha256
    .convert(canonicalBytesMaterializationPagePreimageV1(value))
    .toString();

Uint8List canonicalBytesMaterializationReceiptPreimageV1(
  MaterializationReceiptPreimageV1 value,
) {
  final snapshot = decodeMaterializationReceiptPreimageV1(
    encodeMaterializationReceiptPreimageV1(value),
  );
  final json = _expectMap(
    encodeMaterializationReceiptPreimageV1(snapshot),
    "MaterializationReceiptPreimageV1",
  );
  _expectDigestDomain("MaterializationReceiptPreimageV1", json);
  return _canonicalBytes(json);
}

String digestMaterializationReceiptPreimageV1(
  MaterializationReceiptPreimageV1 value,
) => sha256
    .convert(canonicalBytesMaterializationReceiptPreimageV1(value))
    .toString();

Uint8List canonicalBytesOperationFingerprintPreimageV1(
  OperationFingerprintPreimageV1 value,
) {
  final snapshot = decodeOperationFingerprintPreimageV1(
    encodeOperationFingerprintPreimageV1(value),
  );
  final json = _expectMap(
    encodeOperationFingerprintPreimageV1(snapshot),
    "OperationFingerprintPreimageV1",
  );
  _expectDigestDomain("OperationFingerprintPreimageV1", json);
  return _canonicalBytes(json);
}

String digestOperationFingerprintPreimageV1(
  OperationFingerprintPreimageV1 value,
) => sha256
    .convert(canonicalBytesOperationFingerprintPreimageV1(value))
    .toString();

Uint8List canonicalBytesProviderReadEvidencePreimageV1(
  ProviderReadEvidencePreimageV1 value,
) {
  final snapshot = decodeProviderReadEvidencePreimageV1(
    encodeProviderReadEvidencePreimageV1(value),
  );
  final json = _expectMap(
    encodeProviderReadEvidencePreimageV1(snapshot),
    "ProviderReadEvidencePreimageV1",
  );
  _expectDigestDomain("ProviderReadEvidencePreimageV1", json);
  return _canonicalBytes(json);
}

String digestProviderReadEvidencePreimageV1(
  ProviderReadEvidencePreimageV1 value,
) => sha256
    .convert(canonicalBytesProviderReadEvidencePreimageV1(value))
    .toString();
