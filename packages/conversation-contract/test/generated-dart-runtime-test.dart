import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'fixtures/generated/contract.dart';

typedef DigestResult = ({Uint8List bytes, String digest});

Never fail(String message) => throw StateError(message);

void expect(bool condition, String message) {
  if (!condition) fail(message);
}

void expectThrows(void Function() operation, String message) {
  try {
    operation();
  } on Object {
    return;
  }
  fail('expected failure: $message');
}

String hex(Iterable<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

Map<String, Object?> cloneMap(Object? value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

DigestResult evaluate(String typeId, Object? value) {
  switch (typeId) {
    case 'CanonicalProfileProbePreimageV1':
      final typed = decodeCanonicalProfileProbePreimageV1(value);
      return (
        bytes: canonicalBytesCanonicalProfileProbePreimageV1(typed),
        digest: digestCanonicalProfileProbePreimageV1(typed),
      );
    case 'ProviderReadEvidencePreimageV1':
      final typed = decodeProviderReadEvidencePreimageV1(value);
      return (
        bytes: canonicalBytesProviderReadEvidencePreimageV1(typed),
        digest: digestProviderReadEvidencePreimageV1(typed),
      );
    case 'OperationFingerprintPreimageV1':
      final typed = decodeOperationFingerprintPreimageV1(value);
      return (
        bytes: canonicalBytesOperationFingerprintPreimageV1(typed),
        digest: digestOperationFingerprintPreimageV1(typed),
      );
    case 'MaterializationPagePreimageV1':
      final typed = decodeMaterializationPagePreimageV1(value);
      return (
        bytes: canonicalBytesMaterializationPagePreimageV1(typed),
        digest: digestMaterializationPagePreimageV1(typed),
      );
    case 'MaterializationOrderPreimageV1':
      final typed = decodeMaterializationOrderPreimageV1(value);
      return (
        bytes: canonicalBytesMaterializationOrderPreimageV1(typed),
        digest: digestMaterializationOrderPreimageV1(typed),
      );
    case 'MaterializationCoveragePreimageV1':
      final typed = decodeMaterializationCoveragePreimageV1(value);
      return (
        bytes: canonicalBytesMaterializationCoveragePreimageV1(typed),
        digest: digestMaterializationCoveragePreimageV1(typed),
      );
    case 'MaterializationManifestPreimageV1':
      final typed = decodeMaterializationManifestPreimageV1(value);
      return (
        bytes: canonicalBytesMaterializationManifestPreimageV1(typed),
        digest: digestMaterializationManifestPreimageV1(typed),
      );
    case 'MaterializationBeginHeaderPreimageV1':
      final typed = decodeMaterializationBeginHeaderPreimageV1(value);
      return (
        bytes: canonicalBytesMaterializationBeginHeaderPreimageV1(typed),
        digest: digestMaterializationBeginHeaderPreimageV1(typed),
      );
    case 'MaterializationReceiptPreimageV1':
      final typed = decodeMaterializationReceiptPreimageV1(value);
      return (
        bytes: canonicalBytesMaterializationReceiptPreimageV1(typed),
        digest: digestMaterializationReceiptPreimageV1(typed),
      );
    case 'GapRepairIntentPreimageV1':
      final typed = decodeGapRepairIntentPreimageV1(value);
      return (
        bytes: canonicalBytesGapRepairIntentPreimageV1(typed),
        digest: digestGapRepairIntentPreimageV1(typed),
      );
    default:
      fail('missing typed helper for $typeId');
  }
}

void main() {
  final goldenFile = File.fromUri(
    Platform.script.resolve('fixtures/jcs-goldens.json'),
  );
  final fixture = (jsonDecode(goldenFile.readAsStringSync()) as Map)
      .cast<String, Object?>();
  expect(
    fixture['canonicalizationProfile'] == 'RFC8785-IJSON-SAFE-INTEGER-V1',
    'canonicalization profile',
  );
  final references = (fixture['referenceCases'] as List)
      .cast<Map<String, Object?>>();
  for (final reference in references) {
    final bytes = <int>[];
    final canonicalHex = reference['canonicalUtf8Hex']! as String;
    for (var index = 0; index < canonicalHex.length; index += 2) {
      bytes.add(int.parse(canonicalHex.substring(index, index + 2), radix: 16));
    }
    expect(
      sha256.convert(bytes).toString() == reference['sha256'],
      '${reference['id']} reference digest',
    );
  }
  final cases = (fixture['cases'] as List).cast<Map<String, Object?>>();
  for (final golden in cases) {
    final result = evaluate(golden['typeId']! as String, golden['value']);
    expect(
      hex(result.bytes) == golden['canonicalUtf8Hex'],
      '${golden['id']} bytes',
    );
    expect(result.digest == golden['sha256'], '${golden['id']} digest');
    expect(
      RegExp(r'^[0-9a-f]{64}$').hasMatch(result.digest),
      '${golden['id']} format',
    );
  }

  final probe = cases.first;
  final probeValue = (probe['value']! as Map).cast<String, Object?>();
  expect(
    probeValue['negativeZero'] == 0,
    'Dart integer negative zero canonicalizes as zero',
  );
  expect(
    (probe['canonicalUtf8Hex']! as String).contains('c3a9') &&
        (probe['canonicalUtf8Hex']! as String).contains('65cc81'),
    'NFC and NFD bytes remain distinct',
  );

  final operation = cases.firstWhere(
    (entry) => entry['id'] == 'operation-fingerprint',
  );
  final valid = cloneMap(operation['value']);
  void digestRaw(Object? value) {
    final typed = decodeOperationFingerprintPreimageV1(value);
    digestOperationFingerprintPreimageV1(typed);
  }

  for (final jsonNumber in ['1.0', '1e0']) {
    expect(
      evaluate('OperationFingerprintPreimageV1', {
            ...valid,
            'sequence': jsonDecode(jsonNumber),
          }).digest ==
          operation['sha256'],
      '$jsonNumber integral JSON number parity',
    );
  }

  final missing = cloneMap(valid)..remove('operationCode');
  expectThrows(() => digestRaw(missing), 'missing field');
  expectThrows(() => digestRaw({...valid, 'extra': true}), 'extra field');
  expectThrows(() => digestRaw({...valid, 'sequence': '1'}), 'wrong type');
  expectThrows(
    () => digestRaw({...valid, 'digestDomain': 'ccpocket.wrong.v1'}),
    'wrong domain',
  );
  expectThrows(
    () => digestRaw({...valid, 'payloadDigest': ''.padRight(64, 'A')}),
    'uppercase digest',
  );
  expectThrows(
    () => digestRaw({...valid, 'payloadDigest': ''.padRight(63, 'a')}),
    'short digest',
  );
  for (final number in <num>[
    9007199254740992,
    -9007199254740992,
    1.5,
    double.parse('9007199254740992'),
    double.parse('-9007199254740992'),
    double.nan,
    double.infinity,
    double.negativeInfinity,
  ]) {
    expectThrows(
      () => digestRaw({...valid, 'sequence': number}),
      'invalid number $number',
    );
  }
  final source = cloneMap(valid['source']);
  source['bridgeInstanceId'] = String.fromCharCode(0xd800);
  expectThrows(() => digestRaw({...valid, 'source': source}), 'lone surrogate');
  expectThrows(
    () => digestRaw({...valid, String.fromCharCode(0xdc00): true}),
    'lone surrogate key',
  );

  final tampered = {...valid, 'payloadDigest': ''.padRight(64, 'c')};
  expect(
    evaluate('OperationFingerprintPreimageV1', tampered).digest !=
        operation['sha256'],
    'valid tamper changes digest',
  );

  final manifest = cases.firstWhere(
    (entry) => entry['id'] == 'materialization-manifest',
  );
  final typedManifest = decodeMaterializationManifestPreimageV1(
    manifest['value'],
  );
  typedManifest.orderedPageDigests[0] = ''.padRight(64, 'A');
  expectThrows(
    () => digestMaterializationManifestPreimageV1(typedManifest),
    'typed helper revalidates mutable nested digest values',
  );

  final order = cases.firstWhere(
    (entry) => entry['id'] == 'materialization-order',
  );
  final atNodeLimit = cloneMap(order['value']);
  atNodeLimit['orderedTimelineIds'] = List<String>.generate(
    99993,
    (index) => '$index',
    growable: true,
  );
  final typedAtNodeLimit = decodeMaterializationOrderPreimageV1(atNodeLimit);
  expect(
    RegExp(r'^[0-9a-f]{64}$')
        .hasMatch(digestMaterializationOrderPreimageV1(typedAtNodeLimit)),
    'canonical node budget boundary',
  );
  (atNodeLimit['orderedTimelineIds']! as List<String>).add('overflow');
  final typedOverNodeLimit = decodeMaterializationOrderPreimageV1(atNodeLimit);
  expectThrows(
    () => digestMaterializationOrderPreimageV1(typedOverNodeLimit),
    'canonical node budget overflow',
  );

  stdout.writeln(
    'generated Dart canonical-byte/digest tests: ${cases.length} goldens PASS',
  );
}
