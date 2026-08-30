// @generated from conversation contract e4f018a0338b9ce09d8df016d1f2fc325c5a81b460db8251a6b868897378393b; DO NOT EDIT.
// ignore_for_file: unnecessary_cast

String _expectString(Object? value, String path) {
  if (value is! String) throw FormatException('$path: expected string');
  return value;
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

bool _expectBool(Object? value, String path) {
  if (value is! bool) throw FormatException('$path: expected boolean');
  return value;
}

List<Object?> _expectList(Object? value, String path) {
  if (value is! List) throw FormatException('$path: expected array');
  return value.cast<Object?>();
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
    if (!allowed.contains(key))
      throw FormatException('$path.$key: unknown field');
  }
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
          ? _expectList(json["labels"], "FixturePayloadProgress.labels")
                .map(
                  (value) =>
                      _expectString(value, "FixturePayloadProgress.labels[]"),
                )
                .toList(growable: false)
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

FixtureEnvelope decodeFixtureEnvelope(Object? value) =>
    FixtureEnvelope.fromJson(_expectMap(value, "FixtureEnvelope"));
Object? encodeFixtureEnvelope(FixtureEnvelope value) => value.toJson();

FixturePayload decodeFixturePayload(Object? value) =>
    FixturePayload.fromJson(_expectMap(value, "FixturePayload"));
Object? encodeFixturePayload(FixturePayload value) => value.toJson();

FixturePriority decodeFixturePriority(Object? value) =>
    FixturePriority.fromWire(_expectString(value, "FixturePriority"));
Object? encodeFixturePriority(FixturePriority value) => value.wire;

FixtureSourceRef decodeFixtureSourceRef(Object? value) =>
    FixtureSourceRef.fromJson(_expectMap(value, "FixtureSourceRef"));
Object? encodeFixtureSourceRef(FixtureSourceRef value) => value.toJson();
