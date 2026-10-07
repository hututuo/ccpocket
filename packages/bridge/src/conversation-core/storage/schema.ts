export const CONVERSATION_CORE_SCHEMA_VERSION = 3;

export const CONVERSATION_CORE_TABLES = [
  "meta",
  "writer_owner",
  "source_partition",
  "timeline_materialization",
  "timeline_page",
  "timeline_item",
  "timeline_gap",
  "timeline_coverage_island",
  "timeline_head",
  "timeline_read_attempt",
  "operation",
  "operation_event",
  "reconcile_round",
  "reconcile_fact",
  "reconcile_resolution",
  "queue_lane",
  "queue_entry",
  "interaction",
  "interaction_claim",
] as const;

export const CONVERSATION_CORE_BOOTSTRAP_DDL = `
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY CHECK (length(CAST(key AS BLOB)) BETWEEN 1 AND 128),
  value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) BETWEEN 1 AND 4096)
) STRICT;

CREATE TABLE IF NOT EXISTS writer_owner (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  owner_id TEXT NOT NULL CHECK (length(CAST(owner_id AS BLOB)) BETWEEN 1 AND 128),
  owner_pid INTEGER NOT NULL CHECK (owner_pid > 0),
  owner_epoch INTEGER NOT NULL CHECK (owner_epoch >= 1),
  lease_expires_at INTEGER NOT NULL CHECK (lease_expires_at > 0),
  updated_at INTEGER NOT NULL CHECK (updated_at > 0)
) STRICT;
`;

