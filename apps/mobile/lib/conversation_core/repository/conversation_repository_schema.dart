part of 'conversation_repository.dart';

// Guard counters deliberately carry independent sentinels.  A damaged usage
// row that edits both primary counters to zero cannot look self-consistent
// without also reconstructing these out-of-band offsets.
const _usageGuardEntryOffset = 1000000000;
const _usageGuardByteOffset = 1000000000000;

class _SchemaColumn {
  const _SchemaColumn(
    this.name,
    this.type,
    this.notNull,
    this.primaryKey, {
    this.defaultValue,
  });

  final String name;
  final String type;
  final int notNull;
  final int primaryKey;
  final String? defaultValue;
  int get hidden => 0;
}

class _SchemaIndex {
  const _SchemaIndex(this.name, this.table, this.unique, this.columns);

  final String name;
  final String table;
  final int unique;
  final List<String> columns;
  List<String> get collations =>
      List<String>.filled(columns.length, 'BINARY', growable: false);
  List<int> get descending =>
      List<int>.filled(columns.length, 0, growable: false);
}

class _SchemaForeignKeyGroup {
  const _SchemaForeignKeyGroup(
    this.table,
    this.from,
    this.to, {
    this.onDelete = 'NO ACTION',
  });

  final String table;
  final List<String> from;
  final List<String> to;
  final String onDelete;
  String get onUpdate => 'NO ACTION';
  String get match => 'NONE';
}

// Retained as a column-level description for compatibility with the original
// schema table.  Attestation uses [_schemaForeignKeyGroups] below so that the
// SQLite `id/seq` grouping is checked as one composite constraint.
class _SchemaForeignKey {
  const _SchemaForeignKey(
    this.table,
    this.from,
    this.to, {
    this.onDelete = 'NO ACTION',
  });

  final String table;
  final String from;
  final String to;
  final String onDelete;
  String get onUpdate => 'NO ACTION';
  String get match => 'NONE';
}

// Keep the constructor name private to this library.  The grouped shape is
// intentional: four independent single-column foreign keys are not
// equivalent to one bijective composite reference.
const _threadStateForeignKey = _SchemaForeignKeyGroup(
  'thread_state',
  <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
  ],
  <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
  ],
  onDelete: 'CASCADE',
);

const _stagedMaterializationForeignKey = _SchemaForeignKeyGroup(
  'staged_materialization',
  <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'source_epoch',
    'provider_instance_epoch',
    'materialization_id',
  ],
  <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'source_epoch',
    'provider_instance_epoch',
    'materialization_id',
  ],
  onDelete: 'CASCADE',
);

const _threadStateBindingChecks = <String>[
  "state_kind IN ('canonical', 'projection_only')",
  "(state_kind = 'canonical' AND current_envelope_id IS NOT NULL AND current_envelope_digest IS NOT NULL) OR (state_kind = 'projection_only' AND current_envelope_id IS NULL AND current_envelope_digest IS NULL)",
  '(last_good_revision = -1 AND last_good_connection_epoch IS NULL AND last_good_source_epoch IS NULL AND last_good_provider_instance_epoch IS NULL AND last_good_runtime_authority_generation IS NULL AND last_good_envelope_id IS NULL AND last_good_envelope_digest IS NULL) OR (last_good_revision >= 0 AND last_good_connection_epoch IS NOT NULL AND last_good_source_epoch IS NOT NULL AND last_good_provider_instance_epoch IS NOT NULL AND last_good_runtime_authority_generation IS NOT NULL AND last_good_envelope_id IS NOT NULL AND last_good_envelope_digest IS NOT NULL)',
];

const _schemaChecks = <String, List<String>>{
  'thread_state': _threadStateBindingChecks,
  'operation_projection': <String>["gc_eligible IN (0, 1)"],
  'queue_entry_projection': <String>["gc_eligible IN (0, 1)"],
  'interaction_projection': <String>["gc_eligible IN (0, 1)"],
  'projection_inbox': <String>[
    "state IN ('pending', 'applied', 'stale')",
    "gc_eligible IN (0, 1)",
    "(state = 'pending' AND gc_eligible = 0) OR state = 'applied' OR (state = 'stale' AND gc_eligible = 1)",
  ],
  'publication_outbox': <String>[
    "phase IN ('applied', 'published')",
    "notification_state IN ('pending', 'delivering', 'notified')",
    "(phase = 'applied' AND notification_state = 'pending') OR (phase = 'published' AND notification_state IN ('pending', 'delivering', 'notified'))",
    "(notification_state = 'delivering' AND delivery_token IS NOT NULL AND delivery_claimed_at IS NOT NULL) OR (notification_state IN ('pending', 'notified') AND delivery_token IS NULL AND delivery_claimed_at IS NULL)",
  ],
};

const _usageTables = <String>[
  'thread_state',
  'canonical_item',
  'typed_gap',
  'committed_envelope',
  'retired_epoch',
  'staged_materialization',
  'staged_materialization_page',
  'operation_projection',
  'queue_entry_projection',
  'interaction_projection',
  'projection_head',
  'projection_inbox',
  'publication_outbox',
];

const _schemaTables = <String>[
  'replica_metadata',
  'replica_usage',
  'replica_usage_audit',
  'writer_lease',
  'thread_state',
  'canonical_item',
  'typed_gap',
  'committed_envelope',
  'retired_epoch',
  'staged_materialization',
  'staged_materialization_page',
  'operation_projection',
  'queue_entry_projection',
  'interaction_projection',
  'projection_head',
  'projection_inbox',
  'publication_outbox',
];

