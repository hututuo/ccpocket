import 'dart:io';

import 'contract.dart';

Never fail(String message) => throw StateError(message);

void expect(bool condition, String message) {
  if (!condition) fail(message);
}

void expectUnsupported(void Function() operation, String message) {
  try {
    operation();
  } on UnsupportedError {
    return;
  }
  fail('expected UnsupportedError: $message');
}

void main() {
  final record = pvmc1MachineRecords.first;
  final edge = pvmc1MachineEdgeAuthorities.first;
  final coordinate = edge.coordinate.toJson();
  final machineId = coordinate['machineId']! as String;
  final from = coordinate['from']! as String;
  final to = coordinate['to']! as String;
  expect(isAllowedPvmc1MachineEdge(machineId, from, to), 'initial edge lookup');

  expectUnsupported(
    () => pvmc1MachineRecords.add(record),
    'top-level machine authority',
  );
  expectUnsupported(() => record.states[0] = 'MUTATED', 'nested states');
  expectUnsupported(
    () => record.allowedEdges.add(record.allowedEdges.first),
    'nested allowed edges',
  );
  final replica = pvmc1MachineRecords
      .firstWhere((candidate) => candidate.replicaWriterBindings.isNotEmpty)
      .replicaWriterBindings
      .first;
  expectUnsupported(
    () => replica.storageBindings.add(replica.storageBindings.first),
    'nested replica storage bindings',
  );
  expectUnsupported(
    () => replica.routeBindings.add(replica.routeBindings.first),
    'nested replica route bindings',
  );
  expectUnsupported(
    () => edge.guardRefs.add(edge.guardRefs.first),
    'nested edge guards',
  );
  expectUnsupported(
    () => edge.negativeVectorIds.add(edge.negativeVectorIds.first),
    'nested negative vector IDs',
  );
  expectUnsupported(
    () => pvmc1TransactionManifestIds.add('tx.mutated'),
    'transaction manifest IDs',
  );
  expect(
    isAllowedPvmc1MachineEdge(machineId, from, to),
    'stable helper lookup',
  );
  stdout.writeln('generated Dart B2 deep immutability: PASS');
}