export const CONVERSATION_CORE_DDL = `
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY CHECK (length(CAST(key AS BLOB)) BETWEEN 1 AND 128),
  value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) BETWEEN 1 AND 4096)
) STRICT;

CREATE TABLE IF NOT EXISTS writer_owner (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  owner_id TEXT NOT NULL CHECK (length(CAST(owner_id AS BLOB)) BETWEEN 1 AND 128),
  owner_pid INTEGER NOT NULL CHECK (owner_pid > 0),
  owner_epoch INTEGER NOT NULL CHECK (owner_epoch >= 1),
  lease_expires_at INTEGER NOT NULL CHECK (lease_expires_at > 0),
  updated_at INTEGER NOT NULL CHECK (updated_at > 0)
) STRICT;

CREATE TABLE IF NOT EXISTS source_partition (
  bridge_identity_id TEXT NOT NULL CHECK (length(CAST(bridge_identity_id AS BLOB)) BETWEEN 1 AND 256),
  bridge_instance_id TEXT NOT NULL CHECK (length(CAST(bridge_instance_id AS BLOB)) BETWEEN 1 AND 256),
  codex_source_id TEXT NOT NULL CHECK (length(CAST(codex_source_id AS BLOB)) BETWEEN 1 AND 256),
  created_at INTEGER NOT NULL CHECK (created_at > 0),
  PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_materialization (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL CHECK (length(CAST(provider_thread_id AS BLOB)) BETWEEN 1 AND 256),
  materialization_id TEXT NOT NULL CHECK (length(CAST(materialization_id AS BLOB)) BETWEEN 1 AND 256),
  connection_generation INTEGER NOT NULL CHECK (connection_generation >= 0),
  provider_generation INTEGER NOT NULL CHECK (provider_generation >= 0),
  source_epoch_json TEXT NOT NULL CHECK (
    json_valid(source_epoch_json) AND json_type(source_epoch_json) = 'object' AND
    length(CAST(source_epoch_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  evidence_json TEXT NOT NULL CHECK (
    json_valid(evidence_json) AND json_type(evidence_json) = 'object' AND
    length(CAST(evidence_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  read_evidence_digest TEXT NOT NULL CHECK (
    length(read_evidence_digest) = 64 AND read_evidence_digest NOT GLOB '*[^0-9a-f]*'
  ),
  state TEXT NOT NULL CHECK (state IN ('STAGING', 'SEALED', 'ABORTED')),
  page_count INTEGER NOT NULL DEFAULT 0 CHECK (page_count >= 0),
  item_count INTEGER NOT NULL DEFAULT 0 CHECK (item_count BETWEEN 0 AND 100000),
  gap_count INTEGER NOT NULL DEFAULT 0 CHECK (gap_count BETWEEN 0 AND 100000),
  total_bytes INTEGER NOT NULL DEFAULT 0 CHECK (total_bytes BETWEEN 0 AND 67108864),
  materialization_digest TEXT CHECK (
    materialization_digest IS NULL OR
    (length(materialization_digest) = 64 AND materialization_digest NOT GLOB '*[^0-9a-f]*')
  ),
  order_digest TEXT CHECK (
    order_digest IS NULL OR (length(order_digest) = 64 AND order_digest NOT GLOB '*[^0-9a-f]*')
  ),
  coverage_digest TEXT CHECK (
    coverage_digest IS NULL OR (length(coverage_digest) = 64 AND coverage_digest NOT GLOB '*[^0-9a-f]*')
  ),
  empty_proof_json TEXT CHECK (
    empty_proof_json IS NULL OR
    (json_valid(empty_proof_json) AND json_type(empty_proof_json) = 'object' AND
     length(CAST(empty_proof_json AS BLOB)) BETWEEN 2 AND 65536)
  ),
  verified_at INTEGER,
  created_at INTEGER NOT NULL CHECK (created_at > 0),
  updated_at INTEGER NOT NULL CHECK (updated_at > 0),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_page (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  materialization_id TEXT NOT NULL,
  page_index INTEGER NOT NULL CHECK (page_index BETWEEN 0 AND 9007199254740991),
  previous_page_digest TEXT CHECK (
    previous_page_digest IS NULL OR
    (length(previous_page_digest) = 64 AND previous_page_digest NOT GLOB '*[^0-9a-f]*')
  ),
  page_digest TEXT NOT NULL CHECK (
    length(page_digest) = 64 AND page_digest NOT GLOB '*[^0-9a-f]*'
  ),
  item_count INTEGER NOT NULL CHECK (item_count BETWEEN 0 AND 100000),
  gap_count INTEGER NOT NULL CHECK (gap_count BETWEEN 0 AND 100000),
  body_bytes INTEGER NOT NULL CHECK (body_bytes BETWEEN 2 AND 262144),
  body_json TEXT NOT NULL CHECK (
    json_valid(body_json) AND json_type(body_json) = 'object' AND
    length(CAST(body_json AS BLOB)) BETWEEN 2 AND 262144
  ),
  created_at INTEGER NOT NULL CHECK (created_at > 0),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, page_index
  ),
  UNIQUE (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, page_digest
  ),
  FOREIGN KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) REFERENCES timeline_materialization (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_item (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  materialization_id TEXT NOT NULL,
  item_id TEXT NOT NULL CHECK (length(CAST(item_id AS BLOB)) BETWEEN 1 AND 256),
  provider_turn_id TEXT NOT NULL CHECK (length(CAST(provider_turn_id AS BLOB)) BETWEEN 1 AND 256),
  turn_ordinal INTEGER NOT NULL CHECK (
    turn_ordinal BETWEEN -9007199254740991 AND 9007199254740991
  ),
  item_ordinal INTEGER NOT NULL CHECK (item_ordinal BETWEEN 0 AND 9007199254740991),
  timeline_ordinal INTEGER NOT NULL CHECK (
    timeline_ordinal BETWEEN -9007199254740991 AND 9007199254740991
  ),
  item_kind TEXT NOT NULL CHECK (length(CAST(item_kind AS BLOB)) BETWEEN 1 AND 128),
  payload_json TEXT NOT NULL CHECK (
    json_valid(payload_json) AND json_type(payload_json) = 'object' AND
    length(CAST(payload_json AS BLOB)) BETWEEN 2 AND 262144
  ),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, provider_turn_id, item_id
  ),
  UNIQUE (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, timeline_ordinal
  ),
  UNIQUE (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, turn_ordinal, item_ordinal
  ),
  FOREIGN KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) REFERENCES timeline_materialization (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_gap (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  materialization_id TEXT NOT NULL,
  gap_id TEXT NOT NULL CHECK (length(CAST(gap_id AS BLOB)) BETWEEN 1 AND 256),
  gap_ordinal INTEGER NOT NULL CHECK (gap_ordinal BETWEEN 0 AND 9007199254740991),
  gap_kind TEXT NOT NULL CHECK (gap_kind IN ('STRUCTURAL', 'PAYLOAD')),
  first_missing_timeline_ordinal INTEGER NOT NULL CHECK (
    first_missing_timeline_ordinal BETWEEN -9007199254740991 AND 9007199254740991
  ),
  last_missing_timeline_ordinal INTEGER NOT NULL CHECK (
    last_missing_timeline_ordinal BETWEEN -9007199254740991 AND 9007199254740991 AND
    last_missing_timeline_ordinal >= first_missing_timeline_ordinal
  ),
  reason TEXT NOT NULL CHECK (reason IN (
    'PROVIDER_PAGE_MISSING', 'OVERSIZED_TURN', 'ITEM_PAYLOAD_UNAVAILABLE',
    'UNKNOWN_PROVIDER_ITEM'
  )),
  descriptor_json TEXT NOT NULL CHECK (
    json_valid(descriptor_json) AND json_type(descriptor_json) = 'object' AND
    length(CAST(descriptor_json AS BLOB)) BETWEEN 2 AND 262144
  ),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, gap_id
  ),
  UNIQUE (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, gap_ordinal
  ),
  FOREIGN KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) REFERENCES timeline_materialization (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_coverage_island (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  materialization_id TEXT NOT NULL,
  island_id TEXT NOT NULL CHECK (length(CAST(island_id AS BLOB)) BETWEEN 1 AND 256),
  island_ordinal INTEGER NOT NULL CHECK (island_ordinal BETWEEN 0 AND 9007199254740991),
  first_timeline_ordinal INTEGER NOT NULL CHECK (
    first_timeline_ordinal BETWEEN -9007199254740991 AND 9007199254740991
  ),
  last_timeline_ordinal INTEGER NOT NULL CHECK (
    last_timeline_ordinal BETWEEN -9007199254740991 AND 9007199254740991 AND
    last_timeline_ordinal >= first_timeline_ordinal
  ),
  structural_coverage TEXT NOT NULL CHECK (structural_coverage IN ('COMPLETE', 'PARTIAL')),
  payload_coverage TEXT NOT NULL CHECK (payload_coverage IN ('COMPLETE', 'PARTIAL')),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, island_id
  ),
  UNIQUE (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id, island_ordinal
  ),
  FOREIGN KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) REFERENCES timeline_materialization (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_head (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  materialization_id TEXT NOT NULL,
  updated_at INTEGER NOT NULL CHECK (updated_at > 0),
  PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id),
  FOREIGN KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  ) REFERENCES timeline_materialization (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    materialization_id
  )
) STRICT;

CREATE TRIGGER IF NOT EXISTS timeline_materialization_sealed_immutable
BEFORE UPDATE ON timeline_materialization
WHEN OLD.state IN ('SEALED', 'ABORTED')
BEGIN
  SELECT RAISE(ABORT, 'sealed timeline materialization is immutable');
END;

CREATE TRIGGER IF NOT EXISTS timeline_page_sealed_immutable_update
BEFORE UPDATE ON timeline_page
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline page is immutable'); END;
CREATE TRIGGER IF NOT EXISTS timeline_page_sealed_immutable_delete
BEFORE DELETE ON timeline_page
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline page is immutable'); END;

CREATE TRIGGER IF NOT EXISTS timeline_item_sealed_immutable_update
BEFORE UPDATE ON timeline_item
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline item is immutable'); END;
CREATE TRIGGER IF NOT EXISTS timeline_item_sealed_immutable_delete
BEFORE DELETE ON timeline_item
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline item is immutable'); END;

CREATE TRIGGER IF NOT EXISTS timeline_gap_sealed_immutable_update
BEFORE UPDATE ON timeline_gap
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline gap is immutable'); END;
CREATE TRIGGER IF NOT EXISTS timeline_gap_sealed_immutable_delete
BEFORE DELETE ON timeline_gap
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline gap is immutable'); END;

CREATE TRIGGER IF NOT EXISTS timeline_island_sealed_immutable_update
BEFORE UPDATE ON timeline_coverage_island
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline island is immutable'); END;
CREATE TRIGGER IF NOT EXISTS timeline_island_sealed_immutable_delete
BEFORE DELETE ON timeline_coverage_island
WHEN EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=OLD.bridge_identity_id AND m.bridge_instance_id=OLD.bridge_instance_id AND
    m.codex_source_id=OLD.codex_source_id AND m.provider_thread_id=OLD.provider_thread_id AND
    m.materialization_id=OLD.materialization_id AND m.state='SEALED'
)
BEGIN SELECT RAISE(ABORT, 'sealed timeline island is immutable'); END;

CREATE TRIGGER IF NOT EXISTS timeline_head_requires_sealed_insert
BEFORE INSERT ON timeline_head
WHEN NEW.revision != 1 OR NOT EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=NEW.bridge_identity_id AND
    m.bridge_instance_id=NEW.bridge_instance_id AND
    m.codex_source_id=NEW.codex_source_id AND
    m.provider_thread_id=NEW.provider_thread_id AND
    m.materialization_id=NEW.materialization_id AND m.state='SEALED'
)
BEGIN
  SELECT RAISE(ABORT, 'timeline head requires sealed materialization');
END;

CREATE TRIGGER IF NOT EXISTS timeline_head_requires_sealed_update
BEFORE UPDATE ON timeline_head
WHEN OLD.bridge_identity_id != NEW.bridge_identity_id OR
     OLD.bridge_instance_id != NEW.bridge_instance_id OR
     OLD.codex_source_id != NEW.codex_source_id OR
     OLD.provider_thread_id != NEW.provider_thread_id OR
     NEW.revision != OLD.revision + 1 OR
     NEW.materialization_id = OLD.materialization_id OR
     NEW.updated_at < OLD.updated_at OR
     NOT EXISTS (
  SELECT 1 FROM timeline_materialization m WHERE
    m.bridge_identity_id=NEW.bridge_identity_id AND
    m.bridge_instance_id=NEW.bridge_instance_id AND
    m.codex_source_id=NEW.codex_source_id AND
    m.provider_thread_id=NEW.provider_thread_id AND
    m.materialization_id=NEW.materialization_id AND m.state='SEALED'
)
BEGIN
  SELECT RAISE(ABORT, 'timeline head requires sealed materialization');
END;

CREATE TRIGGER IF NOT EXISTS timeline_head_no_delete
BEFORE DELETE ON timeline_head
BEGIN SELECT RAISE(ABORT, 'timeline head is canonical and cannot be deleted'); END;

CREATE TABLE IF NOT EXISTS timeline_read_attempt (
  attempt_id TEXT PRIMARY KEY CHECK (length(CAST(attempt_id AS BLOB)) BETWEEN 1 AND 256),
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  connection_generation INTEGER NOT NULL CHECK (connection_generation >= 0),
  provider_generation INTEGER NOT NULL CHECK (provider_generation >= 0),
  source_epoch_json TEXT NOT NULL CHECK (
    json_valid(source_epoch_json) AND json_type(source_epoch_json) = 'object' AND
    length(CAST(source_epoch_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  outcome TEXT NOT NULL CHECK (outcome IN ('FAILED', 'PARTIAL', 'TIMEOUT', 'READ_ERROR')),
  evidence_digest TEXT CHECK (
    evidence_digest IS NULL OR
    (length(evidence_digest) = 64 AND evidence_digest NOT GLOB '*[^0-9a-f]*')
  ),
  problem_json TEXT NOT NULL CHECK (
    json_valid(problem_json) AND json_type(problem_json) = 'object' AND
    length(CAST(problem_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  observed_at INTEGER NOT NULL CHECK (observed_at > 0),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
) STRICT;

CREATE TABLE IF NOT EXISTS operation (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL CHECK (length(CAST(provider_thread_id AS BLOB)) BETWEEN 1 AND 256),
  connection_generation INTEGER NOT NULL CHECK (connection_generation >= 0),
  provider_generation INTEGER NOT NULL CHECK (provider_generation >= 0),
  source_epoch_json TEXT NOT NULL CHECK (
    json_valid(source_epoch_json) AND json_type(source_epoch_json) = 'object' AND
    length(CAST(source_epoch_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  actor_id TEXT NOT NULL CHECK (length(CAST(actor_id AS BLOB)) BETWEEN 1 AND 256),
  origin_kind TEXT NOT NULL CHECK (origin_kind IN ('MOBILE_CLIENT', 'BRIDGE_INTERNAL', 'PROVIDER_READER')),
  origin_id TEXT NOT NULL CHECK (length(CAST(origin_id AS BLOB)) BETWEEN 1 AND 256),
  client_instance_id TEXT NOT NULL CHECK (length(CAST(client_instance_id AS BLOB)) BETWEEN 1 AND 256),
  client_message_id TEXT NOT NULL CHECK (length(CAST(client_message_id AS BLOB)) BETWEEN 1 AND 256),
  operation_id TEXT NOT NULL UNIQUE CHECK (length(CAST(operation_id AS BLOB)) BETWEEN 1 AND 256),
  operation_code TEXT NOT NULL CHECK (operation_code IN (
    'OP-001', 'OP-002', 'OP-003', 'OP-004', 'OP-005', 'OP-006',
    'OP-016', 'OP-017', 'OP-018', 'OP-019', 'OP-020', 'OP-021', 'OP-022'
  )),
  conflict_family TEXT NOT NULL CHECK (conflict_family IN (
    'THREAD_MUTATION', 'QUEUE_CONTROL', 'INTERACTION_RESPONSE'
  )),
  fingerprint TEXT NOT NULL CHECK (
    length(fingerprint) = 64 AND fingerprint NOT GLOB '*[^0-9a-f]*'
  ),
  target_json TEXT NOT NULL CHECK (
    json_valid(target_json) AND json_type(target_json) = 'object' AND
    length(CAST(target_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  payload_json TEXT NOT NULL CHECK (
    json_valid(payload_json) AND json_type(payload_json) = 'object' AND
    length(CAST(payload_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  preconditions_json TEXT NOT NULL CHECK (
    json_valid(preconditions_json) AND json_type(preconditions_json) = 'object' AND
    length(CAST(preconditions_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  dispatch_attempt_id TEXT UNIQUE CHECK (
    dispatch_attempt_id IS NULL OR length(CAST(dispatch_attempt_id AS BLOB)) BETWEEN 1 AND 256
  ),
  provider_turn_id TEXT CHECK (
    provider_turn_id IS NULL OR length(CAST(provider_turn_id AS BLOB)) BETWEEN 1 AND 256
  ),
  state TEXT NOT NULL CHECK (state IN (
    'RECEIVED', 'DURABLY_ADMITTED', 'QUEUED', 'CALL_STARTED', 'PROVIDER_ACCEPTED',
    'CANONICAL_OBSERVED', 'SUCCEEDED', 'REJECTED', 'CANCELLED', 'OUTCOME_UNKNOWN'
  )),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  canonical_observed INTEGER NOT NULL CHECK (canonical_observed IN (0, 1)),
  reconcile_required INTEGER NOT NULL CHECK (reconcile_required IN (0, 1)),
  transition_event_kind TEXT NOT NULL CHECK (
    length(CAST(transition_event_kind AS BLOB)) BETWEEN 1 AND 128
  ),
  transition_details_json TEXT CHECK (
    transition_details_json IS NULL OR
    (json_valid(transition_details_json) AND json_type(transition_details_json) = 'object' AND
     length(CAST(transition_details_json AS BLOB)) BETWEEN 2 AND 65536)
  ),
  created_at INTEGER NOT NULL CHECK (created_at > 0),
  dispatch_started_at INTEGER,
  provider_accepted_at INTEGER,
  canonical_observed_at INTEGER,
  updated_at INTEGER NOT NULL CHECK (updated_at > 0),
  CHECK (state != 'CALL_STARTED' OR dispatch_attempt_id IS NOT NULL),
  CHECK (state != 'PROVIDER_ACCEPTED' OR (dispatch_attempt_id IS NOT NULL AND provider_turn_id IS NOT NULL)),
  CHECK (canonical_observed = 0 OR (provider_turn_id IS NOT NULL AND canonical_observed_at IS NOT NULL)),
  CHECK (state != 'OUTCOME_UNKNOWN' OR reconcile_required = 1),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    client_instance_id, client_message_id
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
) STRICT;

CREATE TABLE IF NOT EXISTS operation_event (
  operation_id TEXT NOT NULL,
  event_sequence INTEGER NOT NULL CHECK (event_sequence >= 1),
  from_state TEXT CHECK (from_state IS NULL OR from_state IN (
    'RECEIVED', 'DURABLY_ADMITTED', 'QUEUED', 'CALL_STARTED', 'PROVIDER_ACCEPTED',
    'CANONICAL_OBSERVED', 'SUCCEEDED', 'REJECTED', 'CANCELLED', 'OUTCOME_UNKNOWN'
  )),
  to_state TEXT NOT NULL CHECK (to_state IN (
    'RECEIVED', 'DURABLY_ADMITTED', 'QUEUED', 'CALL_STARTED', 'PROVIDER_ACCEPTED',
    'CANONICAL_OBSERVED', 'SUCCEEDED', 'REJECTED', 'CANCELLED', 'OUTCOME_UNKNOWN'
  )),
  event_kind TEXT NOT NULL CHECK (length(CAST(event_kind AS BLOB)) BETWEEN 1 AND 128),
  dispatch_attempt_id TEXT CHECK (
    dispatch_attempt_id IS NULL OR length(CAST(dispatch_attempt_id AS BLOB)) BETWEEN 1 AND 256
  ),
  provider_turn_id TEXT CHECK (
    provider_turn_id IS NULL OR length(CAST(provider_turn_id AS BLOB)) BETWEEN 1 AND 256
  ),
  details_json TEXT CHECK (
    details_json IS NULL OR
    (json_valid(details_json) AND json_type(details_json) = 'object' AND
     length(CAST(details_json AS BLOB)) BETWEEN 2 AND 65536)
  ),
  created_at INTEGER NOT NULL CHECK (created_at > 0),
  PRIMARY KEY (operation_id, event_sequence),
  FOREIGN KEY (operation_id) REFERENCES operation (operation_id) ON DELETE CASCADE
) STRICT;

CREATE TRIGGER IF NOT EXISTS operation_initial_event
AFTER INSERT ON operation
BEGIN
  INSERT INTO operation_event (
    operation_id, event_sequence, from_state, to_state, event_kind,
    dispatch_attempt_id, provider_turn_id, details_json, created_at
  ) VALUES (
    NEW.operation_id, 1, NULL, NEW.state, NEW.transition_event_kind,
    NEW.dispatch_attempt_id, NEW.provider_turn_id, NEW.transition_details_json, NEW.created_at
  );
END;

CREATE TRIGGER IF NOT EXISTS operation_immutable_identity
BEFORE UPDATE ON operation
WHEN OLD.bridge_identity_id != NEW.bridge_identity_id OR
     OLD.bridge_instance_id != NEW.bridge_instance_id OR
     OLD.codex_source_id != NEW.codex_source_id OR
     OLD.provider_thread_id != NEW.provider_thread_id OR
     OLD.connection_generation != NEW.connection_generation OR
     OLD.provider_generation != NEW.provider_generation OR
     OLD.source_epoch_json != NEW.source_epoch_json OR
     OLD.actor_id != NEW.actor_id OR OLD.origin_kind != NEW.origin_kind OR OLD.origin_id != NEW.origin_id OR
     OLD.client_instance_id != NEW.client_instance_id OR OLD.client_message_id != NEW.client_message_id OR
     OLD.operation_id != NEW.operation_id OR OLD.operation_code != NEW.operation_code OR
     OLD.conflict_family != NEW.conflict_family OR OLD.fingerprint != NEW.fingerprint OR
     OLD.target_json != NEW.target_json OR OLD.payload_json != NEW.payload_json OR
     OLD.preconditions_json != NEW.preconditions_json
BEGIN
  SELECT RAISE(ABORT, 'operation immutable identity violation');
END;

CREATE TRIGGER IF NOT EXISTS operation_terminal_immutable
BEFORE UPDATE ON operation
WHEN OLD.state IN ('SUCCEEDED', 'REJECTED', 'CANCELLED', 'OUTCOME_UNKNOWN')
BEGIN
  SELECT RAISE(ABORT, 'operation terminal state is immutable');
END;

CREATE TRIGGER IF NOT EXISTS operation_safe_transition
BEFORE UPDATE OF state ON operation
WHEN NOT (
  (OLD.state = 'DURABLY_ADMITTED' AND NEW.state IN ('QUEUED', 'CALL_STARTED', 'CANCELLED')) OR
  (OLD.state = 'DURABLY_ADMITTED' AND NEW.state = 'SUCCEEDED' AND NEW.operation_code IN ('OP-002', 'OP-003')) OR
  (OLD.state = 'QUEUED' AND NEW.state IN ('CALL_STARTED', 'CANCELLED')) OR
  (OLD.state = 'CALL_STARTED' AND NEW.state IN ('PROVIDER_ACCEPTED', 'REJECTED', 'OUTCOME_UNKNOWN')) OR
  (OLD.state = 'PROVIDER_ACCEPTED' AND NEW.state IN ('CANONICAL_OBSERVED', 'OUTCOME_UNKNOWN')) OR
  (OLD.state = 'CANONICAL_OBSERVED' AND NEW.state = 'SUCCEEDED')
)
BEGIN
  SELECT RAISE(ABORT, 'operation invalid state transition');
END;

CREATE TRIGGER IF NOT EXISTS operation_updates_require_state_transition
BEFORE UPDATE ON operation
WHEN NEW.state = OLD.state
BEGIN
  SELECT RAISE(ABORT, 'operation update requires a state transition');
END;

CREATE TRIGGER IF NOT EXISTS operation_revision_event_coupling
BEFORE UPDATE OF state ON operation
WHEN NEW.revision != OLD.revision + 1
BEGIN
  SELECT RAISE(ABORT, 'operation revision/event coupling violation');
END;

CREATE TRIGGER IF NOT EXISTS operation_transition_event
AFTER UPDATE OF state ON operation
BEGIN
  INSERT INTO operation_event (
    operation_id, event_sequence, from_state, to_state, event_kind,
    dispatch_attempt_id, provider_turn_id, details_json, created_at
  ) VALUES (
    NEW.operation_id, NEW.revision, OLD.state, NEW.state, NEW.transition_event_kind,
    NEW.dispatch_attempt_id, NEW.provider_turn_id, NEW.transition_details_json, NEW.updated_at
  );
END;

CREATE TRIGGER IF NOT EXISTS operation_no_delete
BEFORE DELETE ON operation
BEGIN
  SELECT RAISE(ABORT, 'operation rows are immutable ledger roots');
END;

CREATE TRIGGER IF NOT EXISTS operation_event_matches_aggregate
BEFORE INSERT ON operation_event
WHEN NOT EXISTS (
  SELECT 1 FROM operation o WHERE o.operation_id=NEW.operation_id AND
    o.revision=NEW.event_sequence AND o.state=NEW.to_state
) OR (
  NEW.event_sequence > 1 AND NOT EXISTS (
    SELECT 1 FROM operation_event previous WHERE
      previous.operation_id=NEW.operation_id AND
      previous.event_sequence=NEW.event_sequence-1 AND
      previous.to_state=NEW.from_state
  )
)
BEGIN
  SELECT RAISE(ABORT, 'operation event does not match aggregate revision');
END;

CREATE TRIGGER IF NOT EXISTS operation_event_append_only_update
BEFORE UPDATE ON operation_event BEGIN SELECT RAISE(ABORT, 'operation_event append only'); END;
CREATE TRIGGER IF NOT EXISTS operation_event_append_only_delete
BEFORE DELETE ON operation_event BEGIN SELECT RAISE(ABORT, 'operation_event append only'); END;

CREATE TABLE IF NOT EXISTS reconcile_round (
  operation_id TEXT NOT NULL,
  reconcile_round_id TEXT NOT NULL CHECK (length(CAST(reconcile_round_id AS BLOB)) BETWEEN 1 AND 256),
  created_at INTEGER NOT NULL CHECK (created_at > 0),
  PRIMARY KEY (operation_id, reconcile_round_id),
  FOREIGN KEY (operation_id) REFERENCES operation (operation_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS reconcile_fact (
  operation_id TEXT NOT NULL,
  reconcile_round_id TEXT NOT NULL,
  fact_id TEXT NOT NULL CHECK (length(CAST(fact_id AS BLOB)) BETWEEN 1 AND 256),
  fact_kind TEXT NOT NULL CHECK (fact_kind IN (
    'PROVIDER_ACCEPTED', 'CANONICAL_OBSERVED', 'PROVIDER_REJECTED', 'PROVIDER_CANCELLED'
  )),
  evidence_digest TEXT NOT NULL CHECK (
    length(evidence_digest) = 64 AND evidence_digest NOT GLOB '*[^0-9a-f]*'
  ),
  evidence_json TEXT NOT NULL CHECK (
    json_valid(evidence_json) AND json_type(evidence_json) = 'object' AND
    length(CAST(evidence_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  provider_turn_id TEXT,
  created_at INTEGER NOT NULL CHECK (created_at > 0),
  PRIMARY KEY (operation_id, reconcile_round_id, fact_id),
  FOREIGN KEY (operation_id, reconcile_round_id)
    REFERENCES reconcile_round (operation_id, reconcile_round_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS reconcile_resolution (
  operation_id TEXT NOT NULL,
  reconcile_round_id TEXT NOT NULL,
  fact_id TEXT NOT NULL,
  projected_outcome TEXT NOT NULL CHECK (projected_outcome IN (
    'PROVIDER_ACCEPTED', 'SUCCEEDED', 'REJECTED', 'CANCELLED'
  )),
  evidence_digest TEXT NOT NULL CHECK (
    length(evidence_digest) = 64 AND evidence_digest NOT GLOB '*[^0-9a-f]*'
  ),
  resolved_at INTEGER NOT NULL CHECK (resolved_at > 0),
  PRIMARY KEY (operation_id, reconcile_round_id),
  FOREIGN KEY (operation_id, reconcile_round_id, fact_id)
    REFERENCES reconcile_fact (operation_id, reconcile_round_id, fact_id)
) STRICT;

CREATE TRIGGER IF NOT EXISTS reconcile_round_append_only_update
BEFORE UPDATE ON reconcile_round BEGIN SELECT RAISE(ABORT, 'reconcile_round append only'); END;
CREATE TRIGGER IF NOT EXISTS reconcile_round_append_only_delete
BEFORE DELETE ON reconcile_round BEGIN SELECT RAISE(ABORT, 'reconcile_round append only'); END;
CREATE TRIGGER IF NOT EXISTS reconcile_fact_append_only_update
BEFORE UPDATE ON reconcile_fact BEGIN SELECT RAISE(ABORT, 'reconcile_fact append only'); END;
CREATE TRIGGER IF NOT EXISTS reconcile_fact_append_only_delete
BEFORE DELETE ON reconcile_fact BEGIN SELECT RAISE(ABORT, 'reconcile_fact append only'); END;
CREATE TRIGGER IF NOT EXISTS reconcile_resolution_append_only_update
BEFORE UPDATE ON reconcile_resolution BEGIN SELECT RAISE(ABORT, 'reconcile_resolution append only'); END;
CREATE TRIGGER IF NOT EXISTS reconcile_resolution_append_only_delete
BEFORE DELETE ON reconcile_resolution BEGIN SELECT RAISE(ABORT, 'reconcile_resolution append only'); END;
CREATE TRIGGER IF NOT EXISTS reconcile_resolution_matches_fact
BEFORE INSERT ON reconcile_resolution
WHEN NOT EXISTS (
  SELECT 1 FROM reconcile_fact f WHERE f.operation_id=NEW.operation_id AND
    f.reconcile_round_id=NEW.reconcile_round_id AND f.fact_id=NEW.fact_id AND
    f.evidence_digest=NEW.evidence_digest
)
BEGIN SELECT RAISE(ABORT, 'reconcile resolution evidence mismatch'); END;

CREATE TABLE IF NOT EXISTS queue_lane (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  lane_family TEXT NOT NULL CHECK (length(CAST(lane_family AS BLOB)) BETWEEN 1 AND 128),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  next_fifo_ordinal INTEGER NOT NULL CHECK (next_fifo_ordinal BETWEEN 0 AND 9007199254740991),
  active_count INTEGER NOT NULL CHECK (active_count BETWEEN 0 AND 16),
  capacity INTEGER NOT NULL CHECK (capacity BETWEEN 1 AND 16),
  updated_at INTEGER NOT NULL CHECK (updated_at > 0),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, lane_family
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
) STRICT;

CREATE TABLE IF NOT EXISTS queue_entry (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  lane_family TEXT NOT NULL,
  queue_entry_id TEXT NOT NULL CHECK (length(CAST(queue_entry_id AS BLOB)) BETWEEN 1 AND 256),
  root_operation_id TEXT NOT NULL,
  fifo_ordinal INTEGER NOT NULL CHECK (fifo_ordinal BETWEEN 0 AND 9007199254740991),
  entry_revision INTEGER NOT NULL CHECK (entry_revision >= 1),
  state TEXT NOT NULL CHECK (state IN ('QUEUED', 'DISPATCH_RESERVED', 'CONSUMED', 'CANCELLED')),
  payload_digest TEXT NOT NULL CHECK (
    length(payload_digest) = 64 AND payload_digest NOT GLOB '*[^0-9a-f]*'
  ),
  payload_json TEXT NOT NULL CHECK (
    json_valid(payload_json) AND json_type(payload_json) = 'object' AND
    length(CAST(payload_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  updated_at INTEGER NOT NULL CHECK (updated_at > 0),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    lane_family, queue_entry_id
  ),
  UNIQUE (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    lane_family, fifo_ordinal
  ),
  FOREIGN KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, lane_family
  ) REFERENCES queue_lane (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id, lane_family
  ),
  FOREIGN KEY (root_operation_id) REFERENCES operation (operation_id)
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS queue_entry_one_active_per_root
ON queue_entry (root_operation_id)
WHERE state IN ('QUEUED', 'DISPATCH_RESERVED');

CREATE TRIGGER IF NOT EXISTS queue_entry_root_scope_insert
BEFORE INSERT ON queue_entry
WHEN NOT EXISTS (
  SELECT 1 FROM operation o WHERE o.operation_id=NEW.root_operation_id AND
    o.bridge_identity_id=NEW.bridge_identity_id AND o.bridge_instance_id=NEW.bridge_instance_id AND
    o.codex_source_id=NEW.codex_source_id AND o.provider_thread_id=NEW.provider_thread_id
)
BEGIN SELECT RAISE(ABORT, 'queue root source/thread mismatch'); END;

CREATE TRIGGER IF NOT EXISTS queue_entry_aggregate_insert
BEFORE INSERT ON queue_entry
WHEN NOT EXISTS (
  SELECT 1 FROM operation o JOIN queue_lane l ON
    l.bridge_identity_id=NEW.bridge_identity_id AND l.bridge_instance_id=NEW.bridge_instance_id AND
    l.codex_source_id=NEW.codex_source_id AND l.provider_thread_id=NEW.provider_thread_id AND
    l.lane_family=NEW.lane_family
  WHERE o.operation_id=NEW.root_operation_id AND o.state='QUEUED' AND NEW.state='QUEUED' AND
    l.active_count=(
      SELECT COUNT(*) FROM queue_entry q WHERE
        q.bridge_identity_id=NEW.bridge_identity_id AND q.bridge_instance_id=NEW.bridge_instance_id AND
        q.codex_source_id=NEW.codex_source_id AND q.provider_thread_id=NEW.provider_thread_id AND
        q.lane_family=NEW.lane_family AND q.state='QUEUED'
    )
)
BEGIN SELECT RAISE(ABORT, 'queue insert aggregate mismatch'); END;

CREATE TRIGGER IF NOT EXISTS queue_entry_safe_transition
BEFORE UPDATE OF state ON queue_entry
WHEN NOT (
  (OLD.state = 'QUEUED' AND NEW.state IN ('DISPATCH_RESERVED', 'CANCELLED')) OR
  (OLD.state = 'DISPATCH_RESERVED' AND NEW.state = 'CONSUMED')
)
BEGIN
  SELECT RAISE(ABORT, 'queue entry invalid state transition');
END;

CREATE TRIGGER IF NOT EXISTS queue_entry_terminal_immutable
BEFORE UPDATE ON queue_entry
WHEN OLD.state IN ('CONSUMED', 'CANCELLED')
BEGIN
  SELECT RAISE(ABORT, 'queue entry terminal state is immutable');
END;

CREATE TRIGGER IF NOT EXISTS queue_entry_identity_immutable
BEFORE UPDATE ON queue_entry
WHEN OLD.bridge_identity_id != NEW.bridge_identity_id OR
     OLD.bridge_instance_id != NEW.bridge_instance_id OR
     OLD.codex_source_id != NEW.codex_source_id OR
     OLD.provider_thread_id != NEW.provider_thread_id OR
     OLD.lane_family != NEW.lane_family OR OLD.queue_entry_id != NEW.queue_entry_id OR
     OLD.root_operation_id != NEW.root_operation_id OR OLD.fifo_ordinal != NEW.fifo_ordinal OR
     (OLD.state = 'DISPATCH_RESERVED' AND
       (OLD.payload_digest != NEW.payload_digest OR OLD.payload_json != NEW.payload_json))
BEGIN
  SELECT RAISE(ABORT, 'queue entry immutable identity violation');
END;

CREATE TRIGGER IF NOT EXISTS queue_entry_revision_coupling
BEFORE UPDATE ON queue_entry
WHEN NEW.entry_revision != OLD.entry_revision + 1 OR
     (NEW.state = OLD.state AND (
       OLD.state != 'QUEUED' OR
       (NEW.payload_digest = OLD.payload_digest AND NEW.payload_json = OLD.payload_json)
     ))
BEGIN
  SELECT RAISE(ABORT, 'queue entry revision/payload coupling violation');
END;

CREATE TRIGGER IF NOT EXISTS queue_entry_aggregate_update
BEFORE UPDATE ON queue_entry
WHEN NOT EXISTS (
  SELECT 1 FROM operation o JOIN queue_lane l ON
    l.bridge_identity_id=NEW.bridge_identity_id AND l.bridge_instance_id=NEW.bridge_instance_id AND
    l.codex_source_id=NEW.codex_source_id AND l.provider_thread_id=NEW.provider_thread_id AND
    l.lane_family=NEW.lane_family
  WHERE o.operation_id=NEW.root_operation_id AND (
    (NEW.state='QUEUED' AND o.state='QUEUED' AND l.active_count=(
      SELECT COUNT(*) FROM queue_entry q WHERE
        q.bridge_identity_id=NEW.bridge_identity_id AND q.bridge_instance_id=NEW.bridge_instance_id AND
        q.codex_source_id=NEW.codex_source_id AND q.provider_thread_id=NEW.provider_thread_id AND
        q.lane_family=NEW.lane_family AND q.state='QUEUED'
    )) OR
    (NEW.state='DISPATCH_RESERVED' AND o.state='CALL_STARTED' AND l.active_count=(
      SELECT COUNT(*) FROM queue_entry q WHERE
        q.bridge_identity_id=NEW.bridge_identity_id AND q.bridge_instance_id=NEW.bridge_instance_id AND
        q.codex_source_id=NEW.codex_source_id AND q.provider_thread_id=NEW.provider_thread_id AND
        q.lane_family=NEW.lane_family AND q.state='QUEUED'
    )) OR
    (NEW.state='CANCELLED' AND o.state='CANCELLED' AND l.active_count=(
      SELECT COUNT(*) FROM queue_entry q WHERE
        q.bridge_identity_id=NEW.bridge_identity_id AND q.bridge_instance_id=NEW.bridge_instance_id AND
        q.codex_source_id=NEW.codex_source_id AND q.provider_thread_id=NEW.provider_thread_id AND
        q.lane_family=NEW.lane_family AND q.state='QUEUED'
    )) OR
    (NEW.state='CONSUMED' AND o.state IN ('PROVIDER_ACCEPTED','REJECTED','OUTCOME_UNKNOWN') AND
      l.active_count=(
        SELECT COUNT(*) FROM queue_entry q WHERE
          q.bridge_identity_id=NEW.bridge_identity_id AND q.bridge_instance_id=NEW.bridge_instance_id AND
          q.codex_source_id=NEW.codex_source_id AND q.provider_thread_id=NEW.provider_thread_id AND
          q.lane_family=NEW.lane_family AND q.state='QUEUED'
      ))
  )
)
BEGIN SELECT RAISE(ABORT, 'queue update aggregate mismatch'); END;

CREATE TRIGGER IF NOT EXISTS queue_entry_no_delete
BEFORE DELETE ON queue_entry
BEGIN SELECT RAISE(ABORT, 'queue entries are durable and cannot be deleted'); END;

CREATE TRIGGER IF NOT EXISTS queue_lane_initial_shape
BEFORE INSERT ON queue_lane
WHEN NEW.revision!=1 OR NEW.next_fifo_ordinal!=0 OR NEW.active_count!=0
BEGIN SELECT RAISE(ABORT, 'queue lane initial shape is invalid'); END;

CREATE TRIGGER IF NOT EXISTS queue_lane_identity_immutable
BEFORE UPDATE ON queue_lane
WHEN OLD.bridge_identity_id!=NEW.bridge_identity_id OR OLD.bridge_instance_id!=NEW.bridge_instance_id OR
     OLD.codex_source_id!=NEW.codex_source_id OR OLD.provider_thread_id!=NEW.provider_thread_id OR
     OLD.lane_family!=NEW.lane_family OR OLD.capacity!=NEW.capacity
BEGIN SELECT RAISE(ABORT, 'queue lane immutable identity violation'); END;

CREATE TRIGGER IF NOT EXISTS queue_lane_revision_aggregate_coupling
BEFORE UPDATE ON queue_lane
WHEN NEW.revision!=OLD.revision+1 OR
     NEW.next_fifo_ordinal NOT IN (OLD.next_fifo_ordinal, OLD.next_fifo_ordinal+1) OR
     NEW.active_count < OLD.active_count-1 OR NEW.active_count > OLD.active_count+1 OR
     NEW.active_count!=(
       SELECT COUNT(*) FROM queue_entry q WHERE
         q.bridge_identity_id=NEW.bridge_identity_id AND q.bridge_instance_id=NEW.bridge_instance_id AND
         q.codex_source_id=NEW.codex_source_id AND q.provider_thread_id=NEW.provider_thread_id AND
         q.lane_family=NEW.lane_family AND q.state='QUEUED'
     ) OR
     (NEW.next_fifo_ordinal=OLD.next_fifo_ordinal+1 AND NEW.active_count!=OLD.active_count+1)
BEGIN SELECT RAISE(ABORT, 'queue lane revision/aggregate coupling violation'); END;

CREATE TRIGGER IF NOT EXISTS queue_lane_no_delete
BEFORE DELETE ON queue_lane
BEGIN SELECT RAISE(ABORT, 'queue lanes are durable and cannot be deleted'); END;

CREATE TABLE IF NOT EXISTS interaction (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  provider_turn_id TEXT NOT NULL CHECK (length(CAST(provider_turn_id AS BLOB)) BETWEEN 1 AND 256),
  interaction_id TEXT NOT NULL CHECK (length(CAST(interaction_id AS BLOB)) BETWEEN 1 AND 256),
  connection_generation INTEGER NOT NULL CHECK (connection_generation >= 0),
  provider_generation INTEGER NOT NULL CHECK (provider_generation >= 0),
  source_epoch_json TEXT NOT NULL CHECK (
    json_valid(source_epoch_json) AND json_type(source_epoch_json) = 'object' AND
    length(CAST(source_epoch_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  provider_request_id TEXT NOT NULL CHECK (length(CAST(provider_request_id AS BLOB)) BETWEEN 1 AND 256),
  variant TEXT NOT NULL CHECK (variant IN ('APPROVAL', 'QUESTION', 'MCP_ELICITATION', 'EXIT_PLAN')),
  state TEXT NOT NULL CHECK (state IN (
    'OPEN_UNCLAIMED', 'CLAIMED', 'RESPONDING', 'RESOLVED', 'EXPIRED', 'WITHDRAWN'
  )),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  expires_at INTEGER NOT NULL CHECK (expires_at BETWEEN 1 AND 9007199254740991),
  descriptor_json TEXT NOT NULL CHECK (
    json_valid(descriptor_json) AND json_type(descriptor_json) = 'object' AND
    length(CAST(descriptor_json AS BLOB)) BETWEEN 2 AND 65536
  ),
  response_fingerprint TEXT CHECK (
    response_fingerprint IS NULL OR
    (length(response_fingerprint) = 64 AND response_fingerprint NOT GLOB '*[^0-9a-f]*')
  ),
  response_operation_id TEXT,
  response_actor_id TEXT,
  response_json TEXT CHECK (
    response_json IS NULL OR
    (json_valid(response_json) AND json_type(response_json) = 'object' AND
     length(CAST(response_json AS BLOB)) BETWEEN 2 AND 65536)
  ),
  resolution_evidence_digest TEXT CHECK (
    resolution_evidence_digest IS NULL OR
    (length(resolution_evidence_digest) = 64 AND resolution_evidence_digest NOT GLOB '*[^0-9a-f]*')
  ),
  updated_at INTEGER NOT NULL CHECK (updated_at > 0),
  CHECK (
    state NOT IN ('RESPONDING', 'RESOLVED') OR
    (response_fingerprint IS NOT NULL AND response_operation_id IS NOT NULL AND
     response_actor_id IS NOT NULL AND response_json IS NOT NULL)
  ),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    provider_turn_id, interaction_id
  ),
  UNIQUE (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    provider_turn_id, provider_request_id
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id),
  FOREIGN KEY (response_operation_id) REFERENCES operation (operation_id)
) STRICT;

CREATE TRIGGER IF NOT EXISTS interaction_safe_transition
BEFORE UPDATE OF state ON interaction
WHEN NOT (
  (OLD.state = 'OPEN_UNCLAIMED' AND NEW.state IN ('CLAIMED', 'EXPIRED', 'WITHDRAWN')) OR
  (OLD.state = 'CLAIMED' AND NEW.state IN ('OPEN_UNCLAIMED', 'RESPONDING', 'EXPIRED', 'WITHDRAWN')) OR
  (OLD.state = 'RESPONDING' AND NEW.state = 'RESOLVED')
)
BEGIN
  SELECT RAISE(ABORT, 'interaction invalid state transition');
END;

CREATE TRIGGER IF NOT EXISTS interaction_terminal_immutable
BEFORE UPDATE ON interaction
WHEN OLD.state IN ('RESOLVED', 'EXPIRED', 'WITHDRAWN')
BEGIN
  SELECT RAISE(ABORT, 'interaction terminal state is immutable');
END;

CREATE TRIGGER IF NOT EXISTS interaction_identity_immutable
BEFORE UPDATE ON interaction
WHEN OLD.bridge_identity_id != NEW.bridge_identity_id OR
     OLD.bridge_instance_id != NEW.bridge_instance_id OR OLD.codex_source_id != NEW.codex_source_id OR
     OLD.provider_thread_id != NEW.provider_thread_id OR OLD.provider_turn_id != NEW.provider_turn_id OR
     OLD.interaction_id != NEW.interaction_id OR OLD.connection_generation != NEW.connection_generation OR
     OLD.provider_generation != NEW.provider_generation OR OLD.source_epoch_json != NEW.source_epoch_json OR
     OLD.provider_request_id != NEW.provider_request_id OR OLD.variant != NEW.variant OR
     OLD.expires_at != NEW.expires_at OR OLD.descriptor_json != NEW.descriptor_json
BEGIN
  SELECT RAISE(ABORT, 'interaction immutable identity violation');
END;

CREATE TRIGGER IF NOT EXISTS interaction_revision_coupling
BEFORE UPDATE ON interaction
WHEN NEW.revision != OLD.revision + 1
BEGIN SELECT RAISE(ABORT, 'interaction revision coupling violation'); END;

CREATE TRIGGER IF NOT EXISTS interaction_leaving_claimed_requires_consumed_claim
BEFORE UPDATE OF state ON interaction
WHEN OLD.state='CLAIMED' AND NEW.state!='CLAIMED' AND EXISTS (
  SELECT 1 FROM interaction_claim c WHERE
    c.bridge_identity_id=OLD.bridge_identity_id AND c.bridge_instance_id=OLD.bridge_instance_id AND
    c.codex_source_id=OLD.codex_source_id AND c.provider_thread_id=OLD.provider_thread_id AND
    c.provider_turn_id=OLD.provider_turn_id AND c.interaction_id=OLD.interaction_id AND c.state='ACTIVE'
)
BEGIN SELECT RAISE(ABORT, 'claimed interaction still has an active claim'); END;

CREATE TRIGGER IF NOT EXISTS interaction_no_delete
BEFORE DELETE ON interaction
BEGIN SELECT RAISE(ABORT, 'interactions are durable and cannot be deleted'); END;

CREATE TABLE IF NOT EXISTS interaction_claim (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  provider_turn_id TEXT NOT NULL,
  interaction_id TEXT NOT NULL,
  claim_id TEXT NOT NULL CHECK (length(CAST(claim_id AS BLOB)) BETWEEN 1 AND 256),
  actor_id TEXT NOT NULL CHECK (length(CAST(actor_id AS BLOB)) BETWEEN 1 AND 256),
  token_hash TEXT NOT NULL CHECK (
    length(token_hash) = 64 AND token_hash NOT GLOB '*[^0-9a-f]*'
  ),
  expires_at INTEGER NOT NULL CHECK (expires_at BETWEEN 1 AND 9007199254740991),
  state TEXT NOT NULL CHECK (state IN ('ACTIVE', 'CONSUMED', 'RELEASED', 'EXPIRED', 'REVOKED')),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  updated_at INTEGER NOT NULL CHECK (updated_at > 0),
  PRIMARY KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    provider_turn_id, interaction_id, claim_id
  ),
  FOREIGN KEY (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    provider_turn_id, interaction_id
  ) REFERENCES interaction (
    bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
    provider_turn_id, interaction_id
  )
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS interaction_claim_one_active
ON interaction_claim (
  bridge_identity_id, bridge_instance_id, codex_source_id, provider_thread_id,
  provider_turn_id, interaction_id
)
WHERE state = 'ACTIVE';

CREATE TRIGGER IF NOT EXISTS interaction_claim_active_owner_insert
BEFORE INSERT ON interaction_claim
WHEN NEW.state='ACTIVE' AND NOT EXISTS (
  SELECT 1 FROM interaction i WHERE
    i.bridge_identity_id=NEW.bridge_identity_id AND i.bridge_instance_id=NEW.bridge_instance_id AND
    i.codex_source_id=NEW.codex_source_id AND i.provider_thread_id=NEW.provider_thread_id AND
    i.provider_turn_id=NEW.provider_turn_id AND i.interaction_id=NEW.interaction_id AND i.state='CLAIMED'
)
BEGIN SELECT RAISE(ABORT, 'active claim requires claimed interaction'); END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_active_owner_update
BEFORE UPDATE ON interaction_claim
WHEN NEW.state='ACTIVE' AND NOT EXISTS (
  SELECT 1 FROM interaction i WHERE
    i.bridge_identity_id=NEW.bridge_identity_id AND i.bridge_instance_id=NEW.bridge_instance_id AND
    i.codex_source_id=NEW.codex_source_id AND i.provider_thread_id=NEW.provider_thread_id AND
    i.provider_turn_id=NEW.provider_turn_id AND i.interaction_id=NEW.interaction_id AND i.state='CLAIMED'
)
BEGIN SELECT RAISE(ABORT, 'active claim requires claimed interaction'); END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_expiry_within_interaction_insert
BEFORE INSERT ON interaction_claim
WHEN NOT EXISTS (
  SELECT 1 FROM interaction i WHERE
    i.bridge_identity_id=NEW.bridge_identity_id AND i.bridge_instance_id=NEW.bridge_instance_id AND
    i.codex_source_id=NEW.codex_source_id AND i.provider_thread_id=NEW.provider_thread_id AND
    i.provider_turn_id=NEW.provider_turn_id AND i.interaction_id=NEW.interaction_id AND
    NEW.expires_at<=i.expires_at
)
BEGIN SELECT RAISE(ABORT, 'claim expiry exceeds interaction expiry'); END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_expiry_within_interaction_update
BEFORE UPDATE OF expires_at, state ON interaction_claim
WHEN NOT EXISTS (
  SELECT 1 FROM interaction i WHERE
    i.bridge_identity_id=NEW.bridge_identity_id AND i.bridge_instance_id=NEW.bridge_instance_id AND
    i.codex_source_id=NEW.codex_source_id AND i.provider_thread_id=NEW.provider_thread_id AND
    i.provider_turn_id=NEW.provider_turn_id AND i.interaction_id=NEW.interaction_id AND
    NEW.expires_at<=i.expires_at
)
BEGIN SELECT RAISE(ABORT, 'claim expiry exceeds interaction expiry'); END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_safe_transition
BEFORE UPDATE OF state ON interaction_claim
WHEN NOT (
  OLD.state = 'ACTIVE' AND NEW.state IN ('CONSUMED', 'RELEASED', 'EXPIRED', 'REVOKED')
)
BEGIN
  SELECT RAISE(ABORT, 'interaction claim invalid state transition');
END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_terminal_immutable
BEFORE UPDATE ON interaction_claim
WHEN OLD.state IN ('CONSUMED', 'RELEASED', 'EXPIRED', 'REVOKED')
BEGIN
  SELECT RAISE(ABORT, 'interaction claim terminal state is immutable');
END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_identity_immutable
BEFORE UPDATE ON interaction_claim
WHEN OLD.bridge_identity_id != NEW.bridge_identity_id OR
     OLD.bridge_instance_id != NEW.bridge_instance_id OR OLD.codex_source_id != NEW.codex_source_id OR
     OLD.provider_thread_id != NEW.provider_thread_id OR OLD.provider_turn_id != NEW.provider_turn_id OR
     OLD.interaction_id != NEW.interaction_id OR OLD.claim_id != NEW.claim_id OR
     OLD.actor_id != NEW.actor_id OR OLD.token_hash != NEW.token_hash
BEGIN
  SELECT RAISE(ABORT, 'interaction claim immutable identity violation');
END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_revision_coupling
BEFORE UPDATE ON interaction_claim
WHEN NEW.revision != OLD.revision + 1 OR
     (NEW.state = OLD.state AND (OLD.state != 'ACTIVE' OR NEW.expires_at = OLD.expires_at))
BEGIN SELECT RAISE(ABORT, 'interaction claim revision coupling violation'); END;

CREATE TRIGGER IF NOT EXISTS interaction_claim_no_delete
BEFORE DELETE ON interaction_claim
BEGIN SELECT RAISE(ABORT, 'interaction claims are durable and cannot be deleted'); END;
`;