const _schemaColumns = <String, List<_SchemaColumn>>{
  'replica_metadata': <_SchemaColumn>[
    _SchemaColumn('schema_identity', 'TEXT', 1, 1),
    _SchemaColumn('schema_version', 'INTEGER', 1, 0),
  ],
  'replica_usage': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('entry_count', 'INTEGER', 1, 0),
    _SchemaColumn('byte_count', 'INTEGER', 1, 0),
    _SchemaColumn('guard_entry_count', 'INTEGER', 1, 0),
    _SchemaColumn('guard_byte_count', 'INTEGER', 1, 0),
  ],
  'replica_usage_audit': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('entry_count', 'INTEGER', 1, 0),
    _SchemaColumn('byte_count', 'INTEGER', 1, 0),
  ],
  'writer_lease': <_SchemaColumn>[
    _SchemaColumn('lease_name', 'TEXT', 1, 1),
    _SchemaColumn('owner_token', 'TEXT', 1, 0),
    _SchemaColumn('owner_pid', 'INTEGER', 1, 0),
    _SchemaColumn('owner_boot_id', 'TEXT', 1, 0),
    _SchemaColumn('owner_process_instance_id', 'TEXT', 1, 0),
    _SchemaColumn('acquired_at', 'INTEGER', 1, 0),
    _SchemaColumn('heartbeat_at', 'INTEGER', 1, 0),
  ],
  'thread_state': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1, defaultValue: null),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('state_kind', 'TEXT', 1, 0),
    _SchemaColumn('connection_epoch', 'TEXT', 1, 0),
    _SchemaColumn('source_epoch', 'TEXT', 1, 0),
    _SchemaColumn('provider_instance_epoch', 'TEXT', 1, 0),
    _SchemaColumn('runtime_authority_generation', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
    _SchemaColumn('current_envelope_id', 'TEXT', 0, 0),
    _SchemaColumn('current_envelope_digest', 'TEXT', 0, 0),
    _SchemaColumn('last_good_revision', 'INTEGER', 1, 0),
    _SchemaColumn('last_good_connection_epoch', 'TEXT', 0, 0),
    _SchemaColumn('last_good_source_epoch', 'TEXT', 0, 0),
    _SchemaColumn('last_good_provider_instance_epoch', 'TEXT', 0, 0),
    _SchemaColumn('last_good_runtime_authority_generation', 'INTEGER', 0, 0),
    _SchemaColumn('last_good_envelope_id', 'TEXT', 0, 0),
    _SchemaColumn('last_good_envelope_digest', 'TEXT', 0, 0),
    _SchemaColumn('structural_coverage', 'TEXT', 1, 0),
    _SchemaColumn('payload_coverage', 'TEXT', 1, 0),
    _SchemaColumn('lower_ordinal', 'INTEGER', 0, 0),
    _SchemaColumn('upper_ordinal', 'INTEGER', 0, 0),
    _SchemaColumn('health', 'TEXT', 1, 0),
    _SchemaColumn('problem_code', 'TEXT', 0, 0),
    _SchemaColumn('updated_at', 'INTEGER', 1, 0),
  ],
  'canonical_item': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('provider_turn_id', 'TEXT', 1, 5),
    _SchemaColumn('provider_item_id', 'TEXT', 1, 6),
    _SchemaColumn('turn_ordinal', 'INTEGER', 1, 0),
    _SchemaColumn('item_ordinal', 'INTEGER', 1, 0),
    _SchemaColumn('timeline_ordinal', 'INTEGER', 1, 0),
    _SchemaColumn('kind', 'TEXT', 1, 0),
    _SchemaColumn('normalized_payload_json', 'TEXT', 1, 0),
    _SchemaColumn('presentation_projection_json', 'TEXT', 1, 0),
    _SchemaColumn('item_digest', 'TEXT', 1, 0),
    _SchemaColumn('byte_size', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
  ],
  'typed_gap': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('gap_id', 'TEXT', 1, 5),
    _SchemaColumn('kind', 'TEXT', 1, 0),
    _SchemaColumn('start_ordinal', 'INTEGER', 1, 0),
    _SchemaColumn('end_ordinal', 'INTEGER', 0, 0),
    _SchemaColumn('details_json', 'TEXT', 1, 0),
    _SchemaColumn('gap_digest', 'TEXT', 1, 0),
    _SchemaColumn('is_active', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
  ],
  'committed_envelope': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('source_epoch', 'TEXT', 1, 5),
    _SchemaColumn('provider_instance_epoch', 'TEXT', 1, 6),
    _SchemaColumn('envelope_id', 'TEXT', 1, 7),
    _SchemaColumn('envelope_digest', 'TEXT', 1, 0),
    _SchemaColumn('connection_epoch', 'TEXT', 1, 0),
    _SchemaColumn('runtime_authority_generation', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
    _SchemaColumn('page_index', 'INTEGER', 1, 0),
    _SchemaColumn('page_count', 'INTEGER', 1, 0),
    _SchemaColumn('final_page_digest', 'TEXT', 0, 0),
    _SchemaColumn('page_manifest_digest', 'TEXT', 1, 0),
    _SchemaColumn('item_count', 'INTEGER', 1, 0),
    _SchemaColumn('gap_count', 'INTEGER', 1, 0),
    _SchemaColumn('island_count', 'INTEGER', 1, 0),
    _SchemaColumn('structural_coverage', 'TEXT', 1, 0),
    _SchemaColumn('payload_coverage', 'TEXT', 1, 0),
    _SchemaColumn('lower_ordinal', 'INTEGER', 0, 0),
    _SchemaColumn('upper_ordinal', 'INTEGER', 0, 0),
    _SchemaColumn('order_digest', 'TEXT', 1, 0),
    _SchemaColumn('last_good_disposition', 'TEXT', 1, 0),
    _SchemaColumn('provider_read_evidence_digest', 'TEXT', 1, 0),
    _SchemaColumn('empty_proof_digest', 'TEXT', 0, 0),
    _SchemaColumn('committed_at', 'INTEGER', 1, 0),
  ],
  'retired_epoch': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('epoch_kind', 'TEXT', 1, 4),
    _SchemaColumn('epoch_value', 'TEXT', 1, 5),
    _SchemaColumn('retired_at', 'INTEGER', 1, 0),
  ],
  'staged_materialization': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('source_epoch', 'TEXT', 1, 5),
    _SchemaColumn('provider_instance_epoch', 'TEXT', 1, 6),
    _SchemaColumn('materialization_id', 'TEXT', 1, 7),
    _SchemaColumn('connection_epoch', 'TEXT', 1, 0),
    _SchemaColumn('runtime_authority_generation', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
    _SchemaColumn('structural_coverage', 'TEXT', 1, 0),
    _SchemaColumn('payload_coverage', 'TEXT', 1, 0),
    _SchemaColumn('lower_ordinal', 'INTEGER', 0, 0),
    _SchemaColumn('upper_ordinal', 'INTEGER', 0, 0),
    _SchemaColumn('health', 'TEXT', 1, 0),
    _SchemaColumn('problem_code', 'TEXT', 0, 0),
    _SchemaColumn('is_snapshot', 'INTEGER', 1, 0),
    _SchemaColumn('page_count', 'INTEGER', 1, 0),
    _SchemaColumn('total_item_count', 'INTEGER', 1, 0),
    _SchemaColumn('provider_read_evidence_digest', 'TEXT', 1, 0),
    _SchemaColumn('provider_read_method', 'TEXT', 1, 0),
    _SchemaColumn('provider_build_id', 'TEXT', 1, 0),
    _SchemaColumn('provider_result_kind', 'TEXT', 1, 0),
    _SchemaColumn('provider_result_digest', 'TEXT', 1, 0),
    _SchemaColumn('provider_coverage_digest', 'TEXT', 1, 0),
    _SchemaColumn('request_id', 'TEXT', 1, 0),
    _SchemaColumn('read_kind', 'TEXT', 1, 0),
    _SchemaColumn('empty_proof_kind', 'TEXT', 0, 0),
    _SchemaColumn('empty_provider_revision', 'TEXT', 0, 0),
    _SchemaColumn('empty_observation_digest', 'TEXT', 0, 0),
    _SchemaColumn('empty_proof_digest', 'TEXT', 0, 0),
    _SchemaColumn('begin_digest', 'TEXT', 1, 0),
    _SchemaColumn('begun_at', 'INTEGER', 1, 0),
  ],
  'staged_materialization_page': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('source_epoch', 'TEXT', 1, 5),
    _SchemaColumn('provider_instance_epoch', 'TEXT', 1, 6),
    _SchemaColumn('materialization_id', 'TEXT', 1, 7),
    _SchemaColumn('page_index', 'INTEGER', 1, 8),
    _SchemaColumn('connection_epoch', 'TEXT', 1, 0),
    _SchemaColumn('runtime_authority_generation', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
    _SchemaColumn('page_count', 'INTEGER', 1, 0),
    _SchemaColumn('previous_page_digest', 'TEXT', 0, 0),
    _SchemaColumn('page_digest', 'TEXT', 1, 0),
    _SchemaColumn('body_json', 'TEXT', 1, 0),
    _SchemaColumn('body_byte_size', 'INTEGER', 1, 0),
    _SchemaColumn('staged_at', 'INTEGER', 1, 0),
  ],
  'operation_projection': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('operation_id', 'TEXT', 1, 5),
    _SchemaColumn('revision', 'INTEGER', 1, 0),
    _SchemaColumn('state', 'TEXT', 1, 0),
    _SchemaColumn('is_terminal', 'INTEGER', 1, 0),
    _SchemaColumn('value_json', 'TEXT', 1, 0),
    _SchemaColumn('value_digest', 'TEXT', 1, 0),
    _SchemaColumn('is_active', 'INTEGER', 1, 0),
    _SchemaColumn('gc_eligible', 'INTEGER', 1, 0),
    _SchemaColumn('snapshot_marker', 'TEXT', 1, 0),
    _SchemaColumn('source_projection_id', 'TEXT', 1, 0),
  ],
  'queue_entry_projection': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('queue_entry_id', 'TEXT', 1, 5),
    _SchemaColumn('operation_id', 'TEXT', 0, 0),
    _SchemaColumn('revision', 'INTEGER', 1, 0),
    _SchemaColumn('position', 'INTEGER', 1, 0),
    _SchemaColumn('state', 'TEXT', 1, 0),
    _SchemaColumn('value_json', 'TEXT', 1, 0),
    _SchemaColumn('value_digest', 'TEXT', 1, 0),
    _SchemaColumn('is_active', 'INTEGER', 1, 0),
    _SchemaColumn('gc_eligible', 'INTEGER', 1, 0),
    _SchemaColumn('snapshot_marker', 'TEXT', 1, 0),
    _SchemaColumn('source_projection_id', 'TEXT', 1, 0),
  ],
  'interaction_projection': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('interaction_id', 'TEXT', 1, 5),
    _SchemaColumn('revision', 'INTEGER', 1, 0),
    _SchemaColumn('kind', 'TEXT', 1, 0),
    _SchemaColumn('state', 'TEXT', 1, 0),
    _SchemaColumn('claim_actor_id', 'TEXT', 0, 0),
    _SchemaColumn('claim_expires_at', 'INTEGER', 0, 0),
    _SchemaColumn('value_json', 'TEXT', 1, 0),
    _SchemaColumn('value_digest', 'TEXT', 1, 0),
    _SchemaColumn('is_active', 'INTEGER', 1, 0),
    _SchemaColumn('gc_eligible', 'INTEGER', 1, 0),
    _SchemaColumn('snapshot_marker', 'TEXT', 1, 0),
    _SchemaColumn('source_projection_id', 'TEXT', 1, 0),
  ],
  'projection_head': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('connection_epoch', 'TEXT', 1, 0),
    _SchemaColumn('source_epoch', 'TEXT', 1, 0),
    _SchemaColumn('provider_instance_epoch', 'TEXT', 1, 0),
    _SchemaColumn('runtime_authority_generation', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
    _SchemaColumn('projection_id', 'TEXT', 1, 0),
    _SchemaColumn('projection_digest', 'TEXT', 1, 0),
    _SchemaColumn('operation_snapshot_complete', 'INTEGER', 1, 0),
    _SchemaColumn('queue_snapshot_complete', 'INTEGER', 1, 0),
    _SchemaColumn('interaction_snapshot_complete', 'INTEGER', 1, 0),
    _SchemaColumn('operation_snapshot_marker', 'TEXT', 1, 0),
    _SchemaColumn('queue_snapshot_marker', 'TEXT', 1, 0),
    _SchemaColumn('interaction_snapshot_marker', 'TEXT', 1, 0),
    _SchemaColumn('updated_at', 'INTEGER', 1, 0),
  ],
  'projection_inbox': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('projection_id', 'TEXT', 1, 5),
    _SchemaColumn('connection_epoch', 'TEXT', 1, 0),
    _SchemaColumn('source_epoch', 'TEXT', 1, 0),
    _SchemaColumn('provider_instance_epoch', 'TEXT', 1, 0),
    _SchemaColumn('runtime_authority_generation', 'INTEGER', 1, 0),
    _SchemaColumn('source_revision', 'INTEGER', 1, 0),
    _SchemaColumn('projection_digest', 'TEXT', 1, 0),
    _SchemaColumn('payload_json', 'TEXT', 1, 0),
    _SchemaColumn('state', 'TEXT', 1, 0),
    _SchemaColumn('gc_eligible', 'INTEGER', 1, 0),
    _SchemaColumn('admitted_at', 'INTEGER', 1, 0),
  ],
  'publication_outbox': <_SchemaColumn>[
    _SchemaColumn('bridge_identity_id', 'TEXT', 1, 1),
    _SchemaColumn('bridge_instance_id', 'TEXT', 1, 2),
    _SchemaColumn('codex_source_id', 'TEXT', 1, 3),
    _SchemaColumn('provider_thread_id', 'TEXT', 1, 4),
    _SchemaColumn('source_epoch', 'TEXT', 1, 5),
    _SchemaColumn('provider_instance_epoch', 'TEXT', 1, 6),
    _SchemaColumn('domain', 'TEXT', 1, 7),
    _SchemaColumn('operation_id', 'TEXT', 1, 8),
    _SchemaColumn('event_id', 'TEXT', 1, 0),
    _SchemaColumn('applied_digest', 'TEXT', 1, 0),
    _SchemaColumn('phase', 'TEXT', 1, 0),
    _SchemaColumn('notification_state', 'TEXT', 1, 0),
    _SchemaColumn('delivery_token', 'TEXT', 0, 0),
    _SchemaColumn('delivery_claimed_at', 'INTEGER', 0, 0),
    _SchemaColumn('applied_at', 'INTEGER', 1, 0),
    _SchemaColumn('published_at', 'INTEGER', 0, 0),
  ],
};

