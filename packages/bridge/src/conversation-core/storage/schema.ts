export const CONVERSATION_CORE_SCHEMA_VERSION = 1;

export const CONVERSATION_CORE_TABLES = [
  "meta",
  "source_partition",
  "timeline_head",
  "timeline_item",
  "timeline_gap",
  "operation",
  "operation_event",
  "queue_lane",
  "queue_entry",
  "interaction",
  "interaction_claim",
] as const;

export const CONVERSATION_CORE_DDL = `
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS source_partition (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_head (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  content_revision INTEGER NOT NULL CHECK (content_revision >= 0),
  materialization_id TEXT,
  health TEXT NOT NULL CHECK (health IN ('HEALTHY', 'DEGRADED')),
  health_problem_json TEXT,
  metadata_json TEXT,
  item_count INTEGER NOT NULL CHECK (item_count >= 0),
  gap_count INTEGER NOT NULL CHECK (gap_count >= 0),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
    ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_item (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  provider_turn_id TEXT NOT NULL,
  item_ordinal INTEGER NOT NULL CHECK (item_ordinal >= 0),
  item_kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    item_id
  ),
  UNIQUE (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    item_ordinal
  ),
  FOREIGN KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ) REFERENCES timeline_head (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS timeline_gap (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  gap_id TEXT NOT NULL,
  gap_ordinal INTEGER NOT NULL CHECK (gap_ordinal >= 0),
  reason TEXT NOT NULL,
  descriptor_json TEXT NOT NULL,
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    gap_id
  ),
  UNIQUE (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    gap_ordinal
  ),
  FOREIGN KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ) REFERENCES timeline_head (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS operation (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  client_message_id TEXT NOT NULL,
  operation_id TEXT NOT NULL UNIQUE,
  fingerprint TEXT NOT NULL,
  dispatch_attempt_id TEXT UNIQUE,
  provider_turn_id TEXT,
  state TEXT NOT NULL CHECK (state IN (
    'ADMITTED',
    'QUEUED',
    'DISPATCHING',
    'PROVIDER_ACCEPTED',
    'CANONICAL_OBSERVED',
    'REJECTED',
    'CANCELLED',
    'OUTCOME_UNKNOWN',
    'RECONCILE_REQUIRED'
  )),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  canonical_observed INTEGER NOT NULL CHECK (canonical_observed IN (0, 1)),
  reconcile_required INTEGER NOT NULL CHECK (reconcile_required IN (0, 1)),
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  dispatch_started_at INTEGER,
  provider_accepted_at INTEGER,
  canonical_observed_at INTEGER,
  updated_at INTEGER NOT NULL,
  CHECK (provider_turn_id IS NULL OR dispatch_attempt_id IS NOT NULL),
  CHECK (provider_accepted_at IS NULL OR provider_turn_id IS NOT NULL),
  CHECK (canonical_observed = 0 OR (
    provider_turn_id IS NOT NULL AND canonical_observed_at IS NOT NULL
  )),
  CHECK (state != 'DISPATCHING' OR dispatch_attempt_id IS NOT NULL),
  CHECK (state != 'PROVIDER_ACCEPTED' OR provider_turn_id IS NOT NULL),
  CHECK (state != 'CANONICAL_OBSERVED' OR provider_turn_id IS NOT NULL),
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    client_message_id
  ),
  UNIQUE (
    operation_id,
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
    ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS operation_event (
  operation_id TEXT NOT NULL,
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  event_sequence INTEGER NOT NULL CHECK (event_sequence >= 1),
  from_state TEXT,
  to_state TEXT NOT NULL,
  event_kind TEXT NOT NULL,
  dispatch_attempt_id TEXT,
  provider_turn_id TEXT,
  details_json TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (operation_id, event_sequence),
  FOREIGN KEY (
    operation_id,
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ) REFERENCES operation (
    operation_id,
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS queue_lane (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  lane_family TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  next_fifo_ordinal INTEGER NOT NULL CHECK (next_fifo_ordinal >= 0),
  active_count INTEGER NOT NULL CHECK (active_count >= 0),
  capacity INTEGER NOT NULL CHECK (capacity BETWEEN 1 AND 16),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    lane_family
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
    ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS queue_entry (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  lane_family TEXT NOT NULL,
  queue_entry_id TEXT NOT NULL,
  root_operation_id TEXT NOT NULL,
  fifo_ordinal INTEGER NOT NULL CHECK (fifo_ordinal >= 0),
  entry_revision INTEGER NOT NULL CHECK (entry_revision >= 1),
  state TEXT NOT NULL CHECK (state IN (
    'QUEUED', 'EDITED', 'DISPATCH_OWNED', 'CONSUMED', 'CANCELLED'
  )),
  payload_digest TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    lane_family,
    queue_entry_id
  ),
  UNIQUE (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    lane_family,
    fifo_ordinal
  ),
  FOREIGN KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    lane_family
  ) REFERENCES queue_lane (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    lane_family
  ) ON DELETE CASCADE,
  FOREIGN KEY (
    root_operation_id,
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  ) REFERENCES operation (
    operation_id,
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id
  )
) STRICT;

CREATE TABLE IF NOT EXISTS interaction (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  provider_turn_id TEXT NOT NULL,
  interaction_id TEXT NOT NULL,
  provider_request_id TEXT NOT NULL,
  variant TEXT NOT NULL CHECK (variant IN ('APPROVAL', 'QUESTION', 'MCP', 'EXIT_PLAN')),
  state TEXT NOT NULL CHECK (state IN (
    'OPEN_UNCLAIMED',
    'OPEN_CLAIMED',
    'RESPONSE_PENDING',
    'RESOLVED',
    'WITHDRAWN',
    'STALE',
    'EXPIRED'
  )),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  descriptor_json TEXT NOT NULL,
  response_fingerprint TEXT,
  response_operation_id TEXT,
  response_actor_id TEXT,
  response_json TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    provider_turn_id,
    interaction_id
  ),
  UNIQUE (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    provider_turn_id,
    provider_request_id
  ),
  FOREIGN KEY (bridge_identity_id, bridge_instance_id, codex_source_id)
    REFERENCES source_partition (bridge_identity_id, bridge_instance_id, codex_source_id)
    ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS interaction_claim (
  bridge_identity_id TEXT NOT NULL,
  bridge_instance_id TEXT NOT NULL,
  codex_source_id TEXT NOT NULL,
  provider_thread_id TEXT NOT NULL,
  provider_turn_id TEXT NOT NULL,
  interaction_id TEXT NOT NULL,
  claim_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('ACTIVE', 'RELEASED', 'EXPIRED')),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    provider_turn_id,
    interaction_id,
    claim_id
  ),
  FOREIGN KEY (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    provider_turn_id,
    interaction_id
  ) REFERENCES interaction (
    bridge_identity_id,
    bridge_instance_id,
    codex_source_id,
    provider_thread_id,
    provider_turn_id,
    interaction_id
  ) ON DELETE CASCADE
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS interaction_claim_one_active
ON interaction_claim (
  bridge_identity_id,
  bridge_instance_id,
  codex_source_id,
  provider_thread_id,
  provider_turn_id,
  interaction_id
)
WHERE state = 'ACTIVE';
`;
