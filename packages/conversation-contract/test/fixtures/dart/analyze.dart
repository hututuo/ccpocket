import '../generated/contract.dart';

Map<String, Object?> envelope(Object? ordinal) => {
  'id': 'envelope-dart',
  'source': {'bridgeInstanceId': 'bridge-dart', 'sourceOrdinal': ordinal},
  'priority': r'cost$x',
  'payload': {'kind': 'text', 'text': r'cost$x'},
  'metadata': {'fixture': r'cost$x'},
  '__proto__': 'safe',
};

void expectFormatException(void Function() action) {
  try {
    action();
  } on FormatException {
    return;
  }
  throw StateError('Expected FormatException');
}

void main() {
  final decoded = decodeFixtureEnvelope(envelope(1.0));
  if (decoded.source.sourceOrdinal != 1 ||
      decoded.priority.wire != r'cost$x' ||
      decoded.proto != 'safe') {
    throw StateError('Dart decoder did not preserve the fixture');
  }
  final encoded = encodeFixtureEnvelope(decoded) as Map<String, Object?>;
  if (encoded['priority'] != r'cost$x' || encoded['__proto__'] != 'safe') {
    throw StateError('Dart round trip did not preserve escaped strings');
  }
  if (decodeFixturePriority(r'quote"slash\cost$x').wire !=
      r'quote"slash\cost$x') {
    throw StateError('Dart literal did not preserve quote/backslash/dollar');
  }

  for (final invalid in <Object?>[
    1.5,
    9007199254740992,
    -9007199254740992,
    double.infinity,
    double.negativeInfinity,
    double.nan,
  ]) {
    expectFormatException(() => decodeFixtureEnvelope(envelope(invalid)));
  }

  final nonStringMap = envelope(1);
  nonStringMap['metadata'] = <Object?, Object?>{1: 'not a string key'};
  expectFormatException(() => decodeFixtureEnvelope(nonStringMap));

  final constrained = decodeFixtureConstrainedRecord({
    'nullableValue': null,
    'fixed': 'FIXED',
    'version': 1,
    'bounded': 2,
    'disabled': false,
    'items': [
      {
        'identity': {'id': 'a'},
        'ordinal': 0,
        'label': 'item-a',
      },
    ],
    'tags': ['alpha'],
  });
  final String? nullableValue = constrained.nullableValue;
  final FixtureOneOf oneOf = decodeFixtureOneOf({'left': 'typed'});
  final List<FixtureOneOf> canonicalOrder = decodeFixtureCanonicalOrderSet([
    {'left': 'a'},
    {'right': 1},
  ]);
  if (nullableValue != null ||
      oneOf is! FixtureOneOfVariant1 ||
      canonicalOrder.length != 2) {
    throw StateError('Generated nullable or oneOf Dart type mismatch');
  }
}