const _schemaIndexes = <_SchemaIndex>[
  _SchemaIndex('canonical_item_window_idx', 'canonical_item', 0, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'timeline_ordinal',
  ]),
  _SchemaIndex('canonical_item_turn_order_idx', 'canonical_item', 1, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'provider_turn_id',
    'item_ordinal',
  ]),
  _SchemaIndex(
    'canonical_item_timeline_unique_idx',
    'canonical_item',
    1,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'timeline_ordinal',
    ],
  ),
  _SchemaIndex('typed_gap_order_idx', 'typed_gap', 0, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'start_ordinal',
    'gap_id',
  ]),
  _SchemaIndex('typed_gap_gc_idx', 'typed_gap', 0, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'is_active',
    'gap_id',
  ]),
  _SchemaIndex(
    'committed_envelope_revision_idx',
    'committed_envelope',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'source_revision',
    ],
  ),
  _SchemaIndex('committed_envelope_gc_idx', 'committed_envelope', 0, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'committed_at',
    'envelope_id',
  ]),
  _SchemaIndex(
    'staging_page_order_idx',
    'staged_materialization_page',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'source_epoch',
      'provider_instance_epoch',
      'materialization_id',
      'page_index',
    ],
  ),
  _SchemaIndex(
    'staged_materialization_gc_idx',
    'staged_materialization',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'begun_at',
      'materialization_id',
    ],
  ),
  _SchemaIndex('projection_inbox_state_idx', 'projection_inbox', 0, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'state',
    'admitted_at',
  ]),
  _SchemaIndex('projection_inbox_gc_idx', 'projection_inbox', 0, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'gc_eligible',
    'state',
    'admitted_at',
    'projection_id',
  ]),
  _SchemaIndex('projection_inbox_recovery_idx', 'projection_inbox', 0, <String>[
    'state',
    'admitted_at',
    'projection_id',
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
  ]),
  _SchemaIndex('queue_entry_order_idx', 'queue_entry_projection', 0, <String>[
    'bridge_identity_id',
    'bridge_instance_id',
    'codex_source_id',
    'provider_thread_id',
    'position',
    'queue_entry_id',
  ]),
  _SchemaIndex(
    'operation_projection_gc_idx',
    'operation_projection',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'is_active',
      'operation_id',
    ],
  ),
  _SchemaIndex(
    'queue_entry_projection_gc_idx',
    'queue_entry_projection',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'is_active',
      'queue_entry_id',
    ],
  ),
  _SchemaIndex(
    'interaction_projection_gc_idx',
    'interaction_projection',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'is_active',
      'interaction_id',
    ],
  ),
  _SchemaIndex(
    'operation_projection_snapshot_gc_idx',
    'operation_projection',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'is_active',
      'gc_eligible',
      'snapshot_marker',
      'operation_id',
    ],
  ),
  _SchemaIndex(
    'queue_entry_projection_snapshot_gc_idx',
    'queue_entry_projection',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'is_active',
      'gc_eligible',
      'snapshot_marker',
      'queue_entry_id',
    ],
  ),
  _SchemaIndex(
    'interaction_projection_snapshot_gc_idx',
    'interaction_projection',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'is_active',
      'gc_eligible',
      'snapshot_marker',
      'interaction_id',
    ],
  ),
  _SchemaIndex(
    'publication_outbox_phase_idx',
    'publication_outbox',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'phase',
      'notification_state',
      'published_at',
      'operation_id',
    ],
  ),
  _SchemaIndex(
    'publication_outbox_recovery_idx',
    'publication_outbox',
    0,
    <String>['phase', 'notification_state', 'published_at', 'event_id'],
  ),
  _SchemaIndex(
    'publication_outbox_provenance_idx',
    'publication_outbox',
    0,
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'domain',
      'operation_id',
      'notification_state',
    ],
  ),
];

const _schemaInlineUniqueConstraints = <String, List<List<String>>>{
  'canonical_item': <List<String>>[
    <String>[
      'bridge_identity_id',
      'bridge_instance_id',
      'codex_source_id',
      'provider_thread_id',
      'timeline_ordinal',
    ],
  ],
  'publication_outbox': <List<String>>[
    <String>['event_id'],
  ],
};

const _schemaForeignKeys = <String, List<_SchemaForeignKey>>{
  'canonical_item': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'thread_state',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
  ],
  'typed_gap': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'thread_state',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
  ],
  'committed_envelope': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'thread_state',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
  ],
  'staged_materialization_page': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'staged_materialization',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'staged_materialization',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'staged_materialization',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'staged_materialization',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'staged_materialization',
      'source_epoch',
      'source_epoch',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'staged_materialization',
      'provider_instance_epoch',
      'provider_instance_epoch',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'staged_materialization',
      'materialization_id',
      'materialization_id',
      onDelete: 'CASCADE',
    ),
  ],
  'operation_projection': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'thread_state',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
  ],
  'queue_entry_projection': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'thread_state',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
  ],
  'interaction_projection': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'thread_state',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
  ],
  'projection_head': <_SchemaForeignKey>[
    _SchemaForeignKey(
      'thread_state',
      'bridge_identity_id',
      'bridge_identity_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'bridge_instance_id',
      'bridge_instance_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'codex_source_id',
      'codex_source_id',
      onDelete: 'CASCADE',
    ),
    _SchemaForeignKey(
      'thread_state',
      'provider_thread_id',
      'provider_thread_id',
      onDelete: 'CASCADE',
    ),
  ],
};

const _schemaForeignKeyGroups = <String, List<_SchemaForeignKeyGroup>>{
  'canonical_item': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
  'typed_gap': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
  'committed_envelope': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
  'staged_materialization_page': <_SchemaForeignKeyGroup>[
    _stagedMaterializationForeignKey,
  ],
  'operation_projection': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
  'queue_entry_projection': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
  'interaction_projection': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
  'projection_head': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
  'publication_outbox': <_SchemaForeignKeyGroup>[_threadStateForeignKey],
};

Future<void> _createSchema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE replica_metadata (
      schema_identity TEXT PRIMARY KEY,
      schema_version INTEGER NOT NULL
    ) STRICT
  ''');
  await db.insert('replica_metadata', const <String, Object?>{
    'schema_identity': ConversationRepository._schemaIdentity,
    'schema_version': ConversationRepository._schemaVersion,
  });
  await db.execute('''
    CREATE TABLE replica_usage (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      entry_count INTEGER NOT NULL,
      byte_count INTEGER NOT NULL,
      guard_entry_count INTEGER NOT NULL,
      guard_byte_count INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE replica_usage_audit (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      entry_count INTEGER NOT NULL,
      byte_count INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE writer_lease (
      lease_name TEXT PRIMARY KEY,
      owner_token TEXT NOT NULL,
      owner_pid INTEGER NOT NULL,
      owner_boot_id TEXT NOT NULL,
      owner_process_instance_id TEXT NOT NULL,
      acquired_at INTEGER NOT NULL,
      heartbeat_at INTEGER NOT NULL
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE thread_state (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      state_kind TEXT NOT NULL,
      connection_epoch TEXT NOT NULL,
      source_epoch TEXT NOT NULL,
      provider_instance_epoch TEXT NOT NULL,
      runtime_authority_generation INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      current_envelope_id TEXT,
      current_envelope_digest TEXT,
      last_good_revision INTEGER NOT NULL,
      last_good_connection_epoch TEXT,
      last_good_source_epoch TEXT,
      last_good_provider_instance_epoch TEXT,
      last_good_runtime_authority_generation INTEGER,
      last_good_envelope_id TEXT,
      last_good_envelope_digest TEXT,
      structural_coverage TEXT NOT NULL,
      payload_coverage TEXT NOT NULL,
      lower_ordinal INTEGER,
      upper_ordinal INTEGER,
      health TEXT NOT NULL,
      problem_code TEXT,
      updated_at INTEGER NOT NULL,
      CHECK (state_kind IN ('canonical', 'projection_only')),
      CHECK (
        (state_kind = 'canonical' AND
          current_envelope_id IS NOT NULL AND current_envelope_digest IS NOT NULL)
        OR
        (state_kind = 'projection_only' AND
          current_envelope_id IS NULL AND current_envelope_digest IS NULL)
      ),
      CHECK (
        (last_good_revision = -1 AND
          last_good_connection_epoch IS NULL AND
          last_good_source_epoch IS NULL AND
          last_good_provider_instance_epoch IS NULL AND
          last_good_runtime_authority_generation IS NULL AND
          last_good_envelope_id IS NULL AND
          last_good_envelope_digest IS NULL)
        OR
        (last_good_revision >= 0 AND
          last_good_connection_epoch IS NOT NULL AND
          last_good_source_epoch IS NOT NULL AND
          last_good_provider_instance_epoch IS NOT NULL AND
          last_good_runtime_authority_generation IS NOT NULL AND
          last_good_envelope_id IS NOT NULL AND
          last_good_envelope_digest IS NOT NULL)
      ),
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE canonical_item (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      provider_turn_id TEXT NOT NULL,
      provider_item_id TEXT NOT NULL,
      turn_ordinal INTEGER NOT NULL,
      item_ordinal INTEGER NOT NULL,
      timeline_ordinal INTEGER NOT NULL,
      kind TEXT NOT NULL,
      normalized_payload_json TEXT NOT NULL,
      presentation_projection_json TEXT NOT NULL,
      item_digest TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, provider_turn_id, provider_item_id),
      UNIQUE (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, timeline_ordinal),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE typed_gap (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      gap_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      start_ordinal INTEGER NOT NULL,
      end_ordinal INTEGER,
      details_json TEXT NOT NULL,
      gap_digest TEXT NOT NULL,
      is_active INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, gap_id),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE committed_envelope (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      source_epoch TEXT NOT NULL,
      provider_instance_epoch TEXT NOT NULL,
      envelope_id TEXT NOT NULL,
      envelope_digest TEXT NOT NULL,
      connection_epoch TEXT NOT NULL,
      runtime_authority_generation INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      page_index INTEGER NOT NULL,
      page_count INTEGER NOT NULL,
      final_page_digest TEXT,
      page_manifest_digest TEXT NOT NULL,
      item_count INTEGER NOT NULL,
      gap_count INTEGER NOT NULL,
      island_count INTEGER NOT NULL,
      structural_coverage TEXT NOT NULL,
      payload_coverage TEXT NOT NULL,
      lower_ordinal INTEGER,
      upper_ordinal INTEGER,
      order_digest TEXT NOT NULL,
      last_good_disposition TEXT NOT NULL,
      provider_read_evidence_digest TEXT NOT NULL,
      empty_proof_digest TEXT,
      committed_at INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, source_epoch, provider_instance_epoch, envelope_id),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE retired_epoch (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      epoch_kind TEXT NOT NULL,
      epoch_value TEXT NOT NULL,
      retired_at INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, epoch_kind, epoch_value)
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE staged_materialization (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      source_epoch TEXT NOT NULL,
      provider_instance_epoch TEXT NOT NULL,
      materialization_id TEXT NOT NULL,
      connection_epoch TEXT NOT NULL,
      runtime_authority_generation INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      structural_coverage TEXT NOT NULL,
      payload_coverage TEXT NOT NULL,
      lower_ordinal INTEGER,
      upper_ordinal INTEGER,
      health TEXT NOT NULL,
      problem_code TEXT,
      is_snapshot INTEGER NOT NULL,
      page_count INTEGER NOT NULL,
      total_item_count INTEGER NOT NULL,
      provider_read_evidence_digest TEXT NOT NULL,
      provider_read_method TEXT NOT NULL,
      provider_build_id TEXT NOT NULL,
      provider_result_kind TEXT NOT NULL,
      provider_result_digest TEXT NOT NULL,
      provider_coverage_digest TEXT NOT NULL,
      request_id TEXT NOT NULL,
      read_kind TEXT NOT NULL,
      empty_proof_kind TEXT,
      empty_provider_revision TEXT,
      empty_observation_digest TEXT,
      empty_proof_digest TEXT,
      begin_digest TEXT NOT NULL,
      begun_at INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, source_epoch, provider_instance_epoch, materialization_id)
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE staged_materialization_page (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      source_epoch TEXT NOT NULL,
      provider_instance_epoch TEXT NOT NULL,
      materialization_id TEXT NOT NULL,
      page_index INTEGER NOT NULL,
      connection_epoch TEXT NOT NULL,
      runtime_authority_generation INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      page_count INTEGER NOT NULL,
      previous_page_digest TEXT,
      page_digest TEXT NOT NULL,
      body_json TEXT NOT NULL,
      body_byte_size INTEGER NOT NULL,
      staged_at INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, source_epoch, provider_instance_epoch, materialization_id, page_index),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, source_epoch, provider_instance_epoch, materialization_id)
        REFERENCES staged_materialization (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, source_epoch, provider_instance_epoch, materialization_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE operation_projection (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      operation_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      state TEXT NOT NULL,
      is_terminal INTEGER NOT NULL,
      value_json TEXT NOT NULL,
      value_digest TEXT NOT NULL,
      is_active INTEGER NOT NULL,
      gc_eligible INTEGER NOT NULL,
      snapshot_marker TEXT NOT NULL,
      source_projection_id TEXT NOT NULL,
      CHECK (gc_eligible IN (0, 1)),
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, operation_id),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE queue_entry_projection (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      queue_entry_id TEXT NOT NULL,
      operation_id TEXT,
      revision INTEGER NOT NULL,
      position INTEGER NOT NULL,
      state TEXT NOT NULL,
      value_json TEXT NOT NULL,
      value_digest TEXT NOT NULL,
      is_active INTEGER NOT NULL,
      gc_eligible INTEGER NOT NULL,
      snapshot_marker TEXT NOT NULL,
      source_projection_id TEXT NOT NULL,
      CHECK (gc_eligible IN (0, 1)),
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, queue_entry_id),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE interaction_projection (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      interaction_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      kind TEXT NOT NULL,
      state TEXT NOT NULL,
      claim_actor_id TEXT,
      claim_expires_at INTEGER,
      value_json TEXT NOT NULL,
      value_digest TEXT NOT NULL,
      is_active INTEGER NOT NULL,
      gc_eligible INTEGER NOT NULL,
      snapshot_marker TEXT NOT NULL,
      source_projection_id TEXT NOT NULL,
      CHECK (gc_eligible IN (0, 1)),
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, interaction_id),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE projection_head (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      connection_epoch TEXT NOT NULL,
      source_epoch TEXT NOT NULL,
      provider_instance_epoch TEXT NOT NULL,
      runtime_authority_generation INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      projection_id TEXT NOT NULL,
      projection_digest TEXT NOT NULL,
      operation_snapshot_complete INTEGER NOT NULL,
      queue_snapshot_complete INTEGER NOT NULL,
      interaction_snapshot_complete INTEGER NOT NULL,
      operation_snapshot_marker TEXT NOT NULL,
      queue_snapshot_marker TEXT NOT NULL,
      interaction_snapshot_marker TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE projection_inbox (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      projection_id TEXT NOT NULL,
      connection_epoch TEXT NOT NULL,
      source_epoch TEXT NOT NULL,
      provider_instance_epoch TEXT NOT NULL,
      runtime_authority_generation INTEGER NOT NULL,
      source_revision INTEGER NOT NULL,
      projection_digest TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      state TEXT NOT NULL,
      gc_eligible INTEGER NOT NULL,
      admitted_at INTEGER NOT NULL,
      CHECK (state IN ('pending', 'applied', 'stale')),
      CHECK (gc_eligible IN (0, 1)),
      CHECK (
        (state = 'pending' AND gc_eligible = 0)
        OR state = 'applied'
        OR (state = 'stale' AND gc_eligible = 1)
      ),
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, projection_id)
    ) STRICT
  ''');
  await db.execute('''
    CREATE TABLE publication_outbox (
      bridge_identity_id TEXT NOT NULL,
      bridge_instance_id TEXT NOT NULL,
      codex_source_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      source_epoch TEXT NOT NULL,
      provider_instance_epoch TEXT NOT NULL,
      domain TEXT NOT NULL,
      operation_id TEXT NOT NULL,
      event_id TEXT NOT NULL,
      applied_digest TEXT NOT NULL,
      phase TEXT NOT NULL,
      notification_state TEXT NOT NULL,
      delivery_token TEXT,
      delivery_claimed_at INTEGER,
      applied_at INTEGER NOT NULL,
      published_at INTEGER,
      CHECK (phase IN ('applied', 'published')),
      CHECK (notification_state IN ('pending', 'delivering', 'notified')),
      CHECK (
        (phase = 'applied' AND notification_state = 'pending')
        OR
        (phase = 'published' AND notification_state IN ('pending', 'delivering', 'notified'))
      ),
      CHECK (
        (notification_state = 'delivering' AND
          delivery_token IS NOT NULL AND delivery_claimed_at IS NOT NULL)
        OR
        (notification_state IN ('pending', 'notified') AND
          delivery_token IS NULL AND delivery_claimed_at IS NULL)
      ),
      UNIQUE (event_id),
      PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, source_epoch, provider_instance_epoch, domain, operation_id),
      FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        REFERENCES thread_state (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
        ON DELETE CASCADE
    ) STRICT
  ''');
  await _createUsageTriggers(db);
  for (final index in _schemaIndexes) {
    final unique = index.unique == 1 ? 'UNIQUE ' : '';
    await db.execute(
      'CREATE ${unique}INDEX ${index.name} ON ${index.table} (${index.columns.join(', ')})',
    );
  }
}

String _usageTriggerName(String table, String event) =>
    'replica_usage_${table}_$event';

String _triggerTable(String name) {
  const prefix = 'replica_usage_';
  if (!name.startsWith(prefix)) return '';
  final suffix = name.substring(prefix.length);
  final tables = _usageTables.toList()
    ..sort((left, right) => right.length.compareTo(left.length));
  for (final table in tables) {
    if (suffix.startsWith('${table}_')) return table;
  }
  return '';
}

String _usageKeyValue(String table, String prefix, String column) {
  // retired_epoch is partition-scoped rather than thread-scoped.  The empty
  // bucket keeps its usage accounting O(1) without pretending that a retired
  // epoch belongs to one particular provider thread.
  if (table == 'retired_epoch' && column == 'provider_thread_id') {
    return "''";
  }
  return '$prefix.$column';
}

String _usageKeyValues(String table, String prefix) => <String>[
  _usageKeyValue(table, prefix, 'bridge_identity_id'),
  _usageKeyValue(table, prefix, 'bridge_instance_id'),
  _usageKeyValue(table, prefix, 'codex_source_id'),
  _usageKeyValue(table, prefix, 'provider_thread_id'),
].join(', ');

String _usageByteExpression(String table, String prefix) =>
    _schemaColumns[table]!
        .map(
          (column) =>
              'COALESCE(LENGTH(CAST($prefix.${column.name} AS BLOB)), 0)',
        )
        .join(' + ');

String _usageWhere(String table, String prefix) => <String>[
  'bridge_identity_id = ${_usageKeyValue(table, prefix, 'bridge_identity_id')}',
  'bridge_instance_id = ${_usageKeyValue(table, prefix, 'bridge_instance_id')}',
  'codex_source_id = ${_usageKeyValue(table, prefix, 'codex_source_id')}',
  'provider_thread_id = ${_usageKeyValue(table, prefix, 'provider_thread_id')}',
].join(' AND ');

String _usageTriggerSql(String table, String event) {
  final keyColumns =
      'bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id';
  final name = _usageTriggerName(table, event);
  if (event == 'insert') {
    return '''
CREATE TRIGGER $name AFTER INSERT ON $table BEGIN
  INSERT INTO replica_usage ($keyColumns, entry_count, byte_count, guard_entry_count, guard_byte_count)
  VALUES (${_usageKeyValues(table, 'NEW')}, 1, ${_usageByteExpression(table, 'NEW')}, ${_usageGuardEntryOffset + 1}, $_usageGuardByteOffset + ${_usageByteExpression(table, 'NEW')})
  ON CONFLICT (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
  DO UPDATE SET
    entry_count = entry_count + 1,
    byte_count = byte_count + excluded.byte_count,
    guard_entry_count = guard_entry_count + excluded.guard_entry_count - $_usageGuardEntryOffset,
    guard_byte_count = guard_byte_count + excluded.guard_byte_count - $_usageGuardByteOffset;
  INSERT INTO replica_usage_audit ($keyColumns, entry_count, byte_count)
  VALUES (${_usageKeyValues(table, 'NEW')}, 1, ${_usageByteExpression(table, 'NEW')})
  ON CONFLICT (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
  DO UPDATE SET
    entry_count = entry_count + 1,
    byte_count = byte_count + excluded.byte_count;
END
''';
  }
  if (event == 'delete') {
    return '''
CREATE TRIGGER $name AFTER DELETE ON $table BEGIN
  UPDATE replica_usage
  SET entry_count = entry_count - 1,
      byte_count = byte_count - (${_usageByteExpression(table, 'OLD')}),
      guard_entry_count = guard_entry_count - 1,
      guard_byte_count = guard_byte_count - (${_usageByteExpression(table, 'OLD')})
  WHERE ${_usageWhere(table, 'OLD')};
  DELETE FROM replica_usage
  WHERE ${_usageWhere(table, 'OLD')} AND entry_count <= 0;
  UPDATE replica_usage_audit
  SET entry_count = entry_count - 1,
      byte_count = byte_count - (${_usageByteExpression(table, 'OLD')})
  WHERE ${_usageWhere(table, 'OLD')};
  DELETE FROM replica_usage_audit
  WHERE ${_usageWhere(table, 'OLD')} AND entry_count <= 0;
END
''';
  }
  return '''
CREATE TRIGGER $name AFTER UPDATE ON $table BEGIN
  UPDATE replica_usage
  SET entry_count = entry_count - 1,
      byte_count = byte_count - (${_usageByteExpression(table, 'OLD')}),
      guard_entry_count = guard_entry_count - 1,
      guard_byte_count = guard_byte_count - (${_usageByteExpression(table, 'OLD')})
  WHERE ${_usageWhere(table, 'OLD')};
  DELETE FROM replica_usage
  WHERE ${_usageWhere(table, 'OLD')} AND entry_count <= 0;
  UPDATE replica_usage_audit
  SET entry_count = entry_count - 1,
      byte_count = byte_count - (${_usageByteExpression(table, 'OLD')})
  WHERE ${_usageWhere(table, 'OLD')};
  DELETE FROM replica_usage_audit
  WHERE ${_usageWhere(table, 'OLD')} AND entry_count <= 0;
  INSERT INTO replica_usage ($keyColumns, entry_count, byte_count, guard_entry_count, guard_byte_count)
  VALUES (${_usageKeyValues(table, 'NEW')}, 1, ${_usageByteExpression(table, 'NEW')}, ${_usageGuardEntryOffset + 1}, $_usageGuardByteOffset + ${_usageByteExpression(table, 'NEW')})
  ON CONFLICT (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
  DO UPDATE SET
    entry_count = entry_count + 1,
    byte_count = byte_count + excluded.byte_count,
    guard_entry_count = guard_entry_count + excluded.guard_entry_count - $_usageGuardEntryOffset,
    guard_byte_count = guard_byte_count + excluded.guard_byte_count - $_usageGuardByteOffset;
  INSERT INTO replica_usage_audit ($keyColumns, entry_count, byte_count)
  VALUES (${_usageKeyValues(table, 'NEW')}, 1, ${_usageByteExpression(table, 'NEW')})
  ON CONFLICT (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id)
  DO UPDATE SET
    entry_count = entry_count + 1,
    byte_count = byte_count + excluded.byte_count;
END
''';
}

Future<void> _createUsageTriggers(Database db) async {
  for (final table in _usageTables) {
    for (final event in const <String>['insert', 'delete', 'update']) {
      await db.execute(_usageTriggerSql(table, event));
    }
  }
}

String _normalizeSql(String sql) =>
    sql.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

bool _hasUnexpectedTableSqlOption(String sql) {
  final normalized = _normalizeSql(sql);
  return RegExp(
    r'\b(on conflict|deferrable|initially deferred|without rowid|autoincrement|collate)\b',
  ).hasMatch(normalized);
}

List<String> _extractCheckExpressions(String sql) {
  final compact = sql.replaceAll(RegExp(r'\s+'), ' ');
  final lower = compact.toLowerCase();
  final checks = <String>[];
  var cursor = 0;
  while (cursor < lower.length) {
    final keyword = lower.indexOf('check', cursor);
    if (keyword < 0) break;
    final beforeIsBoundary =
        keyword == 0 || !RegExp(r'[a-z0-9_]').hasMatch(lower[keyword - 1]);
    var open = keyword + 'check'.length;
    while (open < lower.length && lower[open] == ' ') {
      open += 1;
    }
    if (!beforeIsBoundary || open >= lower.length || lower[open] != '(') {
      cursor = keyword + 'check'.length;
      continue;
    }
    var depth = 1;
    var quote = false;
    var close = open + 1;
    for (; close < compact.length && depth > 0; close += 1) {
      final character = compact[close];
      if (character == "'") {
        if (quote && close + 1 < compact.length && compact[close + 1] == "'") {
          close += 1;
          continue;
        }
        quote = !quote;
      } else if (!quote) {
        if (character == '(') depth += 1;
        if (character == ')') depth -= 1;
      }
    }
    if (depth != 0) break;
    checks.add(_normalizeSql(compact.substring(open + 1, close - 1)));
    cursor = close;
  }
  return checks;
}

Future<void> _verifySchema(Database db) async {
  try {
    final foreignKeyState = await db.rawQuery('PRAGMA foreign_keys');
    if (foreignKeyState.length != 1 ||
        _asInt(foreignKeyState.single['foreign_keys']) != 1) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'database foreign-key enforcement is disabled',
      );
    }
    final metadata = await db.query(
      'replica_metadata',
      columns: const <String>['schema_identity', 'schema_version'],
      where: 'schema_identity = ?',
      whereArgs: <Object?>[ConversationRepository._schemaIdentity],
      limit: 1,
    );
    if (metadata.length != 1 ||
        metadata.single['schema_version'] !=
            ConversationRepository._schemaVersion) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'database marker is not the current conversation replica',
      );
    }
    final tableRows = await db.rawQuery('PRAGMA table_list');
    final actualTables = tableRows
        .map((row) => row['name'])
        .whereType<String>()
        .where((name) => !name.startsWith('sqlite_'))
        .toSet();
    if (actualTables.length != _schemaTables.length ||
        !actualTables.containsAll(_schemaTables)) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'database table set does not match the conversation replica',
      );
    }
    for (final table in _schemaTables) {
      final rows = await db.rawQuery(
        'PRAGMA table_list(${_quoteIdentifier(table)})',
      );
      if (rows.length != 1 ||
          rows.single['type'] != 'table' ||
          _asInt(rows.single['strict']) != 1 ||
          _asInt(rows.single['wr']) != 0) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '$table is not a STRICT table',
        );
      }
      final columns = await db.rawQuery(
        'PRAGMA table_xinfo(${_quoteIdentifier(table)})',
      );
      final expected = _schemaColumns[table]!;
      if (columns.length != expected.length) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '$table has an unexpected column count',
        );
      }
      for (var index = 0; index < expected.length; index += 1) {
        final actual = columns[index];
        final wanted = expected[index];
        if (_asInt(actual['cid']) != index ||
            actual['name'] != wanted.name ||
            actual['type'] != wanted.type ||
            _asInt(actual['notnull']) != wanted.notNull ||
            _asInt(actual['pk']) != wanted.primaryKey ||
            _asInt(actual['hidden']) != wanted.hidden ||
            actual['dflt_value'] != wanted.defaultValue) {
          throw ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            '$table column ${wanted.name} does not match its declared type/PK/nullability/default',
          );
        }
      }
      final sqlRows = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        <Object?>[table],
      );
      final tableSql = sqlRows.length == 1 ? sqlRows.single['sql'] : null;
      if (tableSql is! String || _hasUnexpectedTableSqlOption(tableSql)) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '$table sqlite_master table options are not exact',
        );
      }
      final actualChecks = _extractCheckExpressions(tableSql);
      final expectedChecks = (_schemaChecks[table] ?? const <String>[])
          .map(_normalizeSql)
          .toList(growable: false);
      if (actualChecks.length != expectedChecks.length ||
          actualChecks.asMap().entries.any(
            (entry) => entry.value != expectedChecks[entry.key],
          )) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '$table sqlite_master CHECK contract is not exact',
        );
      }
    }
    final indexesByTable = <String, List<Map<String, Object?>>>{};
    for (final table in _schemaTables) {
      final rows = await db.rawQuery(
        'PRAGMA index_list(${_quoteIdentifier(table)})',
      );
      indexesByTable[table] = rows;
      final actualExplicit = rows
          .where((row) => row['origin'] == 'c')
          .map((row) => row['name'])
          .whereType<String>()
          .toSet();
      final expectedExplicit = _schemaIndexes
          .where((index) => index.table == table)
          .map((index) => index.name)
          .toSet();
      if (actualExplicit.length != expectedExplicit.length ||
          !actualExplicit.containsAll(expectedExplicit)) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '$table has an unexpected explicit index set',
        );
      }
    }
    for (final expected in _schemaIndexes) {
      final rows = await db.rawQuery(
        'PRAGMA index_list(${_quoteIdentifier(expected.table)})',
      );
      final row = rows.where((candidate) => candidate['name'] == expected.name);
      if (row.length != 1 ||
          _asInt(row.single['unique']) != expected.unique ||
          row.single['origin'] != 'c' ||
          _asInt(row.single['partial']) != 0) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '${expected.table} index ${expected.name} is missing or not exact',
        );
      }
      final info = await db.rawQuery(
        'PRAGMA index_info(${_quoteIdentifier(expected.name)})',
      );
      final xinfo = await db.rawQuery(
        'PRAGMA index_xinfo(${_quoteIdentifier(expected.name)})',
      );
      final names = info.map((entry) => entry['name']).toList(growable: false);
      final keyRows = xinfo
          .where((entry) => _asInt(entry['key']) == 1)
          .toList(growable: false);
      final auxiliaryRows = xinfo
          .where((entry) => _asInt(entry['key']) != 1)
          .toList(growable: false);
      final columnsMatch =
          names.length == expected.columns.length &&
          names.asMap().entries.every(
            (entry) => entry.value == expected.columns[entry.key],
          ) &&
          keyRows.length == expected.columns.length &&
          keyRows.asMap().entries.every((entry) {
            final index = entry.key;
            final row = entry.value;
            final collation =
                expected.collations.length == expected.columns.length
                ? expected.collations[index]
                : 'BINARY';
            final descending =
                expected.descending.length == expected.columns.length
                ? expected.descending[index]
                : 0;
            return _asInt(row['seqno']) == index &&
                row['name'] == expected.columns[index] &&
                '${row['coll']}'.toUpperCase() == collation.toUpperCase() &&
                _asInt(row['desc']) == descending;
          });
      final rowidTail =
          auxiliaryRows.length == 1 &&
          _asInt(auxiliaryRows.single['seqno']) == expected.columns.length &&
          _asInt(auxiliaryRows.single['cid']) == -1 &&
          auxiliaryRows.single['name'] == null &&
          '${auxiliaryRows.single['coll']}'.toUpperCase() == 'BINARY' &&
          _asInt(auxiliaryRows.single['desc']) == 0;
      if (!columnsMatch || !rowidTail) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '${expected.table} index ${expected.name} columns are not exact',
        );
      }
    }
    final expectedTriggers = <String, String>{
      for (final table in _usageTables)
        for (final event in const <String>['insert', 'delete', 'update'])
          _usageTriggerName(table, event): _usageTriggerSql(table, event),
    };
    final triggerRows = await db.rawQuery(
      "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name",
    );
    final actualTriggers = <String, Map<String, Object?>>{};
    for (final row in triggerRows) {
      final name = row['name'];
      if (name is! String || actualTriggers.containsKey(name)) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          'database trigger inventory is not exact',
        );
      }
      actualTriggers[name] = row;
    }
    if (actualTriggers.length != expectedTriggers.length ||
        !expectedTriggers.keys.every(actualTriggers.containsKey)) {
      throw const ConversationRepositoryException(
        RepositoryFailureCode.invalidDatabaseIdentity,
        'database trigger inventory is not exact',
      );
    }
    for (final entry in expectedTriggers.entries) {
      final row = actualTriggers[entry.key]!;
      if (row['tbl_name'] != _triggerTable(entry.key) ||
          row['sql'] is! String ||
          _normalizeSql(row['sql']! as String) != _normalizeSql(entry.value)) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          'database trigger ${entry.key} is not exact',
        );
      }
    }
    for (final table in _schemaTables) {
      final foreignKeys = await db.rawQuery(
        'PRAGMA foreign_key_list(${_quoteIdentifier(table)})',
      );
      // Keep the legacy column descriptions reachable for source-level
      // review; the grouped contract below is the actual attestation.
      assert(
        _schemaForeignKeys[table] == null ||
            _schemaForeignKeyGroups.containsKey(table),
      );
      final expectedForeign =
          _schemaForeignKeyGroups[table] ?? const <_SchemaForeignKeyGroup>[];
      final grouped = <int, List<Map<String, Object?>>>{};
      for (final row in foreignKeys) {
        final id = _asInt(row['id']);
        final seq = _asInt(row['seq']);
        final values = grouped.putIfAbsent(id, () => <Map<String, Object?>>[]);
        while (values.length <= seq) {
          values.add(<String, Object?>{});
        }
        values[seq] = row;
      }
      final actualForeign = grouped.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key));
      final groupsMatch =
          actualForeign.length == expectedForeign.length &&
          actualForeign.asMap().entries.every((entry) {
            final rows = entry.value.value;
            final expected = expectedForeign[entry.key];
            if (rows.length != expected.from.length ||
                expected.from.length != expected.to.length) {
              return false;
            }
            return rows.asMap().entries.every((rowEntry) {
              final row = rowEntry.value;
              final index = rowEntry.key;
              return '${row['table']}' == expected.table &&
                  '${row['from']}' == expected.from[index] &&
                  '${row['to']}' == expected.to[index] &&
                  '${row['on_delete']}'.toUpperCase() ==
                      expected.onDelete.toUpperCase() &&
                  '${row['on_update']}'.toUpperCase() ==
                      expected.onUpdate.toUpperCase() &&
                  '${row['match']}'.toUpperCase() ==
                      expected.match.toUpperCase();
            });
          });
      if (!groupsMatch) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '$table foreign-key grouping/order contract is not exact',
        );
      }
    }
    for (final table in _schemaTables) {
      final rows = indexesByTable[table]!;
      final expectedPrimary =
          _schemaColumns[table]!
              .where((column) => column.primaryKey > 0)
              .toList()
            ..sort(
              (left, right) => left.primaryKey.compareTo(right.primaryKey),
            );
      final expectedImplicit = <List<String>>[
        if (expectedPrimary.isNotEmpty)
          expectedPrimary.map((column) => column.name).toList(growable: false),
        ...?_schemaInlineUniqueConstraints[table],
      ];
      final actualImplicit = <String>[];
      for (final row in rows.where(
        (candidate) =>
            candidate['origin'] == 'pk' || candidate['origin'] == 'u',
      )) {
        final name = row['name'];
        if (name is! String) continue;
        final info = await db.rawQuery(
          'PRAGMA index_info(${_quoteIdentifier(name)})',
        );
        final xinfo = await db.rawQuery(
          'PRAGMA index_xinfo(${_quoteIdentifier(name)})',
        );
        final columns = info.map((entry) => '${entry['name']}').toList();
        final keyRows = xinfo
            .where((entry) => _asInt(entry['key']) == 1)
            .toList(growable: false);
        final hasExactOrder =
            keyRows.length == columns.length &&
            keyRows.asMap().entries.every(
              (entry) =>
                  _asInt(entry.value['seqno']) == entry.key &&
                  entry.value['name'] == columns[entry.key] &&
                  '${entry.value['coll']}'.toUpperCase() == 'BINARY' &&
                  _asInt(entry.value['desc']) == 0,
            );
        if (!hasExactOrder ||
            xinfo.length != columns.length + 1 ||
            _asInt(xinfo.last['key']) != 0 ||
            _asInt(xinfo.last['cid']) != -1 ||
            xinfo.last['name'] != null) {
          throw ConversationRepositoryException(
            RepositoryFailureCode.invalidDatabaseIdentity,
            '$table implicit index $name has non-exact order/collation',
          );
        }
        actualImplicit.add(
          '${columns.join('\u0000')}|${List<String>.filled(columns.length, 'BINARY').join('\u0000')}|${List<int>.filled(columns.length, 0).join('\u0000')}',
        );
      }
      String signature(List<String> columns) =>
          '${columns.join('\u0000')}|${List<String>.filled(columns.length, 'BINARY').join('\u0000')}|${List<int>.filled(columns.length, 0).join('\u0000')}';
      final expectedSignatures = expectedImplicit.map(signature).toSet();
      final actualSignatures = actualImplicit.toSet();
      if (expectedSignatures.length != actualSignatures.length ||
          !expectedSignatures.containsAll(actualSignatures)) {
        throw ConversationRepositoryException(
          RepositoryFailureCode.invalidDatabaseIdentity,
          '$table inline PK/UNIQUE contract is not exact',
        );
      }
    }
  } on ConversationRepositoryException {
    rethrow;
  } on Object catch (error) {
    throw ConversationRepositoryException(
      RepositoryFailureCode.invalidDatabaseIdentity,
      'database schema attestation failed: $error',
    );
  }
}

String _quoteIdentifier(String value) => '"${value.replaceAll('"', '""')}"';

int _asInt(Object? value) => value is int ? value : int.parse('$value');

Future<void> _acquireWriterLease(
  ConversationRepository repository,
  Database db,
) async {
  await db.transaction((txn) async {
    final rows = await txn.query(
      'writer_lease',
      columns: const <String>[
        'owner_token',
        'owner_pid',
        'owner_boot_id',
        'owner_process_instance_id',
        'heartbeat_at',
      ],
      where: 'lease_name = ?',
      whereArgs: const <Object?>[ConversationRepository._leaseName],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final owner = rows.single;
      if (!await _leaseCanBeReclaimed(repository, owner)) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.writerLeaseUnavailable,
          'another live process owns this canonical database path',
        );
      }
      final removed = await txn.delete(
        'writer_lease',
        where: _leaseOwnerWhere(),
        whereArgs: _leaseOwnerArgs(owner),
      );
      if (removed != 1) {
        throw const ConversationRepositoryException(
          RepositoryFailureCode.writerLeaseUnavailable,
          'writer lease changed while reclaiming a dead owner',
        );
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.insert('writer_lease', <String, Object?>{
      'lease_name': ConversationRepository._leaseName,
      'owner_token': repository._ownerToken,
      'owner_pid': pid,
      'owner_boot_id': ConversationRepository._bootIdentity,
      'owner_process_instance_id':
          ConversationRepository._processInstanceIdentity,
      'acquired_at': now,
      'heartbeat_at': now,
    });
  });
}

Future<bool> _leaseCanBeReclaimed(
  ConversationRepository repository,
  Map<String, Object?> owner,
) async {
  final heartbeat = owner['heartbeat_at'];
  final heartbeatAt = heartbeat is int ? heartbeat : 0;
  final expired =
      DateTime.now().millisecondsSinceEpoch - heartbeatAt >
      ConversationRepository.writerLeaseTimeout.inMilliseconds;
  final ownerPid = owner['owner_pid'];
  if (ownerPid is! int) return false;
  final sameProcessInstance =
      ownerPid == pid &&
      owner['owner_boot_id'] == ConversationRepository._bootIdentity &&
      owner['owner_process_instance_id'] ==
          ConversationRepository._processInstanceIdentity;
  final probe = repository.processLivenessProbe;
  if (probe != null) {
    try {
      // A supplied probe is the only evidence strong enough to reclaim a
      // fresh lease.  In particular, it may prove that an owner from this
      // process instance has actually exited in a test harness.
      return !(await probe(ownerPid));
    } catch (_) {
      // A failed liveness check is not evidence that a same-process owner is
      // dead.  A same-PID owner may be a live second Dart isolate, so a stale
      // heartbeat alone is not sufficient for that case either.
      return ownerPid != pid && !sameProcessInstance && expired;
    }
  }
  // The owner heartbeat is refreshed periodically while a repository is open,
  // but fail closed for an idle owner from any same-PID isolate as an
  // additional guard against a timer/scheduler pause.  A different PID is
  // reclaimable only after its heartbeat expires.
  return ownerPid != pid && !sameProcessInstance && expired;
}

String _leaseOwnerWhere() =>
    'lease_name = ? AND owner_token = ? AND owner_pid = ? AND owner_boot_id = ? AND owner_process_instance_id = ?';

List<Object?> _leaseOwnerArgs(Map<String, Object?> owner) => <Object?>[
  ConversationRepository._leaseName,
  owner['owner_token'],
  owner['owner_pid'],
  owner['owner_boot_id'],
  owner['owner_process_instance_id'],
];

Future<void> _assertWriterLease(
  DatabaseExecutor db,
  ConversationRepository repository,
) async {
  final rows = await db.query(
    'writer_lease',
    columns: const <String>[
      'owner_token',
      'owner_pid',
      'owner_boot_id',
      'owner_process_instance_id',
    ],
    where: 'lease_name = ?',
    whereArgs: const <Object?>[ConversationRepository._leaseName],
    limit: 1,
  );
  if (rows.length != 1 ||
      rows.single['owner_token'] != repository._ownerToken ||
      rows.single['owner_pid'] != pid ||
      rows.single['owner_boot_id'] != ConversationRepository._bootIdentity ||
      rows.single['owner_process_instance_id'] !=
          ConversationRepository._processInstanceIdentity) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.writerLeaseUnavailable,
      'writer lease was lost before a mutation',
    );
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  final updated = await db.update(
    'writer_lease',
    <String, Object?>{'heartbeat_at': now},
    where: _leaseOwnerWhere(),
    whereArgs: <Object?>[
      ConversationRepository._leaseName,
      repository._ownerToken,
      pid,
      ConversationRepository._bootIdentity,
      ConversationRepository._processInstanceIdentity,
    ],
  );
  if (updated != 1) {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.writerLeaseUnavailable,
      'writer lease changed during heartbeat',
    );
  }
}

Future<void> _releaseWriterLease(
  ConversationRepository repository,
  Database db,
) async {
  await db.transaction((txn) async {
    await txn.delete(
      'writer_lease',
      where: _leaseOwnerWhere(),
      whereArgs: <Object?>[
        ConversationRepository._leaseName,
        repository._ownerToken,
        pid,
        ConversationRepository._bootIdentity,
        ConversationRepository._processInstanceIdentity,
      ],
    );
  });
}

Map<String, Object?> _partitionColumns(SourcePartition partition) =>
    <String, Object?>{
      'bridge_identity_id': partition.bridgeIdentityId,
      'bridge_instance_id': partition.bridgeInstanceId,
      'codex_source_id': partition.codexSourceId,
    };

Map<String, Object?> _keyColumns(ThreadKey key) => <String, Object?>{
  ..._partitionColumns(key.partition),
  'provider_thread_id': key.providerThreadId,
};

String _partitionWhere() =>
    'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ?';

String _keyWhere() =>
    'bridge_identity_id = ? AND bridge_instance_id = ? AND codex_source_id = ? AND provider_thread_id = ?';

List<Object?> _partitionArgs(SourcePartition partition) => <Object?>[
  partition.bridgeIdentityId,
  partition.bridgeInstanceId,
  partition.codexSourceId,
];

List<Object?> _keyArgs(ThreadKey key) => <Object?>[
  ..._partitionArgs(key.partition),
  key.providerThreadId,
];

String _stagingWhere() =>
    '${_keyWhere()} AND source_epoch = ? AND provider_instance_epoch = ?';

List<Object?> _stagingArgs(
  ThreadKey key,
  String sourceEpoch,
  String providerInstanceEpoch,
) => <Object?>[..._keyArgs(key), sourceEpoch, providerInstanceEpoch];

String _outboxWhere() =>
    '${_keyWhere()} AND source_epoch = ? AND provider_instance_epoch = ? AND domain = ? AND operation_id = ?';

List<Object?> _outboxArgs(
  ThreadKey key,
  String sourceEpoch,
  String providerInstanceEpoch,
  String domain,
  String operationId,
) => <Object?>[
  ..._keyArgs(key),
  sourceEpoch,
  providerInstanceEpoch,
  domain,
  operationId,
];
