#!/usr/bin/env python3
"""Read-only static validator for the CC Pocket Codex Kernel v4 design."""

from __future__ import annotations

import argparse
import csv
import datetime
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


REPORT_FORMAT_VERSION = 1
PASS = "PASS"
FAIL = "FAIL"
NOT_RUN = "NOT_RUN"
MISSING = "FAIL_MISSING_ARTIFACT"

CANONICAL_SOURCE_PARTITION = (
    "bridgeIdentityId",
    "bridgeInstanceId",
    "codexSourceId",
)
CANONICAL_OPERATION_KEY = ("SourcePartition", "operationId")

FIXED_TABLE_SHAPES = {
    "matrices/BASELINE-DISPOSITION.csv": (30, 10),
    "matrices/USER-DECISION-REQUIRED.csv": (9, 8),
    "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv": (37, 22),
    "drafts/P1-OPERATION-STATE-MATRIX.csv": (38, 24),
    "drafts/K-CAPABILITY-COMPLETION.csv": (26, 19),
    "drafts/P2-CAPABILITY-P001-P013.csv": (13, 17),
    "drafts/P2-CAPABILITY-P014-P026.csv": (13, 14),
    "drafts/SOURCE-REUSE-DISPOSITION.csv": (52, 9),
    "drafts/AUDIT-COVERAGE-CLOSURE.csv": (112, 9),
    "drafts/EXPERIMENT-AND-GATE-MATRIX.csv": (28, 12),
}
FIXED_FINAL_EXACT_COLUMNS = {
    "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv": 22,
    "drafts/P1-OPERATION-STATE-MATRIX.csv": 27,
    "drafts/K-CAPABILITY-COMPLETION.csv": 23,
}
FIXED_FINAL_HEADERS = {
    "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv": (
        "row_id", "semantic_or_contract", "category", "baseline_disposition",
        "definition", "unique_owner", "execution_location", "authority_identity",
        "scope_fence", "durability", "states", "typed_errors", "capacity_or_bound",
        "unknown_behavior", "required_interface", "ddl_pressure", "wire_pressure",
        "failure_vector", "source_locations", "evidence_level", "change_cost",
        "phase1_status",
    ),
    "drafts/P1-OPERATION-STATE-MATRIX.csv": (
        "mutation_id", "typed_variant", "operation_lifecycle_owner", "domain_effect_owner",
        "execution_location", "target_identity", "offline_policy", "admission_fingerprint",
        "queue_policy", "queue_lane_selector", "execution_conflict_selector", "scheduling_class",
        "preconditions", "delivery_policy", "replay_policy", "reconcile_policy",
        "accepted_evidence", "canonical_observation", "terminal_success", "typed_errors",
        "wire_request", "wire_result", "bridge_storage", "mobile_storage",
        "current_source_locations", "phase2_remainder", "fact_status",
    ),
    "drafts/K-CAPABILITY-COMPLETION.csv": (
        "capability_id", "user_visible_effect", "unique_existing_root_owner", "execution_place",
        "current_source_paths", "current_tests", "phase1_contract_refs", "phase2_ui_controller_work",
        "typed_state", "typed_errors", "capacity_and_unknown_behavior", "storage_or_no_storage",
        "data_flow", "deliberate_negative_vector", "acceptance_layers", "rollback_and_disposition",
        "source_presence", "runtime_status", "root_conflict_or_open_decision", "state_machine_refs",
        "feature_local_state_or_view_projection", "view_projection_only", "projection_derivation",
    ),
}
FIXED_FINAL_TABLE_SHAPES = {
    "matrices/RISK-REGISTER.csv": (27, 11),
    "matrices/EXPERIMENT-REGISTRY.csv": (63, 12),
    "matrices/EVIDENCE-ADJUDICATION.csv": (29, 12),
    "matrices/IMPLEMENTATION-WAVES.csv": (19, 17),
    "matrices/DESIGN-CLOSURE.csv": (112, 17),
}
DYNAMIC_FINAL_TABLE_RULES = {
    "drafts/P1-SEMANTIC-DICTIONARY.csv": (26, "SEMANTIC_SUCCESSOR_V1"),
    "drafts/P1-MESSAGE-REGISTRY.csv": (18, "SUPERSEDED_VIEW_V1"),
    "matrices/DECISION-LEDGER.csv": (13, "DECISION_SUCCESSOR_V1"),
    "matrices/AUTHORITY-OWNERSHIP.csv": (14, "AUTHORITY_ORDERED_SET_V1"),
}
FIXED_FINAL_TABLE_COLUMNS = {
    "drafts/P1-SEMANTIC-DICTIONARY.csv": ("semantic_id", "semantic_kind", "term", "definition", "product_effect", "owner", "authority", "identity_key", "scope_and_fence", "writer", "durability", "ordering", "lifecycle_or_allowed_values", "wire_binding", "storage_binding", "unknown_behavior", "capacity", "error_semantics", "acceptance_vectors", "provenance", "semantic_schema_owner", "ref_minter", "byte_backend_owner", "retention_policy_owner", "ticket_issuer", "status"),
    "drafts/P1-MESSAGE-REGISTRY.csv": ("message_kind", "semantic_id", "direction", "envelope_class", "capability_semantic_id", "aggregate_scope", "correlates_with", "delivery_class", "payload_shape", "allowed_problem_codes", "evolution_policy", "operation_registry_id", "exposure", "superseded_by", "queue_policy", "queue_lane_family", "execution_conflict_families", "status"),
    "matrices/RISK-REGISTER.csv": ("risk_id", "category", "trigger", "impact", "preventive_contract", "detection_evidence", "fail_closed_response", "owner", "gate", "residual_risk", "status"),
    "matrices/EXPERIMENT-REGISTRY.csv": ("canonical_id", "category", "scope", "aliases", "question", "bound_build_or_source", "method", "positive_acceptance", "negative_acceptance", "raw_evidence_artifact", "blocks", "status"),
    "matrices/DECISION-LEDGER.csv": ("decision_id", "record_kind", "scope", "statement", "status", "owner", "source_authority", "source_refs", "supersedes", "superseded_by", "affected_artifacts", "implementation_gate", "rollback_or_change_rule"),
    "matrices/EVIDENCE-ADJUDICATION.csv": ("evidence_id", "evidence_kind", "subject", "authority_rank", "identity_or_digest", "location", "fact_status", "can_prove", "cannot_prove", "staleness_rule", "required_recheck_gate", "decision_refs"),
    "matrices/AUTHORITY-OWNERSHIP.csv": ("semantic_id", "authoritative_fact_source", "domain_owner", "sole_writer", "execution_location", "storage_namespace", "read_port", "mutation_port", "publication_port", "forbidden_writers", "state_machine_refs", "capability_refs", "negative_vector", "rollback_boundary"),
    "matrices/IMPLEMENTATION-WAVES.csv": ("stage_id", "objective", "dependencies", "exact_design_inputs", "target_owners", "target_module_paths", "source_disposition_ids", "enter_gate", "implementation_outputs", "static_checks", "fault_vectors", "runtime_checks", "data_policy", "cutover_scope", "rollback_point", "explicitly_not_authorized", "next_gate"),
    "matrices/DESIGN-CLOSURE.csv": ("id", "class", "required_design_artifact", "phase", "closure_rule", "evidence_input", "owner", "expected_failing_test", "current_status", "design_status", "closing_artifacts", "closing_rows_or_sections", "negative_vector", "machine_binding_status", "runtime_status", "remaining_gate", "root_rationale"),
}
FIXED_FINAL_ALLOWED_BLANK_COLUMNS = {
    "drafts/P1-SEMANTIC-DICTIONARY.csv": {
        "semantic_schema_owner", "ref_minter", "byte_backend_owner",
        "retention_policy_owner", "ticket_issuer",
    },
    "drafts/P1-MESSAGE-REGISTRY.csv": {
        "capability_semantic_id", "correlates_with", "allowed_problem_codes",
        "operation_registry_id", "exposure", "superseded_by", "queue_policy",
        "queue_lane_family", "execution_conflict_families",
    },
}
FIXED_FINAL_FILES = {
    "07-DIGEST-AND-DURABLE-EVENT-ALGEBRA.md",
    "drafts/FULL-DESIGN-SYNTHESIS.md",
    "contracts/contract-registry.json",
    "contracts/CONTRACT-MANIFEST.json",
    "contracts/README.md",
    "contracts/tools/validate_contract.py",
    "contracts/vectors/contract-vectors.json",
    "contracts/sql/bridge-v1.sql",
    "contracts/sql/mobile-v1.sql",
    "drafts/P1-SEMANTIC-DICTIONARY.csv",
    "drafts/P1-MESSAGE-REGISTRY.csv",
    "matrices/RISK-REGISTER.csv",
    "matrices/EXPERIMENT-REGISTRY.csv",
    "matrices/DECISION-LEDGER.csv",
    "matrices/EVIDENCE-ADJUDICATION.csv",
    "matrices/AUTHORITY-OWNERSHIP.csv",
    "matrices/IMPLEMENTATION-WAVES.csv",
    "matrices/DESIGN-CLOSURE.csv",
}
FIXED_MACHINE_SOURCE_KEYS = {
    "contract",
    "owners",
    "semantics",
    "capabilities",
    "stateMachines",
    "errorRegistry",
    "limits",
    "messages",
    "operations",
    "ports",
    "contentResponsibilities",
    "contentLineages",
    "featureContributionContract",
    "productCapabilityBindings",
    "featureContributions",
    "laneFamilies",
    "storageArtifacts",
    "sourceRefs",
    "capabilitySnapshotContract",
    "fingerprintPolicy",
    "featureHostOwnerBindings",
    "storageNamespaces",
    "expectedSoleWriterInventory",
    "decoderContract",
    "admissionPolicy",
    "featureHostResolution",
    "stateMachineBindings",
    "materializationVerifier",
    "featureHostCoverage",
    "expectedOperationRefs",
    "numericTypeInventory",
    "settingsContract",
    "durableEventContract",
    "expectedAggregateEventInventory",
    "executableRuleInventory",
}
FIXED_OPERATION_SLOTS = tuple(
    [f"OP-{index:03d}" for index in range(1, 40)]
    + [f"PX-{index:03d}" for index in range(1, 31)]
)
FIXED_LANE_INVENTORY = (
    "THREAD_PROVIDER",
    "THREAD_STATE",
    "INTERACTION",
    "SOURCE_POLICY",
    "BRIDGE_TRUST",
    "RUNTIME_SESSION",
    "CONTENT_OFFER",
    "TRANSFER",
    "FILE_ROOT",
    "GALLERY",
    "GIT_WORKSPACE",
    "CAPTURE_SCOPE",
)
FEATURE_HOST_KINDS = {
    "BRIDGE",
    "MOBILE",
    "NATIVE_IOS",
    "NATIVE_ANDROID",
}
FEATURE_CAPABILITY_ROLES = {
    "AUTHORITY",
    "ADAPTER",
    "REPLICA",
    "PRESENTATION",
    "NATIVE_HOST",
}
FEATURE_LIFECYCLE_KEYS = {
    "start",
    "stop",
    "disconnect",
    "sourceSwitch",
    "hostEpochChange",
    "appBackground",
    "memoryPressure",
}
FIXED_EXPECTED_SOLE_WRITERS = {
    "AutoApprovalPolicyStore": "BRIDGE",
    "CanonicalTimelineWriter": "BRIDGE",
    "ContentReferenceService": "BRIDGE",
    "ConversationCatalogWriter": "BRIDGE",
    "InteractionBroker": "BRIDGE",
    "OperationKernel": "BRIDGE",
    "RelationGraph": "BRIDGE",
    "ReplicaApplyCoordinator": "MOBILE",
    "ThreadState": "BRIDGE",
}
FIXED_NUMERIC_TYPE_INVENTORY = {
    "AggregateRevision1": (
        "operationRevision", "laneRevision", "entryRevision",
        "interactionRevision", "claimRevision", "settingsRevision",
        "goalRevision", "relationRevision", "policyRevision",
        "certificationRevision", "snapshotRevision", "offerRevision",
        "eventRevision", "applyRevision", "checkpointRevision",
        "availabilityRevision", "connectionActorRevision",
        "credentialRevision", "currentRevision", "expectedSettingsRevision",
        "previousGoalRevision", "previousSettingsRevision",
        "redactionPolicyRevision", "trustRevision", "version",
    ),
    "BaseSequence0": ("baseSeq",),
    "BoundEpoch1": (
        "sourceEpoch", "connectionEpoch", "runtimeEpoch", "hostEpoch",
        "lifecycleEpoch", "connectionGeneration", "leaseGeneration",
        "connectionOrLeaseGeneration",
    ),
    "CheckpointSequence0": ("persistedSeq", "checkpointSequence"),
    "HeadVersion0": (
        "headVersion", "baseHeadVersion", "candidateHeadVersion",
        "expectedHeadVersion",
    ),
    "ObjectGeneration1": (
        "objectGeneration", "offerGeneration", "lineageGeneration",
        "runtimeGeneration", "providerRequestGeneration",
        "artifactGeneration", "assetGeneration", "captureGeneration",
        "imageGeneration", "recordingGeneration", "repositoryGeneration",
        "transferGeneration",
    ),
    "Ordinal0": (
        "pageIndex", "blockIndex", "turnOrdinal", "itemOrdinal",
        "islandOrdinal", "segmentOrdinal", "structuralOrdinal",
        "gapCount", "islandCount", "itemCount", "sessionCount",
        "turnCount",
    ),
    "StreamSequence1": ("streamSeq", "commitSeq"),
}
FIXED_SETTINGS_DDL_COLUMNS = (
    "bridge_identity_id", "bridge_instance_id", "codex_source_id",
    "provider_thread_id", "settings_revision", "previous_settings_revision",
    "head_state", "completeness", "model_state", "model_value",
    "effort_state", "effort_value", "service_tier_state",
    "service_tier_value", "approval_policy_state", "approval_policy_json",
    "approvals_reviewer_state", "approvals_reviewer_value",
    "active_permission_profile_state", "active_permission_profile_id",
    "active_permission_profile_extends_id", "sandbox_policy_state",
    "sandbox_policy_json", "collaboration_mode_state",
    "collaboration_mode_value", "collaboration_settings_model",
    "collaboration_effort_state", "collaboration_effort_value",
    "codex_certification_id", "codex_certification_digest",
    "codex_settings_capability_snapshot_id",
    "codex_settings_capability_snapshot_digest", "observed_at",
    "extensions_json", "provenance_digest", "snapshot_digest",
)
FIXED_EXPECTED_OPERATION_REFS = (
    {
        "capabilityId": "P-007",
        "independentSources": [
            "drafts/P2-CAPABILITY-P001-P013.csv#P-007",
            "drafts/P1-OPERATION-STATE-MATRIX.csv#OP-001",
        ],
        "messageKinds": [
            "operation.submit", "operation.query", "operation.state",
            "operation.reconcile",
        ],
        "operationIds": ["OP-001"],
        "protocolCapabilities": ["core.operation.v1"],
    },
    {
        "capabilityId": "P-014",
        "independentSources": [
            "drafts/P2-CAPABILITY-P014-P026.csv#P-014",
            "drafts/P1-OPERATION-STATE-MATRIX.csv#OP-016..OP-022",
        ],
        "messageKinds": [
            "operation.submit", "operation.query", "operation.state",
            "operation.reconcile",
        ],
        "operationIds": [
            "OP-016", "OP-017", "OP-018", "OP-019", "OP-020",
            "OP-021", "OP-022",
        ],
        "protocolCapabilities": ["core.operation.v1"],
    },
    {
        "capabilityId": "P-025",
        "independentSources": [
            "drafts/P2-CAPABILITY-P014-P026.csv#P-025",
            "drafts/P1-OPERATION-STATE-MATRIX.csv#OP-024",
        ],
        "messageKinds": [
            "operation.submit", "operation.query", "operation.state",
            "operation.reconcile",
        ],
        "operationIds": ["OP-024"],
        "protocolCapabilities": ["core.operation.v1"],
    },
)
FIXED_EXPECTED_AGGREGATE_EVENTS = (
    {"aggregate": "operation", "eventTable": "operation_event", "owner": "OperationKernel"},
    {"aggregate": "operation_queue_lane", "eventTable": "operation_queue_lane_event", "owner": "OperationKernel"},
    {"aggregate": "queue_entry", "eventTable": "queue_entry_event", "owner": "OperationKernel"},
    {"aggregate": "interaction", "eventTable": "interaction_event", "owner": "InteractionBroker"},
    {"aggregate": "interaction_claim", "eventTable": "interaction_claim_event", "owner": "InteractionBroker"},
    {"aggregate": "settings_head", "eventTable": "settings_event", "owner": "ThreadState"},
    {"aggregate": "goal_head", "eventTable": "goal_event", "owner": "ThreadState"},
    {"aggregate": "session_relation", "eventTable": "relation_event", "owner": "RelationGraph"},
    {"aggregate": "content_offer", "eventTable": "content_offer_event", "owner": "ContentReferenceService"},
    {"aggregate": "auto_approval_policy", "eventTable": "auto_approval_policy_event", "owner": "AutoApprovalPolicyStore"},
)
FIXED_DURABLE_EVENT_CONTRACT = {
    "blockRule": "begin plus exact pageCount indexed pages plus commit; only whole-block transaction may publish/checkpoint/ACK commitSeq",
    "envelopeSchemaRef": "schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",
    "eventKeySchemaRef": "schema/durable-event.schema.json#/$defs/EventKeyV1",
    "eventProjectionRule": "same EventKey and eventFactDigest may project to multiple distinct MessageKey; same MessageKey is byte immutable",
    "frameMetadata": {
        "derivation": "frameDigest=SHA256(frameCanonicalBytes) after final envelope encoding including messageDigest",
        "fields": ["frameCanonicalBytes", "frameByteLength", "frameDigest"],
        "scope": "STORAGE_TRANSPORT_ONLY",
    },
    "materializationDomains": ["CATALOG", "TIMELINE"],
    "materializationKinds": [
        "materialization.begin", "materialization.page",
        "materialization.commit",
    ],
    "messageDigestExcludedFields": ["messageDigest"],
    "messageDigestPreimageSchemaRef": "schema/durable-event.schema.json#/$defs/EnvelopeMessagePreimageV1",
    "messageKeySchemaRef": "schema/durable-event.schema.json#/$defs/MessageKeyV1",
    "pageCount": {"maximum": 128, "minimum": 0},
    "payloadDigestPreimage": "RFC8785(typed payload)",
    "protocolForbiddenFields": ["frameDigest", "frameByteLength"],
}
FIXED_ERROR_CLASSES = (
    "UNSUPPORTED", "UNAVAILABLE", "TARGET", "AUTHENTICATION", "AUTHORITY",
    "CAPACITY", "INTEGRITY", "CONFLICT", "PROVIDER", "AMBIGUITY",
    "STORAGE", "INTERNAL",
)
FIXED_RETRY_DIRECTIVES = (
    "NEVER", "SAME_REQUEST_LOOKUP", "AFTER_REFRESH", "AFTER_REBIND",
    "READ_RECONCILE_ONLY", "NEW_OPERATION_ONLY", "AFTER_USER_ACTION",
)
FIXED_PROBLEM_FIELDS = {
    "errorClass", "problemCode", "retryDirective", "safeTitle",
    "safeDetail", "subject", "correlationId",
}
FIXED_PROBLEM_REQUIRED_FIELDS = {
    "errorClass", "problemCode", "retryDirective", "safeTitle", "subject",
}
FIXED_DURABLE_MESSAGE_ROUTES = {
    "sync.gap": ("DEVICE_PROJECTION/PAIRED_DEVICE", "sync.repair"),
    "operation.state": (
        "ORIGIN_RECEIPT/ORIGIN_CONNECTION", "operation.receipt"
    ),
    "queue.snapshot": (
        "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "queue.projection"
    ),
    "interaction.state": (
        "DEVICE_PROJECTION/PAIRED_DEVICE", "interaction.projection"
    ),
    "relation.snapshot": (
        "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "relation.projection"
    ),
    "settings.snapshot": (
        "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "thread.settings"
    ),
    "goal.snapshot": (
        "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "thread.goal"
    ),
    "materialization.begin": (
        "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "materialization"
    ),
    "materialization.page": (
        "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "materialization"
    ),
    "materialization.commit": (
        "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "materialization"
    ),
}
FIXED_GENERATED_TARGET_ROOTS = (
    "packages/bridge/src/conversation-core/protocol/generated/",
    "apps/mobile/lib/conversation_core/protocol/generated/",
)
FIXED_EXECUTABLE_RULES = (
    ("MAT_BEGIN_SUBJECT_EQUALITY", "materialization_begin_subject_equality", ("schema/durable-event.schema.json#/$defs/MaterializationBeginPayloadV1",), ("CF-MAT-BEGIN-SUBJECT-POS", "CF-MAT-BEGIN-SUBJECT-NEG")),
    ("MAT_BEGIN_HEAD_SUCCESSOR", "revision_successor", ("schema/durable-event.schema.json#/$defs/MaterializationBeginPayloadV1",), ("CF-MAT-BEGIN-HEAD-POS", "CF-MAT-BEGIN-HEAD-NEG")),
    ("MAT_BEGIN_EMPTY_PROOF", "materialization_begin_empty_proof", ("schema/durable-event.schema.json#/$defs/MaterializationBeginPayloadV1",), ("CF-MAT-BEGIN-EMPTY-POS", "CF-MAT-BEGIN-EMPTY-NEG")),
    ("MAT_BLOCK_MANIFEST_EQUALITY", "materialization_manifest_equality", ("schema/durable-event.schema.json#/$defs/MaterializationBeginPayloadV1",), ("CF-MAT-MANIFEST-POS", "CF-MAT-MANIFEST-NEG")),
    ("MAT_PAGE_INDEX_RANGE", "materialization_page_index", ("schema/durable-event.schema.json#/$defs/MaterializationPagePayloadV1",), ("CF-MAT-PAGE-INDEX-POS", "CF-MAT-PAGE-INDEX-NEG")),
    ("MAT_PAGE_SUBJECT_EQUALITY", "materialization_page_subject_equality", ("schema/durable-event.schema.json#/$defs/MaterializationPagePayloadV1",), ("CF-MAT-PAGE-SUBJECT-POS", "CF-MAT-PAGE-SUBJECT-NEG")),
    ("MAT_PAGE_DIGEST", "canonical_digest", ("schema/durable-event.schema.json#/$defs/MaterializationPagePayloadV1",), ("CF-MAT-PAGE-DIGEST-POS", "CF-MAT-PAGE-DIGEST-NEG")),
    ("MAT_COMMIT_PAGE_COUNT", "materialization_commit_page_count", ("schema/durable-event.schema.json#/$defs/MaterializationCommitPayloadV1",), ("CF-MAT-COMMIT-COUNT-POS", "CF-MAT-COMMIT-COUNT-NEG")),
    ("MAT_COMMIT_EMPTY_RECEIPT", "materialization_commit_empty_receipt", ("schema/durable-event.schema.json#/$defs/MaterializationCommitPayloadV1",), ("CF-MAT-COMMIT-EMPTY-POS", "CF-MAT-COMMIT-EMPTY-NEG")),
    ("MAT_COMMIT_RECEIPT_EQUALITY", "materialization_commit_receipt_equality", ("schema/durable-event.schema.json#/$defs/MaterializationCommitPayloadV1",), ("CF-MAT-COMMIT-RECEIPT-POS", "CF-MAT-COMMIT-RECEIPT-NEG")),
    ("DURABLE_SOURCE_EQUALITY", "durable_source_equality", ("schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",), ("CF-DURABLE-SOURCE-POS", "CF-DURABLE-SOURCE-NEG")),
    ("DURABLE_SEQUENCE_ALGEBRA", "durable_sequence_algebra", ("schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",), ("CF-DURABLE-SEQUENCE-POS", "CF-DURABLE-SEQUENCE-NEG")),
    ("DURABLE_KIND_PAYLOAD", "durable_kind_payload", ("schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",), ("CF-DURABLE-KIND-POS", "CF-DURABLE-KIND-NEG")),
    ("DURABLE_ROUTE_STREAM", "durable_route_stream", ("schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",), ("CF-DURABLE-ROUTE-POS", "CF-DURABLE-ROUTE-NEG")),
    ("DURABLE_PAYLOAD_DIGEST", "durable_payload_digest", ("schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",), ("CF-DURABLE-PAYLOAD-DIGEST-POS", "CF-DURABLE-PAYLOAD-DIGEST-NEG")),
    ("DURABLE_MESSAGE_DIGEST", "durable_message_digest", ("schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",), ("CF-DURABLE-MESSAGE-DIGEST-POS", "CF-DURABLE-MESSAGE-DIGEST-NEG")),
    ("DURABLE_EVENT_MESSAGE_KEY_IMMUTABILITY", "durable_key_immutability", ("schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1",), ("CF-DURABLE-KEY-POS", "CF-DURABLE-KEY-NEG")),
    ("DURABLE_MESSAGE_PREIMAGE", "durable_message_preimage", ("schema/durable-event.schema.json#/$defs/EnvelopeMessagePreimageV1",), ("CF-DURABLE-PREIMAGE-POS", "CF-DURABLE-PREIMAGE-NEG")),
    ("BOUND_ORDER_PROOF_DIGEST", "bound_order_proof_digest", ("schema/domain.schema.json#/$defs/BoundOrderProof",), ("CF-ORDER-PROOF-DIGEST-POS", "CF-ORDER-PROOF-DIGEST-NEG")),
    ("BOUND_ORDER_PROOF_CHAIN", "bound_order_proof_chain", ("schema/domain.schema.json#/$defs/BoundOrderProof",), ("CF-ORDER-PROOF-CHAIN-POS", "CF-ORDER-PROOF-CHAIN-NEG")),
    ("BOUND_ORDER_PROOF_EVIDENCE", "bound_order_proof_evidence", ("schema/domain.schema.json#/$defs/BoundOrderProof",), ("CF-ORDER-PROOF-EVIDENCE-POS", "CF-ORDER-PROOF-EVIDENCE-NEG")),
    ("CATALOG_PAGE_CHAIN", "page_predecessor_chain", ("schema/domain.schema.json#/$defs/CatalogMaterializationPageBodyV1",), ("CF-CATALOG-PAGE-CHAIN-POS", "CF-CATALOG-PAGE-CHAIN-NEG")),
    ("CATALOG_PAGE_DIGEST", "external_page_digest", ("schema/domain.schema.json#/$defs/CatalogMaterializationPageBodyV1",), ("CF-CATALOG-PAGE-DIGEST-POS", "CF-CATALOG-PAGE-DIGEST-NEG")),
    ("MATERIALIZATION_RECEIPT_DIGEST", "materialization_receipt_digest", ("schema/domain.schema.json#/$defs/CatalogMaterializationVerificationReceiptV1", "schema/domain.schema.json#/$defs/TimelineMaterializationVerificationReceiptV1"), ("CF-RECEIPT-DIGEST-POS", "CF-RECEIPT-DIGEST-NEG")),
    ("SETTINGS_VALUE_COMPLETENESS", "settings_value_completeness", ("schema/domain.schema.json#/$defs/SettingsSnapshotValue",), ("CF-SETTINGS-VALUE-POS", "CF-SETTINGS-VALUE-NEG")),
    ("SETTINGS_READBACK_COEXISTENCE", "settings_readback_coexistence", ("schema/domain.schema.json#/$defs/SettingsSnapshotValue",), ("CF-SETTINGS-READBACK-COEXIST-POS", "CF-SETTINGS-READBACK-COEXIST-NEG")),
    ("SETTINGS_REVISION_SUCCESSOR", "settings_revision_successor", ("schema/domain.schema.json#/$defs/SettingsSnapshotPayloadV1",), ("CF-SETTINGS-REVISION-POS", "CF-SETTINGS-REVISION-NEG")),
    ("SETTINGS_PAYLOAD_COMPLETENESS", "settings_payload_completeness", ("schema/domain.schema.json#/$defs/SettingsSnapshotPayloadV1",), ("CF-SETTINGS-COMPLETENESS-POS", "CF-SETTINGS-COMPLETENESS-NEG")),
    ("GOAL_REVISION_SUCCESSOR", "goal_revision_successor", ("schema/domain.schema.json#/$defs/GoalSnapshotPayloadV1",), ("CF-GOAL-REVISION-POS", "CF-GOAL-REVISION-NEG")),
    ("GOAL_USAGE_MONOTONIC", "goal_usage_monotonic", ("schema/domain.schema.json#/$defs/GoalSnapshotPayloadV1",), ("CF-GOAL-USAGE-POS", "CF-GOAL-USAGE-NEG")),
    ("GOAL_REMAINING_FORBIDDEN", "goal_remaining_forbidden", ("schema/domain.schema.json#/$defs/GoalSnapshotPayloadV1",), ("CF-GOAL-REMAINING-POS", "CF-GOAL-REMAINING-NEG")),
    ("TIMELINE_PAGE_CHAIN", "page_predecessor_chain", ("schema/domain.schema.json#/$defs/MaterializationPageBodyV1",), ("CF-TIMELINE-PAGE-CHAIN-POS", "CF-TIMELINE-PAGE-CHAIN-NEG")),
    ("TIMELINE_PAGE_DIGEST", "external_page_digest", ("schema/domain.schema.json#/$defs/MaterializationPageBodyV1",), ("CF-TIMELINE-PAGE-DIGEST-POS", "CF-TIMELINE-PAGE-DIGEST-NEG")),
    ("MATERIALIZATION_RECEIPT_PREIMAGE", "materialization_receipt_preimage", ("schema/domain.schema.json#/$defs/MaterializationReceiptPreimageV1",), ("CF-RECEIPT-PREIMAGE-POS", "CF-RECEIPT-PREIMAGE-NEG")),
    ("OPERATION_STATE_REGISTRY_PAIR", "operation_state_registry_pair", ("schema/messages.schema.json#/$defs/Message_operation_state/properties/payload",), ("CF-OP-STATE-PAIR-POS", "CF-OP-STATE-PAIR-NEG")),
    ("OPERATION_STATE_ATTEMPT_PRESENCE", "operation_state_attempt_presence", ("schema/messages.schema.json#/$defs/Message_operation_state/properties/payload",), ("CF-OP-STATE-ATTEMPT-POS", "CF-OP-STATE-ATTEMPT-NEG")),
    ("OPERATION_STATE_EFFECT_AXIS", "operation_state_effect_axis", ("schema/messages.schema.json#/$defs/Message_operation_state/properties/payload",), ("CF-OP-STATE-EFFECT-POS", "CF-OP-STATE-EFFECT-NEG")),
    ("RESTART_EXPECTED_TURN", "restart_expected_turn", ("schema/operation-union.schema.json#/$defs/Payload_OP_028",), ("CF-RESTART-TURN-POS", "CF-RESTART-TURN-NEG")),
)
FEATURE_DESCRIPTOR_FIELDS = {
    "featureId", "contributionId", "version", "hostKind", "executionOwnerRef",
    "coveredCapabilityRoles", "dependencies", "ownerRefs", "soleWriterRefs",
    "ports", "operationIds", "messageKinds", "storageNamespaceRefs",
    "capabilityStatePolicy", "targetKinds", "lifecycle", "limits",
    "diagnostics", "uiSlots", "activationKey", "rollbackBoundary",
}
REQUIRED_SQL_VECTOR_IDS = {
    "FV-SQL-DUAL-ACTIVE-CLAIM",
    "FV-SQL-CROSS-SOURCE-TRUST",
    "FV-SQL-ATOMIC-MULTI-CLAIM",
    "FV-SQL-QUEUE-STALE-CAS",
    "FV-SQL-QUEUE-DOUBLE-DISPATCH",
    "FV-SQL-CALL-STARTED-REDISPATCH",
    "FV-SQL-EPHEMERAL-DURABLE",
    "FV-SQL-DRAFT-CASCADE",
    "FV-SQL-AUTO-APPROVAL-POLICY-SKIP",
    "FV-SQL-AUTO-APPROVAL-POLICY-BAD-FIRST",
    "FV-SQL-AUTO-APPROVAL-UNKNOWN-POLICY",
    "FV-SQL-CHECKPOINT-BEFORE-READBACK",
    "FV-SQL-UINT64-OVERFLOW",
    "FV-SQL-UTF8-BYTE-LIMIT",
    "FV-RECEIVE-LAST-GOOD-PARTIAL",
    "FV-RECEIVE-DUPLICATE-PAGE",
    "FV-RECEIVE-MISSING-PAGE",
    "FV-RECEIVE-INVALID-ORDER-PROOF",
    "FV-RECEIVE-STALE-HEAD-CAS",
    "FV-RECEIVE-ATOMIC-ROLLBACK",
    "FV-SQL-DISPATCH-SKIPPED-ORDINAL",
    "FV-SQL-DISPATCH-PARALLEL-PREPARED",
    "FV-RECEIVE-PAGE-CHAIN-MISMATCH",
    "FV-RECEIVE-CHILD-AFTER-SEALED",
    "FV-RECEIVE-HEAD-MANIFEST-ONLY",
    "FV-CONTENT-OFFER-TERMINAL-RESUME",
    "FV-CONTENT-REF-UNFINALIZED-OFFER",
    "FV-MOBILE-ACK-BEFORE-STAGE",
    "FV-SQL-JSON-SAFE-OVERFLOW",
    "FV-RECEIVE-BRIDGE-REPARENT-FORBIDDEN",
    "FV-RECEIVE-MOBILE-REPARENT-FORBIDDEN",
    "FV-RECEIVE-SEALED-PROOF-IMMUTABLE",
    "FV-MOBILE-INBOX-PAYLOAD-IMMUTABLE",
}
FIXED_SCHEMA_FILES = {
    "contracts/schema/common.schema.json",
    "contracts/schema/domain.schema.json",
    "contracts/schema/durable-event.schema.json",
    "contracts/schema/envelope.schema.json",
    "contracts/schema/fingerprint.schema.json",
    "contracts/schema/messages.schema.json",
    "contracts/schema/operation-union.schema.json",
}
FIXED_FINGERPRINT_INCLUDED = (
    "operationKey.sourcePartition.bridgeIdentityId",
    "operationKey.sourcePartition.bridgeInstanceId",
    "operationKey.sourcePartition.codexSourceId",
    "operationKey.operationId",
    "operationRegistryId",
    "operationKind",
    "schemaRevision",
    "typedTarget",
    "typedPayload",
    "typedPreconditions",
)
FIXED_FINGERPRINT_EXCLUDED = (
    "actor",
    "claim",
    "claimHandle",
    "claimRevision",
    "claimTokenDigest",
    "leaseToken",
    "codexCertificationId",
    "codexCertificationDigest",
    "featureCapabilitySnapshotId",
    "featureCapabilitySnapshotDigest",
    "nativeHostCapabilitySnapshotId",
    "nativeHostCapabilitySnapshotDigest",
    "requestId",
    "messageId",
    "clientMessageId",
    "correlationId",
    "retryOfOperationId",
    "deadlineEpochMs",
    "acceptedDeadlinePolicy",
    "traceId",
    "sourceEpoch",
    "connectionEpoch",
    "runtimeEpoch",
    "providerRuntimeEpoch",
    "runtimeFence",
    "runtimeFenceDigest",
    "contentAccessTicket",
    "ticketId",
    "retryTransportMetadata",
)
FIXED_JCS_VECTOR_IDS = (
    "JCS-UTF16-ASTRAL-BEFORE-BMP",
    "JCS-CONTROL-ESCAPES",
    "JCS-NULL-PRESENT",
    "JCS-ABSENT",
    "JCS-INSERTION-ORDER",
    "JCS-SAFE-INTEGER-MAX",
    "JCS-FLOAT-FORBIDDEN",
    "JCS-UNSAFE-INTEGER-FORBIDDEN",
)
FIXED_ACTOR_PROJECTION_VECTOR_IDS = (
    "ACTOR-PROJECTION-POSITIVE",
    "ACTOR-PROJECTION-REJECT-principalId",
    "ACTOR-PROJECTION-REJECT-deviceKeyId",
    "ACTOR-PROJECTION-REJECT-apiKeyId",
    "ACTOR-PROJECTION-REJECT-trustRevision",
    "ACTOR-PROJECTION-REJECT-credentialRevision",
    "ACTOR-PROJECTION-REJECT-scopes",
    "ACTOR-PROJECTION-REJECT-grants",
    "ACTOR-PROJECTION-REJECT-claimTokenDigest",
    "ACTOR-PROJECTION-REJECT-connectionActorId",
    "ACTOR-PROJECTION-REJECT-assurance",
)
FIXED_ACTOR_TICKET_VECTOR_IDS = (
    "ACTOR-TICKET-BINDING-POSITIVE",
    "ACTOR-TICKET-BINDING-REJECT-principalId",
    "ACTOR-TICKET-BINDING-REJECT-deviceKeyId",
    "ACTOR-TICKET-BINDING-REJECT-apiKeyId",
    "ACTOR-TICKET-BINDING-REJECT-trustRevision",
    "ACTOR-TICKET-BINDING-REJECT-credentialRevision",
    "ACTOR-TICKET-BINDING-REJECT-scopes",
    "ACTOR-TICKET-BINDING-REJECT-connectionActorId",
    "ACTOR-TICKET-BINDING-REJECT-assurance",
)
FIXED_PREDECODE_ZERO_EFFECTS = {
    "admissionRows",
    "inboxRows",
    "stagingRows",
    "claimRows",
    "leaseRows",
    "productCalls",
    "providerCalls",
}
FIXED_PREFLIGHT_REQUIRED_FILES = (
    "00-READ-ME-FIRST.md", "01-INPUT-AND-DECISION-LOCK.md",
    "02-ARCHITECTURE-AND-OWNERS.md", "03-CUMULATIVE-DESIGN-AND-FREEZE-GATES.md",
    "04-UNIFIED-DOMAIN-AND-DATAFLOW.md", "05-CONTENT-AND-PRODUCT-OPERATIONS.md",
    "06-STATE-MACHINES-AND-SEMANTIC-AXES.md",
    "07-DIGEST-AND-DURABLE-EVENT-ALGEBRA.md", "PROCESS-LEDGER.md",
    "drafts/IMPLEMENTATION-VALIDATION-ROLLBACK.md",
    "drafts/KERNEL-CAPABILITY-COMPLETION.md", "drafts/MIGRATION-CUTOVER-PLAN.md",
    "drafts/P1-IDENTITY-AUTHORITY-RECEIVE.md",
    "drafts/P1-OPERATIONS-INTERACTIONS-RELATIONS.md",
    "drafts/P2-DEVICE-FILES-MEDIA-GIT.md", "drafts/P2-NATIVE-PRODUCT-SHELL.md",
    "drafts/REQUIREMENT-COVERAGE-REPORT.md", "drafts/SOURCE-REUSE-REPORT.md",
    "matrices/BASELINE-DISPOSITION.csv", "matrices/USER-DECISION-REQUIRED.csv",
    "drafts/AUDIT-COVERAGE-CLOSURE.csv", "drafts/EXPERIMENT-AND-GATE-MATRIX.csv",
    "drafts/K-CAPABILITY-COMPLETION.csv", "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv",
    "drafts/P1-OPERATION-STATE-MATRIX.csv", "drafts/P2-CAPABILITY-P001-P013.csv",
    "drafts/P2-CAPABILITY-P014-P026.csv", "drafts/SOURCE-REUSE-DISPOSITION.csv",
    "validation/README.md", "validation/VALIDATION-SPEC.md",
    "validation/expected-inventory.json", "validation/validate_design.py",
)
FIXED_SOURCE_REFERENCE_COLUMNS = {
    "drafts/K-CAPABILITY-COMPLETION.csv": ("current_source_paths", "current_tests"),
    "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv": ("source_locations",),
    "drafts/P1-OPERATION-STATE-MATRIX.csv": ("current_source_locations",),
    "drafts/SOURCE-REUSE-DISPOSITION.csv": ("current_owner_paths", "current_tests"),
}
FIXED_PHASE2_FILES = (
    "05-CONTENT-AND-PRODUCT-OPERATIONS.md",
    "drafts/P2-CAPABILITY-P001-P013.csv",
    "drafts/P2-CAPABILITY-P014-P026.csv",
    "drafts/P2-DEVICE-FILES-MEDIA-GIT.md",
    "drafts/P2-NATIVE-PRODUCT-SHELL.md",
)

SOURCE_PATH_RE = re.compile(
    r"(?<![\w.-])((?:packages|apps)/[A-Za-z0-9_.+/@-]+"
    r"(?:/[A-Za-z0-9_.+@-]+)*|decisions\.md|THIRD_PARTY_NOTICES\.md)"
)
MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
MARKDOWN_CODE_RE = re.compile(r"`([^`\n]+)`")
FORBIDDEN_ACTOR_ALIASES = (
    "source_device_id",
    "claimantId",
    "deviceId",
    "faceIdPassed",
    "authenticated=true",
)
FORBIDDEN_WRITER_ALIASES = (
    "CanonicalProjectionWriter",
    "ReplicaApplyWriter",
    "CanonicalHistoryWriter",
    "EphemeralChildRegistry",
)

ALLOW_CONTEXT = (
    "delete",
    "replace",
    "remove",
    "rewrite",
    "reject",
    "forbid",
    "forbidden",
    "not_implemented",
    "no_import",
    "no_runtime",
    "unreachable",
    "fail",
    "fail closed",
    "fail-closed",
    "must not",
    "do not",
    "does not",
    "cannot",
    "never",
    "without",
    "evidence",
    "historical",
    "original",
    "donor",
    "source path",
    "source `",
    "alias",
    "allowed only",
    "zero reachable",
    "user decision",
    "current",
    "old",
    "competing",
    "parallel",
    "client boolean",
    "actor_field_forbidden",
    "amend",
    "quarantin",
    "deprecated",
    "删除",
    "替换",
    "拒绝",
    "禁止",
    "不得",
    "不能",
    "不再",
    "不进入",
    "不建立",
    "不保留",
    "不恢复",
    "不信任",
    "不接受",
    "不读取",
    "不读",
    "不可达",
    "只留",
    "隔离",
    "证据",
    "历史",
    "原始",
    "原提案",
    "现有",
    "当前源码",
    "别名",
    "统一回",
    "不另立",
    "无 ",
    "无`",
    "停止",
    "关闭",
    "明确禁止",
    "故意失败",
    "当前",
    "不是",
    "不允许",
    "不重新",
    "决定",
)

LEGACY_MARKER_RE = re.compile(r"\b(?:V2|Mirror|Claude|legacy|Legacy)\b")
FT_BAD_RE = re.compile(
    r"\b(?:FT[-_]?[23]|file[- ]transfer\s+v[23])\b", re.IGNORECASE
)

SQL_FILE_IO_RE = re.compile(
    r"\b(?:ATTACH|DETACH)\b|\bVACUUM\s+INTO\b|"
    r"\bPRAGMA\b|"
    r"\bCREATE\s+VIRTUAL\s+TABLE\b|"
    r"\b(?:load_extension|readfile|writefile)\s*\(",
    re.IGNORECASE,
)
JSON_SCHEMA_TYPES = {
    "null",
    "boolean",
    "object",
    "array",
    "number",
    "integer",
    "string",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def path_has_symlink_component(path: Path, parent: Path) -> bool:
    try:
        relative = path.relative_to(parent)
    except ValueError:
        return True
    current = parent
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def normalize_report_path(root: Path, report_path: Path) -> Path:
    root = root.resolve()
    raw = report_path.expanduser()
    if not raw.is_absolute():
        raw = Path.cwd() / raw
    if raw.is_symlink():
        raise ValueError("--report may not be a symlink")
    resolved = raw.resolve(strict=False)
    if resolved.suffix.lower() != ".json":
        raise ValueError("--report must name a .json file")
    if is_within(resolved, root):
        raise ValueError("--report must be outside the audited repository root")
    if resolved.exists() and not resolved.is_file():
        raise ValueError("--report must be a regular file path")
    return resolved


def is_safe_relative_design_path(value: str) -> bool:
    path = Path(value)
    return bool(value) and not path.is_absolute() and ".." not in path.parts and "\x00" not in value


def stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def reconstructed_utf8_length(value: Any) -> int | None:
    """Return the byte length of a literal or a closed, bounded byte recipe."""
    if isinstance(value, str):
        return len(value.encode("utf-8"))
    if not isinstance(value, dict) or set(value) != {
        "prefix", "repeat", "count", "suffix"
    }:
        return None
    prefix = value.get("prefix")
    repeat = value.get("repeat")
    count = value.get("count")
    suffix = value.get("suffix")
    if (
        not isinstance(prefix, str)
        or not isinstance(repeat, str)
        or not repeat
        or not isinstance(count, int)
        or isinstance(count, bool)
        or count < 0
        or count > 65537
        or not isinstance(suffix, str)
    ):
        return None
    return (
        len(prefix.encode("utf-8"))
        + len(repeat.encode("utf-8")) * count
        + len(suffix.encode("utf-8"))
    )


def settings_operation_inventory_errors(
    payload_property_names: Mapping[str, set[str]],
) -> list[str]:
    """Check R62 ownership/evidence sets independently of registry prose."""
    def mutators_for(*field_names: str) -> set[str]:
        expected_names = set(field_names)
        return {
            operation_id
            for operation_id, names in payload_property_names.items()
            if names & expected_names
        }

    observed_mutators = {
        "model": mutators_for("model", "modelId"),
        "effort": {
            operation_id
            for operation_id, names in payload_property_names.items()
            if any("effort" in name.lower() for name in names)
        },
        "serviceTier": mutators_for("serviceTier", "serviceTierIntent"),
        "collaborationMode": mutators_for("collaborationMode"),
        "approvalPolicy": mutators_for("approvalPolicy"),
        "approvalsReviewer": mutators_for("approvalsReviewer"),
        "sandboxPolicy": mutators_for("sandboxPolicy"),
    }
    expected_mutators = {
        "model": {"OP-024"},
        "effort": {"OP-024"},
        "serviceTier": {"OP-025"},
        "collaborationMode": {"OP-027"},
        "approvalPolicy": {"OP-026", "OP-028"},
        "approvalsReviewer": {"OP-026", "OP-028"},
        "sandboxPolicy": {"OP-026", "OP-028"},
    }
    capability_snapshot_consumers = {
        operation_id
        for operation_id, names in payload_property_names.items()
        if {
            "codexSettingsCapabilitySnapshotId",
            "codexSettingsCapabilitySnapshotDigest",
        }.issubset(names)
    }
    codex_certification_consumers = {
        operation_id
        for operation_id, names in payload_property_names.items()
        if {"codexCertificationId", "codexCertificationDigest"}.issubset(
            names
        )
    }
    errors: list[str] = []
    if observed_mutators != expected_mutators:
        errors.append("settings mutation owner inventory differs")
    if capability_snapshot_consumers != {"OP-024"}:
        errors.append("settings capability snapshot consumer inventory differs")
    if codex_certification_consumers != {
        "OP-025", "OP-026", "OP-027", "OP-028"
    }:
        errors.append("Codex certification consumer inventory differs")
    return errors


def normalize_tuple(raw: str) -> tuple[str, ...]:
    return tuple(part.strip().strip("` ") for part in raw.split(",") if part.strip())


def expand_id_sequence(parts: Sequence[Mapping[str, Any]]) -> list[str]:
    result: list[str] = []
    for part in parts:
        prefix = str(part["prefix"])
        start = int(part["start"])
        end = int(part["end"])
        width = int(part.get("width", 0))
        excluded = {int(value) for value in part.get("exclude", [])}
        for number in range(start, end + 1):
            if number in excluded:
                continue
            rendered = f"{number:0{width}d}" if width else str(number)
            result.append(f"{prefix}{rendered}")
    return result


def fixed_id_sequence(path: str) -> list[str]:
    simple = {
        "matrices/BASELINE-DISPOSITION.csv": [
            f"B-{number:03d}" for number in range(1, 31)
        ],
        "matrices/USER-DECISION-REQUIRED.csv": [
            f"U-{number:03d}" for number in range(1, 10)
        ],
        "drafts/P1-OPERATION-STATE-MATRIX.csv": [
            f"OP-{number:03d}" for number in range(1, 40) if number != 7
        ],
        "drafts/K-CAPABILITY-COMPLETION.csv": [
            f"K-{number:03d}" for number in range(1, 27)
        ],
        "drafts/P2-CAPABILITY-P001-P013.csv": [
            f"P-{number:03d}" for number in range(1, 14)
        ],
        "drafts/P2-CAPABILITY-P014-P026.csv": [
            f"P-{number:03d}" for number in range(14, 27)
        ],
        "drafts/SOURCE-REUSE-DISPOSITION.csv": [
            *[f"K-{number:03d}" for number in range(1, 27)],
            *[f"P-{number:03d}" for number in range(1, 27)],
        ],
        "drafts/EXPERIMENT-AND-GATE-MATRIX.csv": [
            *[f"H{number:02d}" for number in range(0, 19)],
            *[f"D{number:02d}" for number in range(0, 9)],
        ],
    }
    if path in simple:
        return simple[path]
    if path == "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv":
        return [
            *[f"P1-ID-{number:03d}" for number in range(1, 10)],
            *[f"P1-FN-{number:03d}" for number in range(1, 5)],
            *[f"P1-RD-{number:03d}" for number in range(1, 6)],
            *[f"P1-CA-{number:03d}" for number in range(1, 7)],
            *[f"P1-LV-{number:03d}" for number in range(1, 4)],
            *[f"P1-WR-{number:03d}" for number in range(1, 4)],
            *[f"P1-CR-{number:03d}" for number in range(1, 3)],
            *[f"P1-DEL-{number:03d}" for number in range(1, 4)],
            *[f"P1-UD-{number:03d}" for number in range(6, 8)],
        ]
    if path == "drafts/AUDIT-COVERAGE-CLOSURE.csv":
        return [
            *[f"P0-{number:02d}" for number in range(1, 16)],
            *[f"P1-{number:02d}" for number in range(1, 11)],
            *[f"K-{number:03d}" for number in range(1, 27)],
            *[f"P-{number:03d}" for number in range(1, 27)],
            *[f"INPUT-D-{number:03d}" for number in range(1, 13)],
            *[f"U-{number:03d}" for number in range(1, 10)],
            *[f"UNK-{number:03d}" for number in range(1, 15)],
        ]
    return []


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


class StrictJsonError(ValueError):
    pass


class DuplicateJsonKeyError(StrictJsonError):
    pass


def unique_json_object(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJsonKeyError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def reject_json_constant(value: str) -> Any:
    raise StrictJsonError(f"non-standard JSON numeric constant: {value}")


def parse_json_file(path: Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(
            handle,
            object_pairs_hook=unique_json_object,
            parse_constant=reject_json_constant,
        )


class ValidationResult:
    def __init__(self, root: Path, design_root: Path, mode: str, report_path: Path):
        self.root = root
        self.design_root = design_root
        self.mode = mode
        self.report_path = report_path
        self.checks: list[dict[str, Any]] = []
        self.errors: list[dict[str, str]] = []
        self.head: str | None = None
        self.tree: str | None = None

    def error(
        self,
        check_id: str,
        code: str,
        message: str,
        artifact: str = "",
    ) -> None:
        self.errors.append(
            {
                "artifact": artifact,
                "check": check_id,
                "code": code,
                "message": message,
            }
        )

    def run(
        self,
        check_id: str,
        callback: Callable[[str], Mapping[str, Any] | None],
    ) -> bool:
        before = len(self.errors)
        try:
            details = dict(callback(check_id) or {})
        except Exception as exc:  # fail closed with a stable public error type
            self.error(
                check_id,
                "FAIL_VALIDATOR_EXCEPTION",
                f"{type(exc).__name__}: {exc}",
            )
            details = {}
        failed = len(self.errors) != before
        self.checks.append(
            {"details": details, "id": check_id, "status": FAIL if failed else PASS}
        )
        return not failed

    def not_run(self, check_id: str, reason: str) -> None:
        self.checks.append(
            {"details": {"reason": reason}, "id": check_id, "status": NOT_RUN}
        )

    def document(self, artifact_hashes: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
        errors = sorted(
            self.errors,
            key=lambda item: (
                item["check"],
                item["code"],
                item["artifact"],
                item["message"],
            ),
        )
        overall = FAIL if errors else PASS
        document = {
            "artifact_hashes": dict(sorted(artifact_hashes.items())),
            "checks": self.checks,
            "design_root": str(self.design_root),
            "errors": errors,
            "git": {"head": self.head, "tree": self.tree},
            "mode": self.mode,
            "overall_status": overall,
            "report_format_version": REPORT_FORMAT_VERSION,
            "root": str(self.root),
        }
        document["validation_digest"] = hashlib.sha256(
            stable_json(document).encode("utf-8")
        ).hexdigest()
        return document


def load_inventory(
    result: ValidationResult, check_id: str
) -> tuple[dict[str, Any] | None, Mapping[str, Any]]:
    inventory_path = result.design_root / "validation/expected-inventory.json"
    if not inventory_path.is_file():
        result.error(
            check_id,
            MISSING,
            "required validator inventory is missing",
            "validation/expected-inventory.json",
        )
        return None, {"loaded": False}
    try:
        inventory = parse_json_file(inventory_path)
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError) as exc:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            f"inventory JSON cannot be parsed: {exc}",
            "validation/expected-inventory.json",
        )
        return None, {"loaded": False}
    if not isinstance(inventory, dict) or inventory.get("format_version") != 1:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "inventory must be an object with format_version=1",
            "validation/expected-inventory.json",
        )
        return None, {"loaded": False}
    expected_design_dir = inventory.get("design_directory")
    if expected_design_dir != "docs/design/codex-kernel-v4":
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "design_directory must remain docs/design/codex-kernel-v4",
            "validation/expected-inventory.json",
        )
    tables = inventory.get("csv_tables")
    if not isinstance(tables, list):
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "csv_tables must be an array",
            "validation/expected-inventory.json",
        )
        return inventory, {"loaded": True, "format_version": 1}
    configured = {
        str(table.get("path")): table for table in tables if isinstance(table, dict)
    }
    unsafe_table_paths = sorted(
        path for path in configured if not is_safe_relative_design_path(path)
    )
    if unsafe_table_paths:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "CSV paths escape the design root: " + ", ".join(unsafe_table_paths),
            "validation/expected-inventory.json",
        )
    if tuple(inventory.get("preflight_required_files", ())) != FIXED_PREFLIGHT_REQUIRED_FILES:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "preflight_required_files was weakened or reordered",
            "validation/expected-inventory.json",
        )
    raw_source_columns = inventory.get("source_reference_columns")
    normalized_source_columns = {
        str(path): tuple(columns)
        for path, columns in raw_source_columns.items()
    } if isinstance(raw_source_columns, dict) and all(isinstance(columns, list) for columns in raw_source_columns.values()) else {}
    if normalized_source_columns != FIXED_SOURCE_REFERENCE_COLUMNS:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "source_reference_columns was weakened or changed",
            "validation/expected-inventory.json",
        )
    if tuple(inventory.get("phase2_files", ())) != FIXED_PHASE2_FILES:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "phase2_files was weakened or reordered",
            "validation/expected-inventory.json",
        )
    for path, (fixed_rows, fixed_min_columns) in FIXED_TABLE_SHAPES.items():
        table = configured.get(path)
        if table is None:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"fixed CSV contract is missing: {path}",
                "validation/expected-inventory.json",
            )
            continue
        try:
            configured_rows = int(table.get("row_count", -1))
            configured_min_columns = int(table.get("min_columns", -1))
            configured_ids = expand_id_sequence(table.get("id_sequence", []))
        except (KeyError, TypeError, ValueError) as exc:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"invalid fixed CSV contract {path}: {exc}",
                "validation/expected-inventory.json",
            )
            continue
        final_exact_columns = table.get("final_exact_columns")
        exact_required = path in FIXED_FINAL_EXACT_COLUMNS
        if (
            configured_rows != fixed_rows
            or configured_min_columns < fixed_min_columns
            or (
                exact_required
                and final_exact_columns != FIXED_FINAL_EXACT_COLUMNS[path]
            )
        ):
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"{path} must keep {fixed_rows} rows and "
                + (
                    f"at least {fixed_min_columns} columns in preflight and exactly "
                    f"{FIXED_FINAL_EXACT_COLUMNS[path]} in final"
                    if exact_required
                    else f"at least {fixed_min_columns} columns"
                ),
                "validation/expected-inventory.json",
            )
        if exact_required and "final_required_columns" not in table:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"{path} must declare final_required_columns",
                "validation/expected-inventory.json",
            )
        if configured_ids != fixed_id_sequence(path):
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"{path} fixed ID sequence was weakened or changed",
                "validation/expected-inventory.json",
            )
    for path, (fixed_rows, fixed_columns) in FIXED_FINAL_TABLE_SHAPES.items():
        table = configured.get(path)
        if (
            table is None
            or table.get("modes") != ["final"]
            or table.get("row_count") != fixed_rows
            or table.get("exact_columns") != fixed_columns
            or table.get("min_columns") != fixed_columns
            or tuple(table.get("required_columns", ()))
            != FIXED_FINAL_TABLE_COLUMNS[path]
            or set(table.get("allow_blank_columns", ()))
            != FIXED_FINAL_ALLOWED_BLANK_COLUMNS.get(path, set())
        ):
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"{path} must remain a final-only exact {fixed_rows}x{fixed_columns} CSV contract",
                "validation/expected-inventory.json",
            )
    for path, (fixed_columns, dynamic_rule) in DYNAMIC_FINAL_TABLE_RULES.items():
        table = configured.get(path)
        if (
            table is None
            or table.get("modes") != ["final"]
            or "row_count" in table
            or table.get("dynamic_id_rule") != dynamic_rule
            or table.get("exact_columns") != fixed_columns
            or table.get("min_columns") != fixed_columns
            or tuple(table.get("required_columns", ()))
            != FIXED_FINAL_TABLE_COLUMNS[path]
            or set(table.get("allow_blank_columns", ()))
            != FIXED_FINAL_ALLOWED_BLANK_COLUMNS.get(path, set())
        ):
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"{path} must remain a final-only dynamic {fixed_columns}-column successor/set contract",
                "validation/expected-inventory.json",
            )
    final_config = inventory.get("final")
    if not isinstance(final_config, dict):
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "final inventory must be an object",
            "validation/expected-inventory.json",
        )
    else:
        final_files = {str(value) for value in final_config.get("required_files", [])}
        globs = {
            str(entry.get("pattern")): int(entry.get("minimum", 0))
            for entry in final_config.get("required_globs", [])
            if isinstance(entry, dict)
        }
        unsafe_final_paths = sorted(
            value for value in final_files if not is_safe_relative_design_path(value)
        )
        unsafe_globs = sorted(
            value for value in globs if not is_safe_relative_design_path(value)
        )
        if unsafe_final_paths or unsafe_globs:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "final file/glob path escapes design root: "
                + ", ".join([*unsafe_final_paths, *unsafe_globs]),
                "validation/expected-inventory.json",
            )
        if not FIXED_FINAL_FILES.issubset(final_files):
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "fixed final artifact requirements were weakened",
                "validation/expected-inventory.json",
            )
        forbidden_delivery_requirements = sorted(
            value for value in final_files
            if re.search(
                r"(?i)(?:\.zip$|\.tar(?:\.[a-z0-9]+)?$|\.zst$|(?:audit|review)[-_ ]?(?:archive|package)|审核压缩包)",
                value,
            )
        )
        if forbidden_delivery_requirements:
            result.error(
                check_id,
                "FAIL_FORBIDDEN_ARCHIVE_GATE",
                "final inventory may not require an audit/review archive: "
                + ", ".join(forbidden_delivery_requirements),
                "validation/expected-inventory.json",
            )
        forbidden_archive_globs = sorted(
            value for value in globs
            if re.search(
                r"(?i)(?:\.zip|\.tar|\.zst|(?:audit|review)[-_ ]?(?:archive|package)|审核压缩包)",
                value,
            )
        )
        if forbidden_archive_globs:
            result.error(
                check_id,
                "FAIL_FORBIDDEN_ARCHIVE_GATE",
                "final inventory may not require an archive glob: "
                + ", ".join(forbidden_archive_globs),
                "validation/expected-inventory.json",
            )
        if final_config.get("machine_source") != "contracts/contract-registry.json":
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "machine source must remain contracts/contract-registry.json",
                "validation/expected-inventory.json",
            )
        if final_config.get("vector_source") != "contracts/vectors/contract-vectors.json":
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "vector source must remain contracts/vectors/contract-vectors.json",
                "validation/expected-inventory.json",
            )
        if tuple(final_config.get("ddl_files", ())) != (
            "contracts/sql/bridge-v1.sql",
            "contracts/sql/mobile-v1.sql",
        ):
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "the Bridge/Mobile v1 DDL inventory was weakened",
                "validation/expected-inventory.json",
            )
        try:
            operation_slots = tuple(expand_id_sequence(final_config["operation_slots"]))
        except (KeyError, TypeError, ValueError):
            operation_slots = ()
        if operation_slots != FIXED_OPERATION_SLOTS:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "operation slot inventory must be OP-001..OP-039 plus PX-001..PX-030",
                "validation/expected-inventory.json",
            )
        if final_config.get("state_machine_count") != 24:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "state_machine_count must remain 24",
                "validation/expected-inventory.json",
            )
        if final_config.get("feature_contribution_count") != 52:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "feature_contribution_count must remain 52",
                "validation/expected-inventory.json",
            )
        if tuple(final_config.get("lane_inventory", ())) != FIXED_LANE_INVENTORY:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "lane inventory must contain the exact twelve frozen lane families",
                "validation/expected-inventory.json",
            )
        matrix_paths = {
            str(entry.get("path"))
            for entry in tables
            if isinstance(entry, dict)
            and entry.get("modes") == ["final"]
            and str(entry.get("path", "")).startswith("matrices/")
        }
        fixed_matrix_paths = {
            path for path in FIXED_FINAL_FILES if path.startswith("matrices/")
        }
        if matrix_paths != fixed_matrix_paths:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "final matrix contract must enumerate exactly the seven closure matrices",
                "validation/expected-inventory.json",
            )
        if globs.get("contracts/schema/*.schema.json", 0) < 1 or globs.get(
            "contracts/sql/*.sql", 0
        ) < 2:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                "final Schema/DDL glob minimums were weakened",
                "validation/expected-inventory.json",
            )
    return inventory, {"format_version": 1, "loaded": True}


def git_identity(result: ValidationResult, check_id: str) -> Mapping[str, Any]:
    command = ["git", "-C", str(result.root), "rev-parse"]
    try:
        top = subprocess.run(
            command + ["--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        if Path(top).resolve() != result.root:
            raise ValueError(f"root is inside a different Git top-level: {top}")
        result.head = subprocess.run(
            command + ["HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        result.tree = subprocess.run(
            command + ["HEAD^{tree}"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError, ValueError) as exc:
        raise RuntimeError(str(exc)) from exc
    return {"available": True, "head": result.head, "tree": result.tree}


def check_required_files(
    result: ValidationResult,
    check_id: str,
    relative_paths: Sequence[str],
) -> Mapping[str, Any]:
    present = 0
    for raw in relative_paths:
        relative = Path(raw)
        candidate = (result.design_root / relative).resolve(strict=False)
        if relative.is_absolute() or not is_within(candidate, result.design_root):
            result.error(
                check_id,
                "FAIL_UNSAFE_INVENTORY_PATH",
                "inventory path escapes the design root",
                raw,
            )
            continue
        path = result.design_root / relative
        if not path.exists():
            result.error(check_id, MISSING, "required artifact is missing", raw)
        elif path.is_symlink() or not path.is_file():
            result.error(
                check_id,
                "FAIL_INVALID_ARTIFACT_TYPE",
                "required artifact must be a regular non-symlink file",
                raw,
            )
        elif path.stat().st_size == 0:
            result.error(
                check_id,
                "FAIL_EMPTY_ARTIFACT",
                "required artifact is empty",
                raw,
            )
        else:
            present += 1
    return {"present": present, "required": len(relative_paths)}


def validate_csv_table(path: Path, config: Mapping[str, Any]) -> list[dict[str, str]]:
    errors: list[dict[str, str]] = []

    def add(code: str, message: str) -> None:
        errors.append({"code": code, "message": message})

    if not path.is_file():
        add(MISSING, "CSV artifact is missing")
        return errors
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            raw_rows = list(csv.reader(handle, strict=True))
    except (OSError, UnicodeError, csv.Error) as exc:
        add("FAIL_CSV_PARSE", f"CSV parse failed: {exc}")
        return errors
    if not raw_rows:
        add("FAIL_CSV_EMPTY", "CSV contains no header")
        return errors

    header = raw_rows[0]
    if any(not value.strip() for value in header):
        add("FAIL_CSV_BLANK_HEADER", "CSV header contains a blank name")
    if len(set(header)) != len(header):
        add("FAIL_CSV_DUPLICATE_HEADER", "CSV header names are not unique")

    minimum_columns = int(config.get("min_columns", 0))
    if len(header) < minimum_columns:
        add(
            "FAIL_CSV_COLUMN_COUNT",
            f"CSV has {len(header)} columns; expected at least {minimum_columns}",
        )
    exact_columns = config.get("exact_columns")
    if exact_columns is not None and len(header) != int(exact_columns):
        add(
            "FAIL_CSV_COLUMN_COUNT",
            f"CSV has {len(header)} columns; expected exactly {int(exact_columns)}",
        )
    exact_header = config.get("exact_header")
    if exact_header is not None and header != list(exact_header):
        add("FAIL_CSV_HEADER_ORDER", "CSV header differs from the exact final contract")
    required_columns = [str(value) for value in config.get("required_columns", [])]
    missing_columns = [name for name in required_columns if name not in header]
    if missing_columns:
        add(
            "FAIL_CSV_REQUIRED_COLUMNS",
            f"missing required columns: {', '.join(missing_columns)}",
        )

    rows = raw_rows[1:]
    allow_blank_columns = {
        str(value) for value in config.get("allow_blank_columns", [])
    }
    raw_expected_rows = config.get("row_count")
    expected_rows = (
        raw_expected_rows
        if isinstance(raw_expected_rows, int)
        and not isinstance(raw_expected_rows, bool)
        else None
    )
    if expected_rows is not None and len(rows) != expected_rows:
        add(
            "FAIL_CSV_ROW_COUNT",
            f"CSV has {len(rows)} rows; expected {expected_rows}",
        )
    minimum_rows = int(config.get("min_rows", 0))
    if len(rows) < minimum_rows:
        add(
            "FAIL_CSV_ROW_COUNT",
            f"CSV has {len(rows)} rows; expected at least {minimum_rows}",
        )

    for line_number, row in enumerate(rows, 2):
        if len(row) != len(header):
            add(
                "FAIL_CSV_ROW_WIDTH",
                f"row {line_number} has {len(row)} cells; header has {len(header)}",
            )
            continue
        for column_index, value in enumerate(row):
            if not value.strip():
                column = header[column_index] or f"column_{column_index + 1}"
                if column in allow_blank_columns:
                    continue
                add(
                    "FAIL_CSV_BLANK_CELL",
                    f"row {line_number} column {column} is blank",
                )

    id_column = str(config.get("id_column", ""))
    if id_column and id_column in header:
        index = header.index(id_column)
        ids = [row[index] for row in rows if len(row) == len(header)]
        if len(set(ids)) != len(ids):
            add("FAIL_CSV_DUPLICATE_ID", f"{id_column} values are not unique")
        expected_ids = expand_id_sequence(config.get("id_sequence", []))
        if expected_ids and ids != expected_ids:
            add(
                "FAIL_CSV_ID_SEQUENCE",
                f"{id_column} sequence differs from the fixed inventory",
            )
        dynamic_rule = config.get("dynamic_id_rule")
        if dynamic_rule == "SEMANTIC_SUCCESSOR_V1":
            semantic_ids = [value for value in ids if value.startswith("SEM-")]
            operation_ids = [value for value in ids if value.startswith("OP-")]
            capability_ids = [value for value in ids if value.startswith("CAP-")]
            known = set(semantic_ids) | set(operation_ids) | set(capability_ids)
            semantic_numbers = [
                int(value.removeprefix("SEM-"))
                for value in semantic_ids
                if re.fullmatch(r"SEM-[0-9]{3}", value)
            ]
            expected_semantics = (
                [f"SEM-{number:03d}" for number in range(1, max(semantic_numbers) + 1)]
                if semantic_numbers else []
            )
            capability_numbers = [
                int(value.removeprefix("CAP-"))
                for value in capability_ids
                if re.fullmatch(r"CAP-[0-9]{3}", value)
            ]
            expected_capabilities = (
                [
                    f"CAP-{number:03d}"
                    for number in range(1, max(capability_numbers) + 1)
                ]
                if capability_numbers else []
            )
            if (
                set(ids) != known
                or len(semantic_numbers) < 48
                or len(capability_numbers) < 16
                or semantic_ids != expected_semantics
                or operation_ids != ["OP-007", "OP-023", "OP-037"]
                or capability_ids != expected_capabilities
            ):
                add(
                    "FAIL_CSV_ID_SEQUENCE",
                    "semantic dictionary must contain contiguous SEM/CAP successors plus exact OP tombstones",
                )
        elif dynamic_rule == "DECISION_SUCCESSOR_V1":
            decision_ids = [value for value in ids if value.startswith("D-")]
            user_ids = [value for value in ids if value.startswith("U-")]
            stage_ids = [value for value in ids if value.startswith("S-")]
            root_ids = [value for value in ids if re.fullmatch(r"R[0-9]{2}", value)]
            known = set(decision_ids) | set(user_ids) | set(stage_ids) | set(root_ids)
            root_numbers = [int(value[1:]) for value in root_ids]
            expected_roots = (
                [f"R{number:02d}" for number in range(0, max(root_numbers) + 1)]
                if root_numbers else []
            )
            if (
                set(ids) != known
                or decision_ids != [f"D-{number:03d}" for number in range(1, 16)]
                or user_ids != [f"U-{number:03d}" for number in range(1, 10)]
                or stage_ids != [f"S-{number:03d}" for number in range(1, 20)]
                or root_ids != expected_roots
            ):
                add(
                    "FAIL_CSV_ID_SEQUENCE",
                    "decision ledger must retain exact D/U/S inventories and a contiguous dynamic R00..Rnn chain",
                )
        elif dynamic_rule == "AUTHORITY_ORDERED_SET_V1":
            if any(
                not re.fullmatch(r"[A-Z][A-Z0-9_]*", value)
                for value in ids
            ):
                add(
                    "FAIL_CSV_ID_SEQUENCE",
                    "authority inventory IDs must be canonical uppercase semantic identifiers",
                )
        elif dynamic_rule == "SUPERSEDED_VIEW_V1":
            if not ids:
                add(
                    "FAIL_CSV_ID_SEQUENCE",
                    "superseded provenance view must remain a nonempty unique sealed view",
                )
    elif id_column:
        add("FAIL_CSV_ID_COLUMN", f"ID column {id_column} is missing")

    table_name = Path(str(config.get("path", ""))).name
    complete_rows = [row for row in rows if len(row) == len(header)]
    if table_name == "AUDIT-COVERAGE-CLOSURE.csv" and {"id", "class"}.issubset(header):
        id_index = header.index("id")
        class_index = header.index("class")
        for line_number, row in enumerate(complete_rows, 2):
            identifier = row[id_index]
            if identifier.startswith(("P0-", "P1-")):
                expected_class = "REVIEW_PROBLEM"
            elif identifier.startswith(("K-", "P-")):
                expected_class = "ROOT_CAPABILITY"
            elif identifier.startswith(("D-", "INPUT-D-")):
                expected_class = "CROSS_CUTTING"
            elif identifier.startswith("U-"):
                expected_class = "USER_DECISION"
            elif identifier.startswith("UNK-"):
                expected_class = "EXPERIMENT_REQUIRED"
            else:
                expected_class = ""
            if not expected_class or row[class_index] != expected_class:
                add(
                    "FAIL_CSV_SEMANTIC_CLASS",
                    f"row {line_number} {identifier} has class {row[class_index]!r}; expected {expected_class!r}",
                )
    if table_name == "EXPERIMENT-AND-GATE-MATRIX.csv" and {
        "gate_id",
        "gate_kind",
    }.issubset(header):
        id_index = header.index("gate_id")
        kind_index = header.index("gate_kind")
        for line_number, row in enumerate(complete_rows, 2):
            expected_kind = (
                "IMPLEMENTATION_HARD_GATE"
                if row[id_index].startswith("H")
                else "DELIVERY_AUTHORIZATION_GATE"
            )
            if row[kind_index] != expected_kind:
                add(
                    "FAIL_CSV_SEMANTIC_CLASS",
                    f"row {line_number} {row[id_index]} has gate_kind {row[kind_index]!r}; expected {expected_kind!r}",
                )
    if table_name == "DESIGN-CLOSURE.csv" and {
        "id", "machine_binding_status"
    }.issubset(header):
        id_index = header.index("id")
        binding_index = header.index("machine_binding_status")
        for line_number, row in enumerate(complete_rows, 2):
            value = row[binding_index].upper()
            if "PENDING" in value or "MISSING" in value or "UNRESOLVED" in value:
                add(
                    "FAIL_DESIGN_CLOSURE_MACHINE_BINDING",
                    f"row {line_number} {row[id_index]} is not machine-bound: {row[binding_index]!r}",
                )
    if table_name == "P1-MESSAGE-REGISTRY.csv" and "status" in header:
        status_index = header.index("status")
        for line_number, row in enumerate(complete_rows, 2):
            if row[status_index] != "SUPERSEDED_NON_AUTHORITY":
                add(
                    "FAIL_SUPERSEDED_MESSAGE_AUTHORITY",
                    f"row {line_number} old message view is not SUPERSEDED_NON_AUTHORITY",
                )
    if table_name == "P1-SEMANTIC-DICTIONARY.csv" and {
        "semantic_id", "term", "scope_and_fence"
    }.issubset(header):
        id_index = header.index("semantic_id")
        term_index = header.index("term")
        scope_index = header.index("scope_and_fence")
        indexed = {row[id_index]: row for row in complete_rows}
        frozen_terms = {
            "SEM-005": "FeatureCapabilitySnapshot",
            "SEM-032": "CapabilitySupport",
            "SEM-052": "CapabilityAvailability",
            "SEM-053": "CodexAdapterCertification",
            "SEM-054": "ActorProjection",
            "SEM-055": "MaterializationVerificationReceipt",
            "SEM-056": "CodexSettingsCapabilitySnapshot",
            "SEM-057": "ProjectionRoute",
            "SEM-058": "DigestContractV1",
            "SEM-059": "DurableEventVariantV1",
            "SEM-060": "MaterializationCoverageAxes",
            "SEM-061": "CoverageDominanceV1",
            "SEM-062": "GapRepairAdmissionV1",
        }
        for identifier, expected_term in frozen_terms.items():
            row = indexed.get(identifier)
            if row is None or row[term_index] != expected_term:
                add(
                    "FAIL_CAPABILITY_EVIDENCE_NAME",
                    f"{identifier} must retain exact term {expected_term}",
                )
        fingerprint = indexed.get("SEM-025")
        if fingerprint is None or fingerprint[term_index] != "CanonicalFingerprint":
            add(
                "FAIL_FINGERPRINT_EXCLUDED_FIELDS",
                "SEM-025 CanonicalFingerprint row is missing",
            )
        else:
            scope = fingerprint[scope_index].lower()
            excluded_terms = (
                "actor", "evidence", "request", "message", "client", "deadline",
                "trace", "epoch", "ticket",
            )
            if (
                any(term not in scope for term in excluded_terms)
                or not re.search(r"(?i)exclud", scope)
                or re.search(r"(?i)(?:add|include|cover)[^.;]{0,32}\bactor\b", scope)
            ):
                add(
                    "FAIL_FINGERPRINT_EXCLUDED_FIELDS",
                    "SEM-025 must exclude actor/evidence/request/message/client/deadline/trace/epoch/ticket from the semantic fingerprint",
                )
    if table_name == "DECISION-LEDGER.csv" and {
        "decision_id", "record_kind", "scope", "status", "source_authority",
        "supersedes", "statement"
    }.issubset(header):
        indexed = {row[header.index("decision_id")]: row for row in complete_rows}
        row = indexed.get("R33")
        if (
            row is None
            or row[header.index("record_kind")] != "AUTHORIZATION"
            or row[header.index("scope")] != "source-implementation-with-authoritative-design-maintenance"
            or row[header.index("status")] != "FIXED"
            or row[header.index("source_authority")] != "USER_CONFIRMED_REQUIREMENT"
            or row[header.index("supersedes")] != "R17"
            or not all(
                token in row[header.index("statement")]
                for token in ("源码实施", "审核压缩包", "生产", "发布")
            )
        ):
            add(
                "FAIL_SOURCE_IMPLEMENTATION_AUTHORIZATION",
                "R33 must preserve exact source-implementation authorization and no-package/no-delivery boundary",
            )
        r34 = indexed.get("R34")
        r34_statement = r34[header.index("statement")] if r34 else ""
        if (
            r34 is None
            or r34[header.index("record_kind")] != "PROTOCOL"
            or r34[header.index("scope")] != "exact-rfc8785-fingerprint-subdomain"
            or r34[header.index("status")] != "FIXED"
            or r34[header.index("source_authority")] != "ROOT_ADJUDICATED_DESIGN"
            or r34[header.index("supersedes")] != "R32"
            or not all(
                token in r34_statement
                for token in (
                    "RFC 8785", "UTF-16 key ordering", "non-integer JSON numbers",
                    "UInt64", "expected bytes", "SHA-256",
                )
            )
        ):
            add(
                "FAIL_FINGERPRINT_CANONICALIZATION",
                "R34 must freeze the exact RFC8785 integer-only UTF-16-order bytes/digest subdomain",
            )
        for (
            identifier, _historical_scope, _historical_record_kind,
            _historical_statement_terms,
        ) in (
            (
                "R40",
                "materialization-verifier-and-durable-event-block",
                "RECEIVE_SYNC",
                (
                    "MaterializationVerifierV1", "independently", "immutable receipt",
                    "sequence", "payload/message/frame digest", "atomic Mobile",
                ),
            ),
            (
                "R41",
                "i00-codex-schema-and-toolchain-adjudication",
                "EVIDENCE",
                ("0.151.0", "Flutter 3.47", "Dart 3.13", "no Provider certification"),
            ),
            (
                "R42",
                "provider-capability-bound-settings-tuple",
                "THREAD_STATE",
                (
                    "UNKNOWN/EXPLICIT_NULL/VALUE", "Provider string",
                    "approval reviewer", "structured sandbox", "default/plan",
                    "display-only",
                ),
            ),
            (
                "R43", "aggregate-attempt-event-axis-and-guarded-ready-closure",
                "OPERATION",
                ("QUEUED", "BLOCKED_PRECONDITION", "READY", "same-revision event", "OP-023"),
            ),
            (
                "R44", "immutable-current-host-evidence-snapshots", "CAPABILITY",
                ("immutable append-only", "revision one", "current client host", "evidence-kind"),
            ),
            (
                "R45", "sealed-lineage-ticket-and-policy-storage-closure", "CONTENT",
                ("seven sealed lineage", "positive generations", "AutoApprovalPolicyStore", "immutable"),
            ),
            (
                "R46", "independent-capability-operation-reference-closure", "FEATURE_CONTRACT",
                ("derived independently", "P-007", "P-014", "P-025", "operation.submit"),
            ),
            (
                "R47", "zero-based-head-checkpoint-base-ordinal-vs-one-based-bound-epoch-revision-generation-types", "TYPE_SYSTEM",
                ("HeadVersion0", "CheckpointSequence0", "Ordinal0", "BaseSequence0", "BoundEpoch1", "AggregateRevision1", "ObjectGeneration1", "StreamSequence1"),
            ),
            (
                "R48", "decision-vs-input-closure-id-namespace", "GOVERNANCE",
                ("D-001 through D-015", "INPUT-D-001 through INPUT-D-012", "collision"),
            ),
            (
                "R49", "page-preimage-shared-envelope-event-message-keys-and-generic-materialization-block", "RECEIVE_SYNC",
                ("PageBody", "EventKey", "MessageKey", "Catalog and timeline", "pageCount at most 128", "whole-block"),
            ),
            (
                "R50", "goal-sealed-presence-budget-usage-union", "THREAD_STATE",
                ("sealed state", "ABSENT", "CLEARED_PROVEN", "UNKNOWN", "Budget", "usage", "derived"),
            ),
            (
                "R51", "atomic-nested-source-capability-target-admission-equality", "AUTHORITY",
                ("outer SourcePartition", "selected Feature snapshot", "Provider certification", "target-kind"),
            ),
            (
                "R52", "aggregate-head-and-event-atomicity", "STORAGE",
                ("same-transaction", "same-revision event", "cannot be deleted", "ContentRef never update"),
            ),
            (
                "R53", "interaction-settings-goal-single-axis-closure", "STATE_MACHINE",
                ("Interaction uses only", "Settings head is ABSENT/PRESENT", "Goal has six canonical states", "derived health"),
            ),
            (
                "R54", "non-circular-message-and-frame-digest-preimages", "WIRE_INTEGRITY",
                ("never frameDigest or frameByteLength", "excluding only itself", "exact frame bytes", "all three"),
            ),
            (
                "R55", "exact-upstream-source-disposition-and-wave-binding", "BASELINE",
                ("52 capability source-disposition", "exact upstream", "requestId stays transport-only", "Claude paths remain unreachable"),
            ),
            (
                "R56", "subject-derived-materialization-writer-binding", "AUTHORITY",
                ("verifier is pure", "no writer authority", "ConversationCatalogWriter", "CanonicalTimelineWriter", "separate namespaces"),
            ),
            (
                "R57", "single-error-class-code-retry-detail-registry", "ERROR_CONTRACT",
                ("ErrorRegistryV1", "one default retryDirective", "sealed bounded redacted detail schema", "ProblemV1", "OUTCOME_UNKNOWN"),
            ),
            (
                "R58", "sealed-projection-route-recipient-and-stream-algebra", "DELIVERY_AUTHORITY",
                ("ProjectionRouteV1", "rather than a projectionKind by audience Cartesian product", "ORIGIN_RECEIPT/ORIGIN_CONNECTION", "SOURCE_BROADCAST/SOURCE_SUBSCRIBERS", "DEVICE_PROJECTION/PAIRED_DEVICE", "exact allowed route and stream"),
            ),
            (
                "R59", "materialization-receipt-noncircular-preimage-and-begin-binding", "WIRE_INTEGRITY",
                ("begin freezes expected manifest coverage completeness pageCount", "share exact receiptId and manifestDigest", "excluding only receiptDigest", "independently rebuild the preimage"),
            ),
            (
                "R60", "i01-contract-tool-and-final-generated-host-seams", "IMPLEMENTATION_BOUNDARY",
                ("unique machine source", "private validator generator and test workspace only", "generated TypeScript and Dart", "no runtime package dependency", "legacy parser dispatcher upload Claude and Mobile routing handlers untouched"),
            ),
            (
                "R61", "non-circular-contract-set-and-generated-target-manifest", "CONTRACT_INTEGRITY",
                ("sole non-self-referential contract-set manifest", "every normative contract-root regular file except sealed README.md", "exactly two disjoint generatedTargets", "canonical POSIX repo-relative ASCII", "symlinks"),
            ),
            (
                "R62", "provider-readback-nullability-outbound-xor-and-restart-owner-separation", "SETTINGS_CONTRACT",
                ("exactly eight observations", "required-value UNKNOWN-or-VALUE", "nullable UNKNOWN-EXPLICIT_NULL-VALUE", "OP-028 RESTART_WITH_EXECUTION_POLICY", "OP-024 remains the sole effort mutator"),
            ),
            (
                "R63", "exhaustive-digest-registry-and-durable-event-variant-closure", "WIRE_INTEGRITY",
                ("DigestRegistryV1", "exactly nine derivation modes", "DurableEventVariantRegistryV1", "settings.capability.snapshot", "EventFactPreimageV1"),
            ),
            (
                "R64", "minimal-acyclic-materialization-digest-dag-and-coverage-axes", "RECEIVE_INTEGRITY",
                ("proofDigest pageDigest orderDigest coverageDigest manifestDigest beginHeaderDigest receiptDigest", "Structural coverage and payload coverage are orthogonal", "contiguous island turn item and gap ordinals"),
            ),
            (
                "R65", "coverage-dominance-immutable-gap-and-context-bound-repair", "RECEIVE_INTEGRITY",
                ("Catalog and Timeline heads store only ABSENT/PRESENT", "CoverageDominanceV1", "Canonical CoverageGapV1", "R66 supersedes"),
            ),
            (
                "R66", "one-step-authenticated-gap-repair-admission-without-ticket", "CONTROL_PROTOCOL",
                ("gap.repair.request.v1", "RepairAdmissionKeyV1", "No ticket issuer token TTL durable namespace outbox operation or second owner exists"),
            ),
            (
                "R67", "generated-coverage-comparison-projection-and-gap-interval-algebra", "RECEIVE_INTEGRITY",
                ("CoverageComparisonProjectionV1", "Strict superset", "Gap containment", "canonical Gap has no random gapId"),
            ),
        ):
            decision = indexed.get(identifier)
            if (
                decision is None
                or decision[header.index("status")] != "FIXED"
            ):
                add(
                    "FAIL_ROOT_DECISION_BINDING",
                    f"{identifier} is missing or differs from its frozen root decision",
                )
        required_root_columns = {
            "decision_id", "record_kind", "scope", "statement", "status",
            "owner", "source_authority", "source_refs", "affected_artifacts",
            "implementation_gate", "rollback_or_change_rule",
        }
        if required_root_columns.issubset(header):
            indexes = {
                name: header.index(name) for name in required_root_columns
            }
            for line_number, decision in enumerate(complete_rows, 2):
                identifier = decision[indexes["decision_id"]]
                if not re.fullmatch(r"R[0-9]{2}", identifier):
                    continue
                missing_values = [
                    name for name, index in indexes.items()
                    if name != "decision_id" and not decision[index].strip()
                ]
                status = decision[indexes["status"]]
                superseded_by = (
                    decision[header.index("superseded_by")]
                    if "superseded_by" in header else ""
                )
                if (
                    status not in {"FIXED", "SUPERSEDED"}
                    or (status == "SUPERSEDED" and superseded_by == "NONE")
                    or missing_values
                ):
                    add(
                        "FAIL_ROOT_DECISION_BINDING",
                        f"row {line_number} {identifier} lacks a fixed, complete machine binding: {missing_values}",
                    )
    if table_name == "EVIDENCE-ADJUDICATION.csv" and {
        "evidence_id", "evidence_kind", "identity_or_digest", "fact_status",
        "location", "decision_refs"
    }.issubset(header):
        indexed = {row[header.index("evidence_id")]: row for row in complete_rows}
        row = indexed.get("E-USER-003")
        identity = row[header.index("identity_or_digest")] if row else ""
        if (
            row is None
            or row[header.index("evidence_kind")] != "USER_CURRENT_INSTRUCTION"
            or row[header.index("fact_status")] != "CONFIRMED_BY_USER"
            or row[header.index("location")] != "USER_MESSAGE"
            or "R33" not in row[header.index("decision_refs")]
            or not all(token in identity for token in ("source-implementation", "no-package", "no-delivery"))
        ):
            add(
                "FAIL_SOURCE_IMPLEMENTATION_AUTHORIZATION",
                "E-USER-003 must bind source implementation to the no-package/no-delivery scope",
            )
    if table_name == "USER-DECISION-REQUIRED.csv" and {
        "decision_id",
        "status",
    }.issubset(header):
        id_index = header.index("decision_id")
        status_index = header.index("status")
        fixed_status = {
            "U-008": "FIXED_NO_IMPORT",
            "U-009": "FIXED_CLAUDE_UNREACHABLE_SEAM",
        }
        for line_number, row in enumerate(complete_rows, 2):
            expected_status = fixed_status.get(row[id_index], "USER_DECISION_REQUIRED")
            if row[status_index] != expected_status:
                add(
                    "FAIL_CSV_DECISION_STATUS",
                    f"row {line_number} {row[id_index]} has status {row[status_index]!r}; expected {expected_status!r}",
                )
    return errors


def check_csv_tables(
    result: ValidationResult,
    check_id: str,
    tables: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    rows_checked = 0
    registered_paths: set[str] = {
        str(config.get("path"))
        for config in tables
        if isinstance(config, Mapping) and config.get("path")
    }
    applicable_tables = [
        config
        for config in tables
        if not config.get("modes")
    ]
    for raw_config in applicable_tables:
        config = dict(raw_config)
        if result.mode == "final" and "final_exact_columns" in config:
            config["exact_columns"] = config["final_exact_columns"]
            config["exact_header"] = FIXED_FINAL_HEADERS.get(str(config["path"]))
            config["required_columns"] = [
                *config.get("required_columns", []),
                *config.get("final_required_columns", []),
            ]
        if (
            result.mode == "final"
            and config.get("path") == "drafts/AUDIT-COVERAGE-CLOSURE.csv"
        ):
            config["id_sequence"] = [
                {"prefix": "P0-", "start": 1, "end": 15, "width": 2},
                {"prefix": "P1-", "start": 1, "end": 10, "width": 2},
                {"prefix": "K-", "start": 1, "end": 26, "width": 3},
                {"prefix": "P-", "start": 1, "end": 26, "width": 3},
                {"prefix": "INPUT-D-", "start": 1, "end": 12, "width": 3},
                {"prefix": "U-", "start": 1, "end": 9, "width": 3},
                {"prefix": "UNK-", "start": 1, "end": 14, "width": 3},
            ]
        relative = str(config["path"])
        path = result.design_root / relative
        for error in validate_csv_table(path, config):
            result.error(check_id, error["code"], error["message"], relative)
        rows_checked += int(config.get("row_count", 0))
    discovered_tables = 0
    for path in sorted(result.design_root.rglob("*.csv")):
        relative = path.relative_to(result.design_root).as_posix()
        if relative in registered_paths or path.is_symlink() or not path.is_file():
            continue
        discovered_tables += 1
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as handle:
                first_row = next(csv.reader(handle, strict=True), [])
        except (OSError, UnicodeError, csv.Error) as exc:
            result.error(
                check_id,
                "FAIL_CSV_PARSE",
                f"unregistered CSV header cannot be parsed: {exc}",
                relative,
            )
            continue
        if not first_row or not first_row[0].strip():
            result.error(
                check_id,
                "FAIL_CSV_ID_COLUMN",
                "unregistered CSV must have a nonblank first ID column",
                relative,
            )
            continue
        generic_config = {
            "path": relative,
            "id_column": first_row[0],
            "min_columns": 1,
            "min_rows": 1,
            "required_columns": list(first_row),
        }
        for error in validate_csv_table(path, generic_config):
            result.error(check_id, error["code"], error["message"], relative)
    return {
        "discovered_additional_tables": discovered_tables,
        "rows_expected": rows_checked,
        "tables": len(applicable_tables) + discovered_tables,
    }


def extract_source_paths(value: str) -> list[str]:
    return sorted(set(match.group(1).rstrip(".:") for match in SOURCE_PATH_RE.finditer(value)))


def check_source_references(
    result: ValidationResult,
    check_id: str,
    reference_columns: Mapping[str, Sequence[str]],
) -> Mapping[str, Any]:
    references: set[str] = set()
    for relative, columns in sorted(reference_columns.items()):
        path = (result.design_root / relative).resolve(strict=False)
        if not is_safe_relative_design_path(relative) or not is_within(path, result.design_root):
            result.error(check_id, "FAIL_SOURCE_REFERENCE_ESCAPE", "source-reference CSV escapes design root", relative)
            continue
        if not path.is_file():
            result.error(check_id, MISSING, "source-reference CSV is missing", relative)
            continue
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as handle:
                rows = list(csv.DictReader(handle, strict=True))
        except (OSError, UnicodeError, csv.Error) as exc:
            result.error(
                check_id,
                "FAIL_CSV_PARSE",
                f"cannot parse source-reference CSV: {exc}",
                relative,
            )
            continue
        available = set(rows[0]) if rows else set()
        for column in columns:
            if column not in available:
                result.error(
                    check_id,
                    "FAIL_SOURCE_REFERENCE_COLUMN",
                    f"source-reference column is missing: {column}",
                    relative,
                )
                continue
            for row in rows:
                references.update(extract_source_paths(row.get(column, "")))

    for reference in sorted(references):
        relative = Path(reference)
        candidate = (result.root / relative).resolve(strict=False)
        if relative.is_absolute() or ".." in relative.parts or not is_within(candidate, result.root):
            result.error(
                check_id,
                "FAIL_SOURCE_REFERENCE_ESCAPE",
                "source reference escapes repository root",
                reference,
            )
        elif not (result.root / relative).exists():
            result.error(
                check_id,
                "FAIL_SOURCE_REFERENCE_MISSING",
                "referenced current source/test path does not exist",
                reference,
            )
    if not references:
        result.error(
            check_id,
            "FAIL_SOURCE_REFERENCE_EMPTY",
            "no current source/test paths were extracted",
        )
    return {"references": len(references)}


def parse_markdown_target(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<") and ">" in value:
        return value[1 : value.index(">")]
    if re.search(r"\s+[\"']", value):
        value = re.split(r"\s+[\"']", value, maxsplit=1)[0]
    return value


def check_markdown_references(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    count = 0
    code_path_count = 0
    for path in sorted(result.design_root.rglob("*.md")):
        if path.is_symlink() or not path.is_file():
            continue
        relative_doc = path.relative_to(result.design_root).as_posix()
        for line_number, line in enumerate(read_text(path).splitlines(), 1):
            for match in MARKDOWN_LINK_RE.finditer(line):
                target = parse_markdown_target(match.group(1))
                if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                    continue
                target_path = urllib.parse.unquote(target.split("#", 1)[0])
                if not target_path:
                    continue
                count += 1
                if target_path.startswith("/"):
                    candidate = Path(target_path).resolve(strict=False)
                else:
                    candidate = (path.parent / target_path).resolve(strict=False)
                artifact = f"{relative_doc}:{line_number}"
                if not is_within(candidate, result.root):
                    result.error(
                        check_id,
                        "FAIL_MARKDOWN_REFERENCE_ESCAPE",
                        f"Markdown link escapes repository root: {target}",
                        artifact,
                    )
                elif not candidate.exists():
                    result.error(
                        check_id,
                        "FAIL_MARKDOWN_REFERENCE_MISSING",
                        f"Markdown link target does not exist: {target}",
                        artifact,
                    )
            for match in MARKDOWN_CODE_RE.finditer(line):
                raw = match.group(1).strip().rstrip(".,;:")
                if (
                    not raw
                    or any(character.isspace() for character in raw)
                    or any(marker in raw for marker in ("*", "{", "}", "<", ">"))
                ):
                    continue
                if not (
                    raw.startswith(("packages/", "apps/", "docs/"))
                    or raw in ("decisions.md", "THIRD_PARTY_NOTICES.md")
                ):
                    continue
                code_path_count += 1
                normalized = raw.split("#", 1)[0]
                normalized = re.sub(r":\d+(?:-\d+)?$", "", normalized)
                symbol_suffix = re.fullmatch(
                    r"(.+\.(?:ts|tsx|js|mjs|dart|swift|kt|java|py|md|json|sql|csv)):{1,2}[A-Za-z_][A-Za-z0-9_.<>-]*",
                    normalized,
                )
                if symbol_suffix:
                    normalized = symbol_suffix.group(1)
                candidate = (result.root / normalized).resolve(strict=False)
                artifact = f"{relative_doc}:{line_number}"
                planned_i01_path = (
                    normalized == "packages/conversation-contract"
                    or normalized.startswith(
                        "packages/bridge/src/conversation-core/protocol/generated"
                    )
                    or normalized.startswith(
                        "apps/mobile/lib/conversation_core/protocol/generated"
                    )
                    or (
                        result.mode == "preflight"
                        and normalized.startswith(
                            "docs/design/codex-kernel-v4/contracts"
                        )
                    )
                )
                if not is_within(candidate, result.root):
                    result.error(
                        check_id,
                        "FAIL_MARKDOWN_REFERENCE_ESCAPE",
                        f"Markdown code path escapes repository root: {raw}",
                        artifact,
                    )
                elif (
                    not candidate.exists()
                    and not planned_i01_path
                    and not line_has_allow_context(line)
                ):
                    result.error(
                        check_id,
                        "FAIL_MARKDOWN_REFERENCE_MISSING",
                        f"Markdown code path does not exist: {raw}",
                        artifact,
                    )
    return {"code_paths": code_path_count, "local_links": count}


def semantic_files(design_root: Path) -> list[Path]:
    paths: list[Path] = []
    for pattern in ("*.md", "*.csv", "*.json", "*.sql"):
        for path in design_root.rglob(pattern):
            relative = path.relative_to(design_root)
            if relative.parts and relative.parts[0] == "validation":
                continue
            if path.is_file() and not path.is_symlink():
                paths.append(path)
    return sorted(set(paths))


def identity_errors(text: str) -> list[dict[str, str]]:
    errors: list[dict[str, str]] = []
    source_re = re.compile(
        r"\bSourcePartition\b\s*(?:(?:is\s+exactly|fixed\s+as)\s*)?=\s*\(([^)]*)\)",
        re.IGNORECASE,
    )
    operation_re = re.compile(
        r"\bOperationKey\b\s*=\s*\(([^)]*)\)", re.IGNORECASE
    )
    source_plus_re = re.compile(
        r"\bSourcePartition\b\s*=\s*"
        r"([A-Za-z][A-Za-z0-9]*(?:\s*\+\s*[A-Za-z][A-Za-z0-9]*)+)",
        re.IGNORECASE,
    )
    operation_plus_re = re.compile(
        r"\bOperationKey\b\s*=\s*"
        r"([A-Za-z][A-Za-z0-9]*(?:\s*\+\s*[A-Za-z][A-Za-z0-9]*)+)",
        re.IGNORECASE,
    )
    for match in source_re.finditer(text):
        actual = normalize_tuple(match.group(1))
        if actual != CANONICAL_SOURCE_PARTITION:
            errors.append(
                {
                    "code": "FAIL_SOURCE_PARTITION",
                    "message": f"SourcePartition definition is {actual!r}",
                }
            )
    for match in operation_re.finditer(text):
        actual = normalize_tuple(match.group(1))
        if actual != CANONICAL_OPERATION_KEY:
            errors.append(
                {
                    "code": "FAIL_OPERATION_KEY",
                    "message": f"OperationKey definition is {actual!r}",
                }
            )
    for match in source_plus_re.finditer(text):
        actual = tuple(part.strip() for part in match.group(1).split("+"))
        if actual != CANONICAL_SOURCE_PARTITION:
            errors.append(
                {
                    "code": "FAIL_SOURCE_PARTITION",
                    "message": f"SourcePartition definition is {actual!r}",
                }
            )
    for match in operation_plus_re.finditer(text):
        actual = tuple(part.strip() for part in match.group(1).split("+"))
        if actual != CANONICAL_OPERATION_KEY:
            errors.append(
                {
                    "code": "FAIL_OPERATION_KEY",
                    "message": f"OperationKey definition is {actual!r}",
                }
            )
    return errors


def check_identity_contracts(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    source_definitions = 0
    operation_definitions = 0
    source_re = re.compile(r"\bSourcePartition\b[^\n=]{0,32}=\s*\(", re.IGNORECASE)
    operation_re = re.compile(r"\bOperationKey\b\s*=\s*\(", re.IGNORECASE)
    source_plus_re = re.compile(r"\bSourcePartition\b\s*=\s*[A-Za-z]+\s*\+", re.IGNORECASE)
    operation_plus_re = re.compile(r"\bOperationKey\b\s*=\s*[A-Za-z]+\s*\+", re.IGNORECASE)
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        text = read_text(path)
        source_definitions += len(source_re.findall(text)) + len(source_plus_re.findall(text))
        operation_definitions += len(operation_re.findall(text)) + len(
            operation_plus_re.findall(text)
        )
        for error in identity_errors(text):
            result.error(check_id, error["code"], error["message"], relative)
    if source_definitions == 0:
        result.error(
            check_id,
            "FAIL_SOURCE_PARTITION_MISSING",
            "no SourcePartition tuple definition was found",
        )
    if operation_definitions == 0:
        result.error(
            check_id,
            "FAIL_OPERATION_KEY_MISSING",
            "no OperationKey tuple definition was found",
        )
    return {
        "operation_key_definitions": operation_definitions,
        "source_partition_definitions": source_definitions,
    }


def line_has_allow_context(line: str) -> bool:
    lowered = line.lower()
    return any(marker.lower() in lowered for marker in ALLOW_CONTEXT)


def check_aliases(result: ValidationResult, check_id: str) -> Mapping[str, Any]:
    occurrences = 0
    needles = FORBIDDEN_ACTOR_ALIASES + FORBIDDEN_WRITER_ALIASES
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        # Contract JSON is checked as a structured graph in final mode.  A
        # line-oriented pass cannot distinguish a forbidden-field vector from
        # a reachable field and would reject the deliberate negative corpus.
        if relative.startswith("contracts/") and path.suffix.lower() == ".json":
            continue
        if path.suffix.lower() == ".csv":
            try:
                with path.open("r", encoding="utf-8-sig", newline="") as handle:
                    rows = list(csv.DictReader(handle, strict=True))
            except (OSError, UnicodeError, csv.Error):
                continue
            for row_index, row in enumerate(rows, 2):
                row_context = " ".join(str(value) for value in row.values())
                for column, value in row.items():
                    found = [
                        needle
                        for needle in needles
                        if needle.lower() in (value or "").lower()
                    ]
                    if not found:
                        continue
                    occurrences += len(found)
                    evidence_column = any(
                        marker in (column or "").lower()
                        for marker in (
                            "forbidden",
                            "evidence",
                            "source",
                            "disposition",
                            "reason",
                            "baseline",
                        )
                    )
                    if not evidence_column and not line_has_allow_context(row_context):
                        result.error(
                            check_id,
                            "FAIL_FORBIDDEN_ACTOR_WRITER_ALIAS",
                            f"alias lacks explicit rejection/evidence context: {', '.join(found)}",
                            f"{relative}:{row_index}:{column}",
                        )
            continue

        lines = read_text(path).splitlines()
        for index, line in enumerate(lines):
            found = [needle for needle in needles if needle.lower() in line.lower()]
            if not found:
                continue
            occurrences += len(found)
            context = " ".join(lines[max(0, index - 2) : min(len(lines), index + 3)])
            if not line_has_allow_context(context):
                result.error(
                    check_id,
                    "FAIL_FORBIDDEN_ACTOR_WRITER_ALIAS",
                    f"alias lacks explicit rejection/evidence context: {', '.join(found)}",
                    f"{relative}:{index + 1}",
                )
    return {"reviewed_occurrences": occurrences}


def check_legacy_markers(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    occurrences = 0
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        if relative.startswith("contracts/") and path.suffix.lower() == ".json":
            continue
        strict_contract = relative.startswith("contracts/")
        lines = read_text(path).splitlines()
        negative_section = False
        for line_number, line in enumerate(lines, 1):
            if path.suffix.lower() == ".md" and line.lstrip().startswith("#"):
                heading = line.lower()
                negative_section = any(
                    marker in heading
                    for marker in (
                        "故意失败",
                        "必须故意失败",
                        "negative vector",
                        "fault vector",
                    )
                )
            matches = sorted(set(match.group(0) for match in LEGACY_MARKER_RE.finditer(line)))
            if not matches:
                continue
            occurrences += len(matches)
            context = " ".join(
                lines[max(0, line_number - 4) : min(len(lines), line_number + 3)]
            )
            allowed = (
                negative_section
                or relative.startswith("evidence/")
                or line_has_allow_context(context)
            )
            if strict_contract:
                lowered = line.lower()
                allowed = any(
                    marker in lowered
                    for marker in (
                        "not_implemented",
                        "no_import",
                        "no legacy",
                        "delete",
                        "forbidden",
                        "unreachable",
                        "不可达",
                        "删除",
                    )
                )
            if not allowed:
                result.error(
                    check_id,
                    "FAIL_REACHABLE_LEGACY_MARKER",
                    f"marker lacks evidence/delete/unreachable context: {', '.join(matches)}",
                    f"{relative}:{line_number}",
                )
    return {"reviewed_occurrences": occurrences}


def check_phase2_candidate_binding(
    result: ValidationResult,
    check_id: str,
    phase2_files: Sequence[str],
) -> Mapping[str, Any]:
    scanned = 0
    for relative in phase2_files:
        path = (result.design_root / relative).resolve(strict=False)
        if not is_safe_relative_design_path(relative) or not is_within(path, result.design_root):
            result.error(check_id, "FAIL_PHASE2_PATH_ESCAPE", "Phase 2 artifact escapes design root", relative)
            continue
        if not path.is_file():
            result.error(check_id, MISSING, "Phase 2 artifact is missing", relative)
            continue
        scanned += 1
        for line_number, line in enumerate(read_text(path).splitlines(), 1):
            if "CANDIDATE_BINDING" in line:
                result.error(
                    check_id,
                    "FAIL_PHASE2_CANDIDATE_BINDING",
                    "CANDIDATE_BINDING is forbidden in Phase 2",
                    f"{relative}:{line_number}",
                )
    return {"files": scanned}


def quantity_to_bytes(number: str, unit: str) -> int:
    value = int(number.replace(",", "").replace("_", "").replace(" ", ""))
    normalized = unit.lower()
    if normalized == "kib":
        return value * 1024
    if normalized == "mib":
        return value * 1024 * 1024
    return value


def budget_errors(text: str, maximum: int = 65536) -> list[dict[str, str]]:
    errors: list[dict[str, str]] = []
    pattern = re.compile(
        r"(?i)\b(?:control(?:\s+(?:frame|envelope|policy|body))?|envelope)"
        r"(?:\s+(?:at\s+most|max(?:imum)?))?\s*(?:<=|=|:)?\s*"
        r"([0-9][0-9,_ ]*)\s*(KiB|MiB|B|bytes)\b"
    )
    for match in pattern.finditer(text):
        declared = quantity_to_bytes(match.group(1), match.group(2))
        if declared > maximum:
            errors.append(
                {
                    "code": "FAIL_CONTROL_BUDGET_OVERSIZE",
                    "message": f"declared control/envelope budget {declared} exceeds {maximum}",
                }
            )
    return errors


def check_budgets(
    result: ValidationResult,
    check_id: str,
    configured: Mapping[str, Any],
) -> Mapping[str, Any]:
    expected = {"envelope": 65536, "payload": 57344, "interaction_answer": 49152}
    actual = {key: int(configured.get(key, -1)) for key in expected}
    if actual != expected:
        result.error(
            check_id,
            "FAIL_BUDGET_INVENTORY",
            f"inventory budgets differ from fixed values: {actual}",
            "validation/expected-inventory.json",
        )

    declarations = 0
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        text = read_text(path)
        for error in budget_errors(text, expected["envelope"]):
            result.error(check_id, error["code"], error["message"], relative)
        declarations += len(
            re.findall(r"(?i)(?:control|envelope)[^\n]{0,32}(?:KiB|bytes|\dB)", text)
        )

    authoritative_paths = (
        result.design_root / "PROCESS-LEDGER.md",
        result.design_root / "drafts/P1-OPERATIONS-INTERACTIONS-RELATIONS.md",
    )
    authoritative = "\n".join(
        read_text(path) for path in authoritative_paths if path.is_file()
    )
    spellings = {
        "envelope": ("65,536", "65536", "64 KiB", "64KiB"),
        "payload": ("57,344", "57344", "56 KiB", "56KiB"),
        "interaction_answer": ("49,152", "49152", "48 KiB", "48KiB"),
    }
    for name, variants in spellings.items():
        if not any(value in authoritative for value in variants):
            result.error(
                check_id,
                "FAIL_BUDGET_DECLARATION_MISSING",
                f"authoritative {name} budget declaration is missing",
            )
    return {"declarations_reviewed": declarations, **expected}


def check_ft_naming(result: ValidationResult, check_id: str) -> Mapping[str, Any]:
    occurrences = 0
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        for line_number, line in enumerate(read_text(path).splitlines(), 1):
            matches = []
            for match in FT_BAD_RE.finditer(line):
                rendered = match.group(0)
                version_match = re.search(r"[23]", rendered)
                version = version_match.group(0) if version_match else ""
                slash_compound = (
                    match.start() > 0
                    and line[match.start() - 1] == "/"
                    and match.end() < len(line)
                    and line[match.end()] == "/"
                )
                if (
                    relative.startswith("evidence/")
                    or (version and f"FT/{version}" in line)
                    or slash_compound
                ):
                    continue
                matches.append(match)
            occurrences += len(matches)
            if matches:
                result.error(
                    check_id,
                    "FAIL_FILE_TRANSFER_NAMING",
                    "file-transfer generations must be named FT/2 or FT/3",
                    f"{relative}:{line_number}",
                )
    content_path = result.design_root / "05-CONTENT-AND-PRODUCT-OPERATIONS.md"
    if content_path.is_file():
        content = read_text(content_path)
        for required in ("FT/2", "FT/3"):
            if required not in content:
                result.error(
                    check_id,
                    "FAIL_FILE_TRANSFER_NAMING_MISSING",
                    f"required canonical name is missing: {required}",
                    "05-CONTENT-AND-PRODUCT-OPERATIONS.md",
                )
    else:
        result.error(
            check_id,
            MISSING,
            "content/operation design is missing",
            "05-CONTENT-AND-PRODUCT-OPERATIONS.md",
        )
    return {"forbidden_spellings": occurrences}


def selector_has_forbidden_scope(value: Any) -> bool:
    rendered = stable_json(value).lower()
    return any(marker in rendered for marker in ("generic", "global", "path", "route"))


def check_r14_operation_preflight(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    relative = "drafts/P1-OPERATION-STATE-MATRIX.csv"
    path = result.design_root / relative
    if not path.is_file():
        result.error(check_id, MISSING, "operation matrix is missing", relative)
        return {"operations": 0}
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            rows = list(csv.DictReader(handle, strict=True))
    except (OSError, UnicodeError, csv.Error) as exc:
        result.error(
            check_id,
            "FAIL_CSV_PARSE",
            f"operation matrix cannot be parsed: {exc}",
            relative,
        )
        return {"operations": 0}
    for row_index, row in enumerate(rows, 2):
        operation_id = row.get("mutation_id", f"row-{row_index}")
        for column in ("queue_lane_selector", "execution_conflict_selector"):
            selector = row.get(column, row.get("queue_lane", ""))
            if selector_has_forbidden_scope(selector):
                result.error(
                    check_id,
                    "FAIL_R14_FORBIDDEN_LANE_SCOPE",
                    f"{operation_id} uses generic/global/path/route {column}: {selector}",
                    f"{relative}:{row_index}",
                )
        replay = row.get("replay_policy", "")
        lowered = replay.lower()
        same_id = "same operationid" in lowered or "same id" in lowered
        redispatch = bool(re.search(r"\b(?:redispatch|re-dispatch|resend\s+dispatch)\b", lowered))
        resend = bool(re.search(r"\bresend\b", lowered))
        admission_lookup_only = bool(
            re.search(r"(?i)(?:admission|state).{0,32}(?:lookup|query)", lowered)
            or re.search(r"(?i)resend.{0,48}learn\s+admission", lowered)
        )
        if same_id and (redispatch or (resend and not admission_lookup_only)):
            result.error(
                check_id,
                "FAIL_R14_SAME_ID_REDISPATCH",
                f"{operation_id} describes same-ID resend/redispatch",
                f"{relative}:{row_index}",
            )
    return {"operations": len(rows)}


def check_r14_machine_contracts(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    relative = "contracts/contract-registry.json"
    path = result.design_root / relative
    try:
        registry = parse_json_file(path)
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError) as exc:
        result.error(
            check_id,
            "FAIL_R14_REGISTRY_PARSE",
            f"machine registry cannot be parsed: {exc}",
            relative,
        )
        return {"operations": 0}
    operations = registry.get("operations") if isinstance(registry, dict) else None
    if not isinstance(operations, list) or not operations:
        result.error(
            check_id,
            "FAIL_R14_OPERATION_REGISTRY",
            "registry operations must be a nonempty array",
            relative,
        )
        return {"operations": 0}
    for index, operation in enumerate(operations):
        artifact = f"{relative}#operations/{index}"
        if not isinstance(operation, dict):
            result.error(
                check_id,
                "FAIL_R14_OPERATION_REGISTRY",
                "operation descriptor must be an object",
                artifact,
            )
            continue
        operation_id = operation.get("id", f"operation-{index}")
        for selector in ("queueLaneSelector", "executionConflictSelectors"):
            if selector not in operation:
                result.error(
                    check_id,
                    "FAIL_R14_SELECTOR_MISSING",
                    f"{operation_id} is missing {selector}",
                    artifact,
                )
            elif selector_has_forbidden_scope(operation[selector]):
                result.error(
                    check_id,
                    "FAIL_R14_FORBIDDEN_LANE_SCOPE",
                    f"{operation_id} {selector} uses generic/global/path/route scope",
                    artifact,
                )
        replay_policy = operation.get("replayPolicy")
        if not isinstance(replay_policy, str) or not replay_policy.strip():
            result.error(
                check_id,
                "FAIL_R14_SAME_ID_POLICY_MISSING",
                f"{operation_id} must declare an explicit replay policy",
                artifact,
            )
        rendered = stable_json(operation).lower()
        if (
            re.search(
                r"same.{0,40}(?:operation)?id.{0,80}(?:resend|redispatch|re-dispatch)",
                rendered,
            )
            or "resend_dispatch" in rendered
        ):
            result.error(
                check_id,
                "FAIL_R14_SAME_ID_REDISPATCH",
                f"{operation_id} describes same-ID resend dispatch",
                artifact,
            )
        if re.search(
            r"legacy.{0,80}upload.{0,80}fallback|upload.{0,80}legacy.{0,80}fallback",
            rendered,
        ):
            result.error(
                check_id,
                "FAIL_R14_LEGACY_UPLOAD_FALLBACK",
                f"{operation_id} registers a legacy upload mutation fallback",
                artifact,
            )
    return {"operations": len(operations), "selector_fields_per_operation": 2}


def final_missing_artifacts(
    design_root: Path, final_config: Mapping[str, Any]
) -> list[str]:
    missing: list[str] = []
    for relative in final_config.get("required_files", []):
        path = design_root / str(relative)
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            missing.append(str(relative))
    for entry in final_config.get("required_globs", []):
        pattern = str(entry["pattern"])
        minimum = int(entry.get("minimum", 1))
        matches = [
            path
            for path in design_root.glob(pattern)
            if path.is_file() and not path.is_symlink() and path.stat().st_size > 0
        ]
        if len(matches) < minimum:
            missing.append(pattern)
    return sorted(missing)


def check_final_inventory(
    result: ValidationResult,
    check_id: str,
    final_config: Mapping[str, Any],
) -> Mapping[str, Any]:
    missing = final_missing_artifacts(result.design_root, final_config)
    for artifact in missing:
        result.error(
            check_id,
            MISSING,
            "required final artifact or glob is missing/empty",
            artifact,
        )
    return {
        "missing": len(missing),
        "required_files": len(final_config.get("required_files", [])),
        "required_globs": len(final_config.get("required_globs", [])),
    }


def check_contract_manifest(
    result: ValidationResult, check_id: str, final_config: Mapping[str, Any]
) -> Mapping[str, Any]:
    relative = "contracts/CONTRACT-MANIFEST.json"
    manifest_path = result.design_root / relative
    try:
        manifest = parse_json_file(manifest_path)
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError) as exc:
        result.error(check_id, "FAIL_CONTRACT_MANIFEST_PARSE", f"manifest cannot be parsed: {exc}", relative)
        return {"files": 0}
    if not isinstance(manifest, dict):
        result.error(check_id, "FAIL_CONTRACT_MANIFEST_STRUCTURE", "manifest must be an object", relative)
        return {"files": 0}

    manifest_fields = {
        "contractSet", "algorithm", "members", "contractSetDigest",
        "implementationReady", "generatedTargets",
    }
    implementation_ready = manifest.get("implementationReady")
    generated_targets = manifest.get("generatedTargets")
    if (
        manifest.get("contractSet") != "ccpocket.codex.kernel/1/revision-1"
        or manifest.get("algorithm") != "sha256"
        or set(manifest) != manifest_fields
    ):
        result.error(
            check_id,
            "FAIL_CONTRACT_MANIFEST_STRUCTURE",
            "manifest must use the closed contractSet/algorithm/members/"
            "contractSetDigest/implementationReady/generatedTargets shape",
            relative,
        )
    if (
        not isinstance(implementation_ready, bool)
        or not isinstance(generated_targets, list)
        or (
            implementation_ready is False
            and generated_targets != []
        )
        or (
            implementation_ready is True
            and len(generated_targets) != 2
        )
    ):
        result.error(
            check_id,
            "FAIL_CONTRACT_MANIFEST_LIFECYCLE",
            "DESIGN_SOURCE_READY is exactly implementationReady=false with "
            "generatedTargets=[]; I01_GENERATED is exactly "
            "implementationReady=true with two nonempty target inventories",
            relative,
        )
    raw_entries = manifest.get("members")
    entries: list[dict[str, Any]] = []
    if isinstance(raw_entries, list):
        entries = [entry for entry in raw_entries if isinstance(entry, dict)]
        if len(entries) != len(raw_entries):
            result.error(check_id, "FAIL_CONTRACT_MANIFEST_STRUCTURE", "every managed file entry must be an object", relative)
    elif isinstance(raw_entries, dict):
        result.error(
            check_id,
            "FAIL_CONTRACT_MANIFEST_STRUCTURE",
            "members must be the deterministic sorted array form",
            relative,
        )
        for path, value in raw_entries.items():
            if isinstance(value, str):
                entries.append({"path": path, "sha256": value})
            elif isinstance(value, dict):
                entries.append({"path": path, **value})
            else:
                result.error(check_id, "FAIL_CONTRACT_MANIFEST_STRUCTURE", f"invalid entry for {path}", relative)
    else:
        result.error(check_id, "FAIL_CONTRACT_MANIFEST_STRUCTURE", "manifest needs a members array", relative)

    contracts_root = (result.design_root / "contracts").resolve()
    declared: dict[str, str] = {}
    declared_casefold: set[str] = set()
    raw_member_paths: list[str] = []
    for index, entry in enumerate(entries):
        artifact = f"{relative}#members/{index}"
        if set(entry) != {"path", "bytes", "sha256"}:
            result.error(
                check_id,
                "FAIL_CONTRACT_MANIFEST_ENTRY",
                "member must contain exactly path, bytes, and sha256",
                artifact,
            )
        raw_path = entry.get("path")
        digest = next((entry.get(key) for key in ("sha256", "digest", "sha256Digest") if key in entry), None)
        if not isinstance(raw_path, str) or not raw_path or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            result.error(check_id, "FAIL_CONTRACT_MANIFEST_ENTRY", "entry needs a safe path and lowercase SHA-256", artifact)
            continue
        relative_under_contracts = raw_path.removeprefix("contracts/")
        candidate = (contracts_root / relative_under_contracts).resolve(strict=False)
        normalized = f"contracts/{Path(relative_under_contracts).as_posix()}"
        if (
            Path(raw_path).is_absolute()
            or raw_path.startswith("contracts/")
            or not raw_path.isascii()
            or "\\" in raw_path
            or any(ord(character) < 32 or ord(character) == 127 for character in raw_path)
            or raw_path != "/".join(Path(raw_path).parts)
            or any(part in {"", ".", ".."} for part in raw_path.split("/"))
            or ".." in Path(raw_path).parts
            or not is_within(candidate, contracts_root)
            or normalized == relative
            or raw_path == "README.md"
        ):
            result.error(check_id, "FAIL_CONTRACT_MANIFEST_PATH", f"unsafe or self-referential manifest path: {raw_path}", artifact)
            continue
        if normalized in declared:
            result.error(check_id, "FAIL_CONTRACT_MANIFEST_DUPLICATE", f"duplicate managed path: {normalized}", artifact)
        if normalized.casefold() in declared_casefold:
            result.error(
                check_id,
                "FAIL_CONTRACT_MANIFEST_DUPLICATE",
                f"case-fold colliding managed path: {normalized}",
                artifact,
            )
        declared_casefold.add(normalized.casefold())
        declared[normalized] = digest
        raw_member_paths.append(raw_path)
        if not candidate.is_file() or candidate.is_symlink():
            result.error(check_id, MISSING, f"managed contract file is missing: {normalized}", artifact)
            continue
        actual_digest = sha256_file(candidate)
        if actual_digest != digest:
            result.error(check_id, "FAIL_CONTRACT_MANIFEST_DIGEST", f"SHA-256 mismatch for {normalized}", artifact)
        size_value = next((entry.get(key) for key in ("size", "bytes", "sizeBytes") if key in entry), None)
        if size_value is not None and (not isinstance(size_value, int) or isinstance(size_value, bool) or size_value != candidate.stat().st_size):
            result.error(check_id, "FAIL_CONTRACT_MANIFEST_SIZE", f"byte size mismatch for {normalized}", artifact)

    if raw_member_paths != sorted(raw_member_paths):
        result.error(
            check_id,
            "FAIL_CONTRACT_MANIFEST_ORDER",
            "source members must use sorted canonical contract-root-relative paths",
            relative,
        )
    readme_path = contracts_root / "README.md"
    readme_text = read_text(readme_path) if readme_path.is_file() else ""
    if (
        not readme_path.is_file()
        or readme_path.is_symlink()
        or "NON_NORMATIVE_REVIEW_VIEW" not in readme_text
        or "cannot override" not in readme_text
    ):
        result.error(
            check_id,
            "FAIL_CONTRACT_README_AUTHORITY",
            "README.md is the sole sealed non-authority exclusion and must explicitly deny override authority",
            "contracts/README.md",
        )
    contract_symlinks = [
        path.relative_to(result.design_root).as_posix()
        for path in contracts_root.rglob("*") if path.is_symlink()
    ]
    if contract_symlinks:
        result.error(
            check_id,
            "FAIL_CONTRACT_MANIFEST_PATH",
            "contract root contains symlinks: " + ", ".join(contract_symlinks),
            relative,
        )
    actual_paths = {
        path.relative_to(result.design_root).as_posix()
        for path in contracts_root.rglob("*")
        if path.is_file()
        and not path.is_symlink()
        and path.resolve() != manifest_path.resolve()
        and path.resolve() != readme_path.resolve()
    }
    if set(declared) != actual_paths:
        result.error(
            check_id,
            "FAIL_CONTRACT_MANIFEST_COVERAGE",
            f"manifest coverage differs; missing={sorted(actual_paths - set(declared))}, extra={sorted(set(declared) - actual_paths)}",
            relative,
        )

    contract_set_digest = manifest.get("contractSetDigest")
    canonical_member_set = stable_json(
        {
            "members": [
                {
                    "path": entry.get("path"),
                    "bytes": entry.get("bytes"),
                    "sha256": entry.get("sha256"),
                }
                for entry in entries
            ]
        }
    ).encode("utf-8")
    expected_contract_set_digest = hashlib.sha256(canonical_member_set).hexdigest()
    if (
        not isinstance(contract_set_digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", contract_set_digest)
        or contract_set_digest != expected_contract_set_digest
    ):
        result.error(
            check_id,
            "FAIL_CONTRACT_MANIFEST_SET_DIGEST",
            "contractSetDigest must be SHA-256 of canonical {members:[...]} in declared order",
            relative,
        )

    registry_digest = sha256_file(result.design_root / str(final_config["machine_source"]))
    if declared.get(str(final_config["machine_source"])) != registry_digest:
        result.error(check_id, "FAIL_CONTRACT_MANIFEST_SOURCE_DIGEST", "managed registry entry digest is missing or inconsistent", relative)
    return {
        "contract_set_digest": contract_set_digest,
        "files": len(declared),
        "readiness": (
            "DESIGN_SOURCE_READY"
            if implementation_ready is False and generated_targets == []
            else (
                "I01_GENERATED_DECLARED"
                if implementation_ready is True
                and isinstance(generated_targets, list)
                and len(generated_targets) == 2
                else "INVALID"
            )
        ),
        "registry_sha256": registry_digest,
    }


def check_generated_targets(
    result: ValidationResult,
    check_id: str,
    reproduce: Callable[[Path], None] | None = None,
) -> Mapping[str, Any]:
    relative = "contracts/CONTRACT-MANIFEST.json"
    errors_before = len(result.errors)
    manifest = parse_json_file(result.design_root / relative)
    if not isinstance(manifest, dict):
        result.error(
            check_id, "FAIL_GENERATED_TARGET_MANIFEST",
            "contract manifest must be an object", relative,
        )
        return {"readiness": "INVALID", "targets": 0}
    targets = manifest.get("generatedTargets")
    source_digest = manifest.get("contractSetDigest")
    if (
        manifest.get("implementationReady") is not True
        or not isinstance(targets, list)
        or len(targets) != 2
    ):
        result.error(
            check_id,
            "FAIL_GENERATED_TARGET_MANIFEST",
            "I01_GENERATED_READY requires implementationReady=true and "
            "exactly two generatedTargets",
            relative,
        )
        return {"readiness": "INVALID", "targets": 0}
    observed_roots: list[str] = []
    all_declared_paths: set[str] = set()
    all_casefold_paths: set[str] = set()
    files_checked = 0

    def canonical_repo_path(value: Any) -> bool:
        return (
            isinstance(value, str)
            and bool(value)
            and value.isascii()
            and not value.startswith("/")
            and "\\" not in value
            and not any(ord(character) < 32 or ord(character) == 127 for character in value)
            and all(part not in {"", ".", ".."} for part in value.rstrip("/").split("/"))
            and value.rstrip("/") == "/".join(Path(value.rstrip("/")).parts)
        )

    for index, target in enumerate(targets):
        artifact = f"{relative}#generatedTargets/{index}"
        if not isinstance(target, dict) or set(target) != {
            "language", "targetRoot", "sourceDigest", "files"
        }:
            result.error(
                check_id,
                "FAIL_GENERATED_TARGET_MANIFEST",
                "generated target must contain exactly language/targetRoot/sourceDigest/files",
                artifact,
            )
            continue
        target_root = target.get("targetRoot")
        files = target.get("files")
        if (
            not canonical_repo_path(target_root)
            or not str(target_root).endswith("/")
            or target.get("language")
            != ("TYPESCRIPT" if index == 0 else "DART")
            or target.get("sourceDigest") != source_digest
            or not isinstance(files, list)
            or not files
        ):
            result.error(
                check_id,
                "FAIL_GENERATED_TARGET_MANIFEST",
                "target root/source digest/files are invalid or empty",
                artifact,
            )
            continue
        observed_roots.append(str(target_root))
        lexical_target_directory = result.root / str(target_root).rstrip("/")
        target_directory = lexical_target_directory.resolve(strict=False)
        if (
            not is_within(target_directory, result.root)
            or path_has_symlink_component(lexical_target_directory, result.root)
            or not target_directory.is_dir()
        ):
            result.error(
                check_id,
                "FAIL_GENERATED_TARGET_PATH",
                f"generated target root is missing, escaping, or symlinked: {target_root}",
                artifact,
            )
            continue
        raw_paths: list[str] = []
        for file_index, entry in enumerate(files):
            file_artifact = f"{artifact}/files/{file_index}"
            if (
                not isinstance(entry, dict)
                or set(entry) != {"path", "bytes", "sha256"}
                or not canonical_repo_path(entry.get("path"))
                or not str(entry.get("path")).startswith(str(target_root))
                or not isinstance(entry.get("bytes"), int)
                or isinstance(entry.get("bytes"), bool)
                or entry["bytes"] < 1
                or not isinstance(entry.get("sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
            ):
                result.error(
                    check_id,
                    "FAIL_GENERATED_TARGET_FILE",
                    "generated file needs a canonical in-root path, positive bytes, and lowercase SHA-256",
                    file_artifact,
                )
                continue
            file_path = entry["path"]
            raw_paths.append(file_path)
            if file_path in all_declared_paths or file_path.casefold() in all_casefold_paths:
                result.error(
                    check_id,
                    "FAIL_GENERATED_TARGET_PATH",
                    f"duplicate/case-fold-colliding generated file: {file_path}",
                    file_artifact,
                )
            all_declared_paths.add(file_path)
            all_casefold_paths.add(file_path.casefold())
            lexical_candidate = result.root / file_path
            candidate = lexical_candidate.resolve(strict=False)
            if (
                not is_within(candidate, target_directory)
                or path_has_symlink_component(lexical_candidate, result.root)
                or not candidate.is_file()
                or candidate.is_symlink()
            ):
                result.error(
                    check_id, MISSING,
                    f"generated file is missing/unsafe: {file_path}",
                    file_artifact,
                )
                continue
            content = candidate.read_bytes()
            if (
                len(content) != entry["bytes"]
                or hashlib.sha256(content).hexdigest() != entry["sha256"]
            ):
                result.error(
                    check_id,
                    "FAIL_GENERATED_TARGET_DIGEST",
                    f"generated bytes/digest drift: {file_path}",
                    file_artifact,
                )
            header = content[:1024].decode("utf-8", "replace")
            if "DO NOT EDIT" not in header.upper() or str(source_digest) not in header:
                result.error(
                    check_id,
                    "FAIL_GENERATED_TARGET_HEADER",
                    f"generated header lacks do-not-edit/source digest: {file_path}",
                    file_artifact,
                )
            files_checked += 1
        if raw_paths != sorted(raw_paths):
            result.error(
                check_id,
                "FAIL_GENERATED_TARGET_PATH",
                "generated target file inventory must be sorted",
                artifact,
            )
        actual_files = {
            path.relative_to(result.root).as_posix()
            for path in target_directory.rglob("*")
            if path.is_file() and not path.is_symlink()
        } if target_directory.is_dir() else set()
        target_symlinks = [
            path.relative_to(result.root).as_posix()
            for path in target_directory.rglob("*") if path.is_symlink()
        ] if target_directory.is_dir() else []
        if actual_files != set(raw_paths) or target_symlinks:
            result.error(
                check_id,
                "FAIL_GENERATED_TARGET_COVERAGE",
                f"generated root has unlisted/missing/symlink files: extra={sorted(actual_files - set(raw_paths))}, missing={sorted(set(raw_paths) - actual_files)}, symlinks={target_symlinks}",
                artifact,
            )
    if tuple(observed_roots) != FIXED_GENERATED_TARGET_ROOTS:
        result.error(
            check_id,
            "FAIL_GENERATED_TARGET_PATH",
            "generatedTargets must use the exact ordered Bridge TypeScript and Mobile Dart roots",
            relative,
        )
    forbidden_roots = (
        "docs/design/codex-kernel-v4/contracts/",
        "packages/conversation-contract/",
    )
    if any(
        left.startswith(right) or right.startswith(left)
        for index, left in enumerate(observed_roots)
        for right in (*observed_roots[index + 1 :], *forbidden_roots)
    ):
        result.error(
            check_id,
            "FAIL_GENERATED_TARGET_PATH",
            "generated target roots overlap each other or source/tool roots",
            relative,
        )
    replayed = False
    if reproduce is None:
        result.error(
            check_id,
            "FAIL_GENERATED_TARGET_REPRODUCTION",
            "declared generatedTargets cannot reach I01_GENERATED_READY from "
            "hashes alone; one unique generator must be replayed into a temporary "
            "root for exact byte comparison",
            relative,
        )
    else:
        try:
            with tempfile.TemporaryDirectory(
                prefix="ccpocket-v4-generated-replay-"
            ) as temporary_directory:
                replay_root = Path(temporary_directory)
                reproduce(replay_root)
                replay_symlinks = [
                    path.relative_to(replay_root).as_posix()
                    for path in replay_root.rglob("*") if path.is_symlink()
                ]
                if replay_symlinks:
                    raise ValueError(
                        "replayed output contains symlinks: "
                        + ", ".join(sorted(replay_symlinks))
                    )
                replayed_paths = {
                    path.relative_to(replay_root).as_posix()
                    for path in replay_root.rglob("*")
                    if path.is_file() and not path.is_symlink()
                }
                for target_root in FIXED_GENERATED_TARGET_ROOTS:
                    replay_directory = replay_root / target_root
                    if (
                        path_has_symlink_component(replay_directory, replay_root)
                        or not replay_directory.is_dir()
                    ):
                        raise ValueError(
                            f"replayed target root is missing/unsafe: {target_root}"
                        )
                    if any(path.is_symlink() for path in replay_directory.rglob("*")):
                        raise ValueError(
                            f"replayed target root contains symlinks: {target_root}"
                        )
                if replayed_paths != all_declared_paths:
                    raise ValueError(
                        "replayed inventory differs: "
                        f"missing={sorted(all_declared_paths - replayed_paths)}, "
                        f"extra={sorted(replayed_paths - all_declared_paths)}"
                    )
                for file_path in sorted(all_declared_paths):
                    source_bytes = (result.root / file_path).read_bytes()
                    replay_bytes = (replay_root / file_path).read_bytes()
                    if replay_bytes != source_bytes:
                        raise ValueError(
                            f"replayed bytes differ for {file_path}"
                        )
                replayed = True
        except (OSError, UnicodeError, ValueError) as exc:
            result.error(
                check_id,
                "FAIL_GENERATED_TARGET_REPRODUCTION",
                f"temporary-root generator replay failed: {exc}",
                relative,
            )
    return {
        "files": files_checked,
        "readiness": (
            "I01_GENERATED_READY"
            if replayed and len(result.errors) == errors_before
            else "I01_GENERATED_NOT_REPRODUCED"
        ),
        "source_digest": source_digest,
        "targets": len(observed_roots),
    }


def check_contract_registry(
    result: ValidationResult,
    check_id: str,
    final_config: Mapping[str, Any],
) -> Mapping[str, Any]:
    relative = str(final_config["machine_source"])
    path = result.design_root / relative
    try:
        registry = parse_json_file(path)
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError) as exc:
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_PARSE",
            f"contract registry cannot be parsed: {exc}",
            relative,
        )
        return {"arrays": 0}
    if not isinstance(registry, dict):
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_STRUCTURE",
            "contract registry must be a JSON object",
            relative,
        )
        return {"arrays": 0}
    if "P1-MESSAGE-REGISTRY.csv" in stable_json(registry):
        result.error(
            check_id,
            "FAIL_SUPERSEDED_MESSAGE_AUTHORITY",
            "the superseded 83-row message view may not feed the semantic machine source",
            relative,
        )
    missing_keys = sorted(FIXED_MACHINE_SOURCE_KEYS - set(registry))
    if missing_keys:
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_KEYS",
            f"missing keys: {', '.join(missing_keys)}",
            relative,
        )

    source_refs = registry.get("sourceRefs")
    if (
        not isinstance(source_refs, list)
        or not source_refs
        or any(not isinstance(reference, str) for reference in source_refs)
        or source_refs != sorted(source_refs)
        or len(source_refs) != len(set(source_refs))
        or any(
            not is_safe_relative_design_path(reference)
            or not (result.design_root / reference).is_file()
            or (result.design_root / reference).is_symlink()
            for reference in source_refs
        )
    ):
        result.error(
            check_id,
            "FAIL_CONTRACT_SOURCE_REFERENCE",
            "sourceRefs must be a sorted unique inventory of safe existing design-source files",
            relative,
        )
    contract = registry.get("contract")
    if not isinstance(contract, dict):
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_STRUCTURE",
            "contract metadata must be an object",
            relative,
        )
    elif (
        contract.get("protocolId") != "ccpocket.codex.kernel"
        or contract.get("protocolMajor") != 1
        or contract.get("schemaRevision") != 1
        or contract.get("designGeneration") != "v4"
        or contract.get("authority")
        != "THIS_REGISTRY_PLUS_REFERENCED_SCHEMA_AND_SQL"
        or contract.get("reviewViewsNonNormative") is not True
        or contract.get("legacyImport") != "NO_IMPORT"
        or tuple(contract.get("generatedTargets", ()))
        != FIXED_GENERATED_TARGET_ROOTS
    ):
        result.error(
            check_id,
            "FAIL_CONTRACT_METADATA",
            "contract metadata must freeze the unique source, revision/major/v4, exact two generated target policies, non-authority views, and NO_IMPORT",
            relative,
        )

    limits = registry.get("limits")
    limit_values: dict[str, Any] = {}
    if isinstance(limits, list):
        for item in limits:
            if isinstance(item, dict) and isinstance(item.get("id"), str):
                limit_values[item["id"]] = item.get("value")
    expected_limits = {
        "CONTROL_ENVELOPE_BYTES": 65536,
        "CONTROL_PAYLOAD_BYTES": 57344,
        "INTERACTION_ANSWER_BYTES": 49152,
    }
    if any(limit_values.get(key) != value for key, value in expected_limits.items()):
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_LIMITS",
            f"machine limits must include exact byte budgets: {expected_limits}",
            relative,
        )

    machine_actor_keys = {
        "source_device_id",
        "claimantid",
        "deviceid",
        "faceidpassed",
        "authenticated",
    }

    def machine_location_allows_evidence(location: str) -> bool:
        lowered = location.lower()
        return any(
            marker in lowered
            for marker in (
                "evidence",
                "negative",
                "forbidden",
                "deleted",
                "disposition",
                "sourcepath",
            )
        )

    def walk_machine_markers(node: Any, location: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                child_location = f"{location}/{key}"
                if (
                    key.lower() in machine_actor_keys
                    and not machine_location_allows_evidence(child_location)
                ):
                    result.error(
                        check_id,
                        "FAIL_CONTRACT_REGISTRY_ACTOR_ALIAS",
                        f"authoritative machine source contains forbidden actor field: {key}",
                        relative,
                    )
                walk_machine_markers(value, child_location)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk_machine_markers(value, f"{location}/{index}")
        elif isinstance(node, str):
            evidence = machine_location_allows_evidence(location) or line_has_allow_context(node)
            actor_aliases = [
                alias
                for alias in FORBIDDEN_ACTOR_ALIASES
                if alias.lower() in node.lower()
            ]
            writer_aliases = [
                alias for alias in FORBIDDEN_WRITER_ALIASES if alias in node
            ]
            legacy_markers = sorted(
                set(match.group(0) for match in LEGACY_MARKER_RE.finditer(node))
            )
            if actor_aliases and not evidence:
                result.error(
                    check_id,
                    "FAIL_CONTRACT_REGISTRY_ACTOR_ALIAS",
                    f"machine source contains actor alias: {', '.join(actor_aliases)}",
                    relative,
                )
            if writer_aliases and not evidence:
                result.error(
                    check_id,
                    "FAIL_CONTRACT_REGISTRY_WRITER_ALIAS",
                    f"machine source contains writer alias: {', '.join(writer_aliases)}",
                    relative,
                )
            if legacy_markers and not evidence:
                result.error(
                    check_id,
                    "FAIL_REACHABLE_LEGACY_MARKER",
                    f"machine source contains reachable marker: {', '.join(legacy_markers)}",
                    relative,
                )
            if "CANDIDATE_BINDING" in node:
                result.error(
                    check_id,
                    "FAIL_PHASE2_CANDIDATE_BINDING",
                    "machine source contains CANDIDATE_BINDING",
                    relative,
                )

    walk_machine_markers(registry, "#")

    key_fields = {
        "owners": "id",
        "semantics": "id",
        "capabilities": "id",
        "stateMachines": "id",
        "limits": "id",
        "messages": "kind",
        "operations": "id",
        "ports": "id",
        "laneFamilies": "id",
    }
    arrays_checked = 0
    id_sets: dict[str, set[str]] = {}
    for key, id_field in key_fields.items():
        value = registry.get(key)
        if not isinstance(value, list) or not value:
            result.error(
                check_id,
                "FAIL_CONTRACT_REGISTRY_ARRAY",
                f"{key} must be a nonempty array",
                relative,
            )
            continue
        arrays_checked += 1
        ids: list[str] = []
        for index, item in enumerate(value):
            if (
                not isinstance(item, dict)
                or not isinstance(item.get(id_field), str)
                or not item[id_field].strip()
            ):
                result.error(
                    check_id,
                    "FAIL_CONTRACT_REGISTRY_ID",
                    f"{key}[{index}] must contain a nonblank string {id_field}",
                    relative,
                )
            else:
                ids.append(item[id_field])
        if len(ids) != len(set(ids)):
            result.error(
                check_id,
                "FAIL_CONTRACT_REGISTRY_DUPLICATE_ID",
                f"{key} contains duplicate ids",
                relative,
            )
        id_sets[str(key)] = set(ids)

    operation_ids = [
        item.get("id") for item in registry.get("operations", []) if isinstance(item, dict)
    ]
    expected_operation_ids = expand_id_sequence(final_config["operation_slots"])
    if operation_ids != expected_operation_ids:
        result.error(
            check_id,
            "FAIL_OPERATION_SLOT_INVENTORY",
            "operation registry must contain OP-001..OP-039 and PX-001..PX-030 exactly",
            relative,
        )

    owner_ids = id_sets.get("owners", set())
    error_registry = registry.get("errorRegistry")
    error_entries = (
        error_registry.get("problems", [])
        if isinstance(error_registry, dict)
        else []
    )
    error_ids = {
        entry.get("code") for entry in error_entries
        if isinstance(entry, dict) and isinstance(entry.get("code"), str)
    }
    capability_ids = id_sets.get("capabilities", set())
    state_machine_ids = id_sets.get("stateMachines", set())
    lane_ids = id_sets.get("laneFamilies", set())
    observed_error_classes: set[str] = set()
    observed_retry_directives: set[str] = set()
    error_mappings: dict[str, tuple[str, str, str]] = {}
    if (
        not isinstance(error_registry, dict)
        or set(error_registry)
        != {"id", "errorClasses", "retryDirectives", "problems"}
        or error_registry.get("id") != "ErrorRegistryV1"
        or error_registry.get("errorClasses") != list(FIXED_ERROR_CLASSES)
        or error_registry.get("retryDirectives") != list(FIXED_RETRY_DIRECTIVES)
        or not isinstance(error_entries, list)
        or not error_entries
    ):
        result.error(
            check_id,
            "FAIL_ERROR_REGISTRY",
            "ErrorRegistryV1 must close id/errorClasses/retryDirectives/problems with the exact twelve/seven inventories",
            relative,
        )
        error_entries = []
    for index, entry in enumerate(error_entries):
        artifact = f"{relative}#errors/{index}"
        if not isinstance(entry, dict) or set(entry) != {
            "code", "errorClass", "retryDirective", "detailSchemaRef"
        }:
            result.error(
                check_id,
                "FAIL_ERROR_REGISTRY",
                "each error entry must contain exactly code/errorClass/retryDirective/detailSchemaRef; aliases and parallel taxonomies are forbidden",
                artifact,
            )
            continue
        code = entry.get("code")
        error_class = entry.get("errorClass")
        retry_directive = entry.get("retryDirective")
        detail_schema_ref = entry.get("detailSchemaRef")
        if (
            not isinstance(code, str)
            or not code
            or error_class not in FIXED_ERROR_CLASSES
            or retry_directive not in FIXED_RETRY_DIRECTIVES
            or not isinstance(detail_schema_ref, str)
            or not detail_schema_ref.startswith("schema/")
        ):
            result.error(
                check_id,
                "FAIL_ERROR_REGISTRY",
                "error entry has an unknown class/directive or unresolved detail schema identity",
                artifact,
            )
            continue
        observed_error_classes.add(error_class)
        observed_retry_directives.add(retry_directive)
        error_mappings[code] = (
            error_class, retry_directive, detail_schema_ref
        )
    if (
        observed_error_classes != set(FIXED_ERROR_CLASSES)
        or len(error_mappings) != len(error_entries)
    ):
        result.error(
            check_id,
            "FAIL_ERROR_REGISTRY",
            "ErrorRegistryV1 must cover exactly twelve classes and seven directives with one mapping per globally unique problemCode",
            relative,
        )
    if error_mappings.get("OUTCOME_UNKNOWN", (None, None, None))[:2] != (
        "AMBIGUITY", "READ_RECONCILE_ONLY"
    ):
        result.error(
            check_id,
            "FAIL_OUTCOME_UNKNOWN_RETRY",
            "OUTCOME_UNKNOWN must map only to AMBIGUITY/READ_RECONCILE_ONLY",
            relative,
        )
    if "ResourcePolicyStore" in owner_ids or list(owner_ids).count("AutoApprovalPolicyStore") != 1:
        result.error(
            check_id,
            "FAIL_AUTO_APPROVAL_POLICY_OWNER",
            "registry must contain the unique AutoApprovalPolicyStore and no ResourcePolicyStore alias",
            relative,
        )

    host_owner_bindings = registry.get("featureHostOwnerBindings")
    host_kinds_by_owner: dict[str, set[str]] = {}
    if not isinstance(host_owner_bindings, list) or not host_owner_bindings:
        result.error(
            check_id,
            "FAIL_FEATURE_HOST_OWNER_BINDING",
            "featureHostOwnerBindings must be a nonempty array",
            relative,
        )
        host_owner_bindings = []
    for index, binding in enumerate(host_owner_bindings):
        artifact = f"{relative}#featureHostOwnerBindings/{index}"
        if not isinstance(binding, dict) or set(binding) != {"ownerRef", "hostKinds"}:
            result.error(check_id, "FAIL_FEATURE_HOST_OWNER_BINDING", "host-owner binding must contain exactly ownerRef/hostKinds", artifact)
            continue
        owner_ref = binding.get("ownerRef")
        host_kinds = binding.get("hostKinds")
        if owner_ref not in owner_ids:
            result.error(check_id, "FAIL_FEATURE_HOST_OWNER_BINDING", f"unresolved ownerRef: {owner_ref!r}", artifact)
        if (
            not isinstance(host_kinds, list)
            or not host_kinds
            or any(value not in FEATURE_HOST_KINDS for value in host_kinds)
            or len(host_kinds) != len(set(host_kinds))
        ):
            result.error(check_id, "FAIL_FEATURE_HOST_OWNER_BINDING", "hostKinds must be a nonempty unique subset of the closed host inventory", artifact)
            continue
        if isinstance(owner_ref, str):
            if owner_ref in host_kinds_by_owner:
                result.error(check_id, "FAIL_FEATURE_HOST_OWNER_BINDING", f"duplicate owner binding: {owner_ref}", artifact)
            host_kinds_by_owner[owner_ref] = set(host_kinds)

    storage_namespaces = registry.get("storageNamespaces")
    storage_namespace_registry: dict[str, dict[str, Any]] = {}
    if not isinstance(storage_namespaces, list):
        result.error(check_id, "FAIL_FEATURE_STORAGE_NAMESPACE", "storageNamespaces must be an array", relative)
        storage_namespaces = []
    for index, namespace in enumerate(storage_namespaces):
        artifact = f"{relative}#storageNamespaces/{index}"
        if not isinstance(namespace, dict):
            result.error(check_id, "FAIL_FEATURE_STORAGE_NAMESPACE", "storage namespace must be an object", artifact)
            continue
        namespace_id = namespace.get("namespaceId")
        if not isinstance(namespace_id, str) or not namespace_id:
            result.error(check_id, "FAIL_FEATURE_STORAGE_NAMESPACE", "namespaceId must be nonblank", artifact)
            continue
        if namespace_id in storage_namespace_registry:
            result.error(check_id, "FAIL_FEATURE_STORAGE_NAMESPACE", f"duplicate namespaceId: {namespace_id}", artifact)
        storage_namespace_registry[namespace_id] = namespace
        if namespace.get("ownerRef") not in owner_ids:
            result.error(check_id, "FAIL_FEATURE_STORAGE_NAMESPACE", f"unresolved namespace owner: {namespace.get('ownerRef')!r}", artifact)

    fingerprint_policy = registry.get("fingerprintPolicy")
    if (
        not isinstance(fingerprint_policy, dict)
        or fingerprint_policy.get("id") != "CanonicalFingerprintV1"
        or fingerprint_policy.get("owner") != "OperationKernel"
        or fingerprint_policy.get("canonicalization") != "RFC8785_THEN_SHA256"
        or fingerprint_policy.get("schemaRef") != "schema/fingerprint.schema.json#/$defs/CanonicalFingerprintV1"
        or fingerprint_policy.get("numberDomain") != "INTEGER_ONLY_JSON_SAFE_RANGE; UINT64_AS_CANONICAL_DECIMAL_STRING; FLOAT_NAN_INFINITY_FORBIDDEN"
        or fingerprint_policy.get("keyOrdering") != "UTF16_CODE_UNITS"
        or fingerprint_policy.get("stringPolicy") != "JSON_REQUIRED_ESCAPES; UTF8_OUTPUT; NO_UNICODE_NORMALIZATION"
        or tuple(fingerprint_policy.get("included", ())) != FIXED_FINGERPRINT_INCLUDED
        or tuple(fingerprint_policy.get("excluded", ())) != FIXED_FINGERPRINT_EXCLUDED
        or fingerprint_policy.get("admissionComparisonOrder") != [
            "ACTOR_IMMUTABLE_MATCH_OR_OPERATION_ACTOR_MISMATCH",
            "CANONICAL_FINGERPRINT_MATCH_OR_OPERATION_FINGERPRINT_CONFLICT",
            "SAME_ID_LOOKUP_ONLY",
        ]
    ):
        result.error(
            check_id,
            "FAIL_FINGERPRINT_POLICY",
            "fingerprintPolicy must preserve exact semantic inputs, excluded admission/evidence fields, and actor-first comparison order",
            relative,
        )
    capability_snapshot_contract = registry.get("capabilitySnapshotContract")
    expected_snapshot_contract = {
        "featureSnapshotSchemaRef": "schema/domain.schema.json#/$defs/FeatureCapabilitySnapshot",
        "codexCertificationSchemaRef": "schema/domain.schema.json#/$defs/CodexAdapterCertification",
        "codexSettingsSnapshotSchemaRef": "schema/domain.schema.json#/$defs/CodexSettingsCapabilitySnapshot",
        "nativeHostSnapshotSchemaRef": "schema/domain.schema.json#/$defs/NativeHostCapabilitySnapshot",
    }
    expected_snapshot_owners = {
        "CodexAdapterCertification": "ProviderCapabilityRegistry",
        "CodexSettingsCapabilitySnapshot": "ProviderCapabilityRegistry",
        "NativeHostCapabilitySnapshot": "NativeCapabilityHost",
        "FeatureCapabilitySnapshot": "SourceRegistry",
    }
    if (
        not isinstance(capability_snapshot_contract, dict)
        or any(capability_snapshot_contract.get(key) != value for key, value in expected_snapshot_contract.items())
        or capability_snapshot_contract.get("owners") != expected_snapshot_owners
    ):
        result.error(
            check_id,
            "FAIL_CAPABILITY_EVIDENCE_SCOPE",
            "capabilitySnapshotContract must keep Codex certification, native-host evidence, and negotiated feature snapshot distinct",
            relative,
        )
    else:
        for evidence_owner in expected_snapshot_owners.values():
            if evidence_owner not in owner_ids:
                result.error(
                    check_id,
                    "FAIL_CAPABILITY_EVIDENCE_SCOPE",
                    f"capability evidence owner is unresolved: {evidence_owner}",
                    relative,
                )

    materialization_verifier = registry.get("materializationVerifier")
    if (
        not isinstance(materialization_verifier, dict)
        or materialization_verifier.get("id") != "MaterializationVerifierV1"
        or materialization_verifier.get("authority")
        != "PURE_DETERMINISTIC_ALGORITHM_NO_WRITE_PORT"
        or materialization_verifier.get("ownerResolution") != {
            "CATALOG": "ConversationCatalogWriter",
            "TIMELINE": "CanonicalTimelineWriter",
        }
        or materialization_verifier.get("receiptSchemaResolution") != {
            "CATALOG": "schema/domain.schema.json#/$defs/CatalogMaterializationVerificationReceiptV1",
            "TIMELINE": "schema/domain.schema.json#/$defs/TimelineMaterializationVerificationReceiptV1",
        }
        or set(materialization_verifier.get("inputSchemaRefs", ()))
        != {
            "schema/durable-event.schema.json#/$defs/MaterializationBeginPayloadV1",
            "schema/durable-event.schema.json#/$defs/MaterializationPagePayloadV1",
            "schema/durable-event.schema.json#/$defs/MaterializationCommitPayloadV1",
        }
        or not isinstance(materialization_verifier.get("algorithm"), list)
        or len(materialization_verifier["algorithm"]) < 10
        or not isinstance(materialization_verifier.get("failure"), str)
    ):
        result.error(
            check_id,
            "FAIL_MATERIALIZATION_VERIFIER_CONTRACT",
            "MaterializationVerifierV1 must be pure/no-writer, derive CATALOG/TIMELINE writer from subject, and bind begin/page/commit, graph receipt, and last-good failure",
            relative,
        )
    decoder_contract = registry.get("decoderContract")
    if (
        not isinstance(decoder_contract, dict)
        or decoder_contract.get("owner") != "AuthenticatedTransport"
        or decoder_contract.get("ordering") != [
            "FRAME_UTF8_BYTE_LIMIT", "UTF8_DECODE", "DUPLICATE_KEY_REJECT",
            "JSON_PARSE", "ENVELOPE_SCHEMA", "PAYLOAD_UTF8_BYTE_LIMIT",
            "PAYLOAD_SCHEMA", "ACTOR_ALIAS_PRESCAN", "ADMISSION",
        ]
        or decoder_contract.get("frameLimitRef") != "CONTROL_ENVELOPE_BYTES"
        or decoder_contract.get("payloadLimitRef") != "CONTROL_PAYLOAD_BYTES"
        or decoder_contract.get("interactionAnswerLimitRef") != "INTERACTION_ANSWER_BYTES"
        or set(decoder_contract.get("invalidZeroEffects", ()))
        != FIXED_PREDECODE_ZERO_EFFECTS
    ):
        result.error(
            check_id,
            "FAIL_PREDECODE_CAPACITY_CONTRACT",
            "decoderContract must enforce exact byte gates before decode with the closed zero-effect oracle",
            relative,
        )
    feature_host_resolution = registry.get("featureHostResolution")
    if feature_host_resolution != {
        "profiles": [
            {"profileId": "MOBILE_IOS", "nativeHostKind": "NATIVE_IOS"},
            {"profileId": "MOBILE_ANDROID", "nativeHostKind": "NATIVE_ANDROID"},
        ],
        "rule": "NATIVE_HOST required role is satisfied only by a descriptor for the exact current nativeHostKind; another platform never satisfies it",
        "missing": "support UNKNOWN and availability TEMPORARILY_UNAVAILABLE until current-host evidence exists",
    }:
        result.error(
            check_id,
            "FAIL_FEATURE_HOST_RESOLUTION",
            "featureHostResolution must bind exact upstream native host and fail closed; cross-platform candidate mapping is forbidden",
            relative,
        )

    references_checked = 0

    def require_reference(value: Any, targets: set[str], location: str, kind: str) -> None:
        nonlocal references_checked
        references_checked += 1
        if not isinstance(value, str) or value not in targets:
            result.error(
                check_id,
                "FAIL_CONTRACT_REGISTRY_REFERENCE",
                f"{location} does not resolve in {kind}: {value!r}",
                relative,
            )

    for collection in ("semantics", "capabilities", "stateMachines", "ports"):
        for index, item in enumerate(registry.get(collection, [])):
            if isinstance(item, dict):
                if (
                    collection == "stateMachines"
                    and item.get("id") == "SM-MATERIALIZATION"
                ):
                    owner_resolution = item.get("ownerResolution")
                    if owner_resolution != {
                        "CATALOG": "ConversationCatalogWriter",
                        "TIMELINE": "CanonicalTimelineWriter",
                    }:
                        result.error(
                            check_id,
                            "FAIL_STATE_MACHINE_OWNER_RESOLUTION",
                            "SM-MATERIALIZATION owner must derive exactly from sealed CATALOG/TIMELINE subject",
                            f"{relative}#/{collection}/{index}/ownerResolution",
                        )
                    else:
                        for owner in owner_resolution.values():
                            require_reference(
                                owner, owner_ids,
                                f"#/{collection}/{index}/ownerResolution",
                                "owners",
                            )
                else:
                    require_reference(item.get("owner"), owner_ids, f"#/{collection}/{index}/owner", "owners")
    for index, item in enumerate(registry.get("contentResponsibilities", [])):
        if isinstance(item, dict):
            require_reference(item.get("owner"), owner_ids, f"#/contentResponsibilities/{index}/owner", "owners")
    expected_support = (
        "SUPPORTED", "UNSUPPORTED", "REQUIRES_BASE_APP_UPDATE", "UNKNOWN"
    )
    expected_availability = (
        "AVAILABLE", "TEMPORARILY_UNAVAILABLE", "POLICY_DISABLED",
        "RESOURCE_EXHAUSTED", "UNKNOWN"
    )
    capability_owner: dict[str, str] = {}
    for index, capability in enumerate(registry.get("capabilities", [])):
        if not isinstance(capability, dict):
            continue
        capability_owner[str(capability.get("id"))] = str(capability.get("owner", ""))
        support = capability.get("supportAxis")
        availability = capability.get("availabilityAxis")
        if support != list(expected_support):
            result.error(check_id, "FAIL_CAPABILITY_SUPPORT_AXIS", "supportAxis is incomplete or mixed with availability", f"{relative}#capabilities/{index}")
        if availability != list(expected_availability):
            result.error(check_id, "FAIL_CAPABILITY_AVAILABILITY_AXIS", "availabilityAxis is incomplete or mixed with support", f"{relative}#capabilities/{index}")

    for index, message in enumerate(registry.get("messages", [])):
        if not isinstance(message, dict):
            continue
        capability = message.get("capability")
        require_reference(capability, capability_ids, f"#/messages/{index}/capability", "capabilities")
        if isinstance(capability, str) and capability in capability_owner:
            require_reference(capability_owner[capability], owner_ids, f"#/messages/{index}/effectiveOwner", "owners")
        for error in message.get("errors", []):
            require_reference(error, error_ids, f"#/messages/{index}/errors", "errors")

    for index, operation in enumerate(registry.get("operations", [])):
        if not isinstance(operation, dict):
            continue
        artifact = f"{relative}#operations/{index}"
        require_reference(operation.get("owner"), owner_ids, f"#/operations/{index}/owner", "owners")
        require_reference(operation.get("domainOwner"), owner_ids, f"#/operations/{index}/domainOwner", "owners")
        for error in operation.get("errors", []):
            require_reference(error, error_ids, f"#/operations/{index}/errors", "errors")
        for machine in operation.get("stateMachines", []):
            require_reference(machine, state_machine_ids, f"#/operations/{index}/stateMachines", "stateMachines")
        queue_selector = operation.get("queueLaneSelector")
        if queue_selector is not None:
            require_reference(queue_selector, lane_ids, f"#/operations/{index}/queueLaneSelector", "laneFamilies")
        conflicts = operation.get("executionConflictSelectors")
        if not isinstance(conflicts, list):
            result.error(check_id, "FAIL_OPERATION_CONFLICT_SELECTORS", "executionConflictSelectors must be an array distinct from queueLaneSelector", artifact)
        else:
            for selector in conflicts:
                require_reference(selector, lane_ids, f"#/operations/{index}/executionConflictSelectors", "laneFamilies")
        if operation.get("id") in {"OP-038", "OP-039"} and operation.get("domainOwner") != "AutoApprovalPolicyStore":
            result.error(
                check_id,
                "FAIL_AUTO_APPROVAL_POLICY_OWNER",
                "OP-038/OP-039 domain owner must be AutoApprovalPolicyStore",
                artifact,
            )

    public_operation_ids = {
        item.get("id")
        for item in registry.get("operations", [])
        if isinstance(item, dict) and item.get("exposure") == "PUBLIC"
    }

    expected_operation_refs = registry.get("expectedOperationRefs")
    if expected_operation_refs != list(FIXED_EXPECTED_OPERATION_REFS):
        result.error(
            check_id,
            "FAIL_EXPECTED_OPERATION_REFS",
            "expectedOperationRefs must equal the independent P-007/P-014/P-025 to OP inventory",
            relative,
        )
    expected_operations_by_capability = {
        item["capabilityId"]: item
        for item in FIXED_EXPECTED_OPERATION_REFS
    }
    independent_source_ids: dict[str, set[str]] = {}
    for source_path, candidate_columns in (
        (
            "drafts/P2-CAPABILITY-P001-P013.csv",
            ("capability_id", "id"),
        ),
        (
            "drafts/P2-CAPABILITY-P014-P026.csv",
            ("capability_id", "id"),
        ),
        (
            "drafts/P1-OPERATION-STATE-MATRIX.csv",
            ("mutation_id", "operation_id", "id"),
        ),
    ):
        ids: set[str] = set()
        try:
            with (result.design_root / source_path).open(
                "r", encoding="utf-8-sig", newline=""
            ) as handle:
                reader = csv.DictReader(handle, strict=True)
                fieldnames = set(reader.fieldnames or ())
                id_column = next(
                    (column for column in candidate_columns if column in fieldnames),
                    None,
                )
                if id_column is not None:
                    ids = {
                        row[id_column].strip()
                        for row in reader
                        if isinstance(row.get(id_column), str)
                        and row[id_column].strip()
                    }
        except (OSError, UnicodeError, csv.Error):
            pass
        independent_source_ids[source_path] = ids
    source_inventory_failures: list[str] = []
    for item in FIXED_EXPECTED_OPERATION_REFS:
        capability_id = item["capabilityId"]
        capability_source = item["independentSources"][0].split("#", 1)[0]
        if capability_id not in independent_source_ids.get(capability_source, set()):
            source_inventory_failures.append(capability_id)
        operation_source = item["independentSources"][1].split("#", 1)[0]
        missing_operations = set(item["operationIds"]) - independent_source_ids.get(
            operation_source, set()
        )
        source_inventory_failures.extend(sorted(missing_operations))
    if source_inventory_failures:
        result.error(
            check_id,
            "FAIL_EXPECTED_OPERATION_SOURCE",
            "independent capability/operation CSV evidence is missing: "
            + ", ".join(source_inventory_failures),
            relative,
        )

    if registry.get("durableEventContract") != FIXED_DURABLE_EVENT_CONTRACT:
        result.error(
            check_id,
            "FAIL_DURABLE_EVENT_CONTRACT",
            "durableEventContract must separate EventKey/MessageKey, exclude only messageDigest from its preimage, keep frame metadata outside protocol, and close 0..128 whole blocks",
            relative,
        )
    if registry.get("expectedAggregateEventInventory") != list(
        FIXED_EXPECTED_AGGREGATE_EVENTS
    ):
        result.error(
            check_id,
            "FAIL_AGGREGATE_EVENT_INVENTORY",
            "expectedAggregateEventInventory must equal the independent ten aggregate/event/owner rows",
            relative,
        )

    lane_values = [
        item.get("id") for item in registry.get("laneFamilies", []) if isinstance(item, dict)
    ]
    if lane_values != list(final_config["lane_inventory"]):
        result.error(
            check_id,
            "FAIL_LANE_INVENTORY",
            "laneFamilies must contain the exact twelve frozen lanes in order",
            relative,
        )
    for index, lane in enumerate(registry.get("laneFamilies", [])):
        if not isinstance(lane, dict):
            continue
        if selector_has_forbidden_scope(lane):
            result.error(check_id, "FAIL_R14_FORBIDDEN_LANE_SCOPE", "lane family uses generic/global/path/route scope", f"{relative}#laneFamilies/{index}")
        keys = lane.get("canonicalKeyFields")
        if not isinstance(keys, list) or not keys or any(not isinstance(value, str) or not value for value in keys):
            result.error(check_id, "FAIL_LANE_KEY_FIELDS", "canonicalKeyFields must be a nonempty string array", f"{relative}#laneFamilies/{index}")

    vector_path = result.design_root / str(final_config["vector_source"])
    vector_ids: set[str] = set()
    try:
        vector_document = parse_json_file(vector_path)
        if isinstance(vector_document, dict):
            for vectors in vector_document.values():
                if isinstance(vectors, list):
                    for vector in vectors:
                        if isinstance(vector, dict) and isinstance(vector.get("id"), str):
                            vector_ids.add(vector["id"])
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError):
        pass

    machines = registry.get("stateMachines", [])
    canonical_sm_path = result.design_root / "06-STATE-MACHINES-AND-SEMANTIC-AXES.md"
    canonical_sm_ids: list[str] = []
    if canonical_sm_path.is_file():
        for identifier in re.findall(r"`(SM-[A-Z0-9-]+)`", read_text(canonical_sm_path)):
            if identifier not in canonical_sm_ids:
                canonical_sm_ids.append(identifier)
    if len(canonical_sm_ids) != int(final_config["state_machine_count"]):
        result.error(
            check_id,
            "FAIL_CANONICAL_STATE_MACHINE_INVENTORY",
            f"06 must define exactly {final_config['state_machine_count']} unique state machines; found {len(canonical_sm_ids)}",
            "06-STATE-MACHINES-AND-SEMANTIC-AXES.md",
        )
    registry_sm_ids = [
        item.get("id") for item in machines if isinstance(item, dict)
    ] if isinstance(machines, list) else []
    if registry_sm_ids != canonical_sm_ids:
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_INVENTORY",
            "registry stateMachines must match the ordered 06 inventory exactly (no omitted or invented Plan machine)",
            relative,
        )

    machines_by_id = {
        item.get("id"): item
        for item in machines
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }

    def require_exact_machine(
        machine_id: str,
        states: Sequence[str],
        transitions: Sequence[tuple[str, str]],
    ) -> None:
        machine = machines_by_id.get(machine_id)
        actual_states = machine.get("states", ()) if isinstance(machine, dict) else ()
        actual_edges = machine.get("transitions", ()) if isinstance(machine, dict) else ()
        actual_edge_tuples = [
            tuple(edge)
            for edge in actual_edges
            if isinstance(edge, list) and len(edge) == 2
        ] if isinstance(actual_edges, list) else []
        if (
            not isinstance(machine, dict)
            or not isinstance(actual_states, list)
            or any(not isinstance(state, str) for state in actual_states)
            or len(actual_states) != len(set(actual_states))
            or set(actual_states) != set(states)
            or len(actual_edge_tuples) != len(actual_edges)
            or len(actual_edge_tuples) != len(set(actual_edge_tuples))
            or set(actual_edge_tuples) != set(transitions)
        ):
            result.error(
                check_id,
                "FAIL_STATE_MACHINE_EXACT_SET",
                f"{machine_id} states/edges differ from the R38 authoritative set",
                relative,
            )

    require_exact_machine(
        "SM-MATERIALIZATION",
        ("STAGING", "SEALED", "REJECTED", "QUARANTINED"),
        (
            ("STAGING", "SEALED"),
            ("STAGING", "REJECTED"),
            ("STAGING", "QUARANTINED"),
        ),
    )
    require_exact_machine(
        "SM-OPERATION",
        (
            "RECEIVED", "REJECTED_BEFORE_ADMISSION", "ADMITTED", "QUEUED",
            "BLOCKED_PRECONDITION", "READY", "DISPATCHING",
            "PROVIDER_ACCEPTED", "AWAITING_EFFECT_OBSERVATION", "SUCCEEDED",
            "FAILED_DEFINITIVE", "OUTCOME_UNKNOWN", "CANCELLED_PRE_DISPATCH",
        ),
        (
            ("RECEIVED", "REJECTED_BEFORE_ADMISSION"),
            ("RECEIVED", "ADMITTED"),
            ("ADMITTED", "QUEUED"),
            ("ADMITTED", "BLOCKED_PRECONDITION"),
            ("ADMITTED", "READY"),
            ("QUEUED", "READY"),
            ("BLOCKED_PRECONDITION", "READY"),
            ("READY", "DISPATCHING"),
            ("DISPATCHING", "PROVIDER_ACCEPTED"),
            ("DISPATCHING", "FAILED_DEFINITIVE"),
            ("DISPATCHING", "OUTCOME_UNKNOWN"),
            ("PROVIDER_ACCEPTED", "AWAITING_EFFECT_OBSERVATION"),
            ("AWAITING_EFFECT_OBSERVATION", "SUCCEEDED"),
            ("AWAITING_EFFECT_OBSERVATION", "FAILED_DEFINITIVE"),
            ("ADMITTED", "CANCELLED_PRE_DISPATCH"),
            ("QUEUED", "CANCELLED_PRE_DISPATCH"),
            ("BLOCKED_PRECONDITION", "CANCELLED_PRE_DISPATCH"),
            ("READY", "CANCELLED_PRE_DISPATCH"),
        ),
    )
    require_exact_machine(
        "SM-CATALOG-HEAD",
        ("ABSENT", "PRESENT"),
        (("ABSENT", "PRESENT"), ("PRESENT", "PRESENT")),
    )
    require_exact_machine(
        "SM-TIMELINE-HEAD",
        ("ABSENT", "PRESENT", "TOMBSTONED_PROVEN"),
        (
            ("ABSENT", "PRESENT"),
            ("PRESENT", "PRESENT"),
            ("PRESENT", "TOMBSTONED_PROVEN"),
        ),
    )
    replica_nonterminal = (
        "RECEIVED", "STAGED", "APPLIED", "READBACK_VERIFIED", "PUBLISHED"
    )
    require_exact_machine(
        "SM-REPLICA-APPLY",
        (*replica_nonterminal, "ACKED", "REJECTED", "SNAPSHOT_REQUIRED"),
        (
            ("RECEIVED", "STAGED"),
            ("STAGED", "APPLIED"),
            ("APPLIED", "READBACK_VERIFIED"),
            ("READBACK_VERIFIED", "PUBLISHED"),
            ("PUBLISHED", "ACKED"),
            *tuple(
                (source, target)
                for source in replica_nonterminal
                for target in ("REJECTED", "SNAPSHOT_REQUIRED")
            ),
        ),
    )
    offer_progress = ("OFFERED", "TRANSFERRING", "VERIFYING")
    require_exact_machine(
        "SM-CONTENT-OFFER",
        (
            "OFFERED", "TRANSFERRING", "VERIFYING", "FINALIZING",
            "FINALIZED", "FAILED", "CANCELLED", "EXPIRED",
        ),
        (
            ("OFFERED", "TRANSFERRING"),
            ("TRANSFERRING", "VERIFYING"),
            ("VERIFYING", "FINALIZING"),
            ("FINALIZING", "FINALIZED"),
            *tuple(
                (source, target)
                for source in offer_progress
                for target in ("FAILED", "CANCELLED", "EXPIRED")
            ),
            ("FINALIZING", "FAILED"),
        ),
    )
    interaction_open = (
        "OPEN_UNCLAIMED", "OPEN_CLAIMED", "RESPONSE_PENDING"
    )
    interaction_terminal = ("RESOLVED", "WITHDRAWN", "STALE", "EXPIRED")
    require_exact_machine(
        "SM-INTERACTION",
        (*interaction_open, *interaction_terminal),
        (
            ("OPEN_UNCLAIMED", "OPEN_CLAIMED"),
            ("OPEN_CLAIMED", "OPEN_UNCLAIMED"),
            ("OPEN_CLAIMED", "RESPONSE_PENDING"),
            *tuple(
                (source, target)
                for source in interaction_open
                for target in interaction_terminal
            ),
        ),
    )
    require_exact_machine(
        "SM-SETTINGS-SNAPSHOT",
        ("ABSENT", "PRESENT"),
        (("ABSENT", "PRESENT"), ("PRESENT", "PRESENT")),
    )
    goal_present = ("ACTIVE", "PAUSED", "BUDGET_LIMITED", "COMPLETED")
    require_exact_machine(
        "SM-GOAL",
        ("ABSENT_PROVEN", *goal_present, "CLEARED_PROVEN"),
        (
            *tuple(
                ("ABSENT_PROVEN", target)
                for target in (*goal_present, "CLEARED_PROVEN")
            ),
            *tuple(
                (source, target)
                for source in goal_present
                for target in (*goal_present, "ABSENT_PROVEN", "CLEARED_PROVEN")
            ),
            *tuple(
                ("CLEARED_PROVEN", target)
                for target in (*goal_present, "ABSENT_PROVEN")
            ),
        ),
    )

    state_machine_bindings = registry.get("stateMachineBindings")
    binding_machine_ids = [
        value.get("stateMachine")
        for value in state_machine_bindings
        if isinstance(value, dict)
    ] if isinstance(state_machine_bindings, list) else []
    if binding_machine_ids != registry_sm_ids:
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_DDL_BINDING",
            "stateMachineBindings must cover the exact ordered state-machine inventory",
            relative,
        )
        state_machine_bindings = state_machine_bindings if isinstance(state_machine_bindings, list) else []
    ddl_connections: dict[str, sqlite3.Connection] = {}
    try:
        for database, ddl_relative in zip(
            ("bridge", "mobile"), final_config.get("ddl_files", ())
        ):
            connection = sqlite3.connect(":memory:")
            load_ddl(connection, [result.design_root / str(ddl_relative)])
            ddl_connections[database] = connection
        for index, machine_binding in enumerate(state_machine_bindings):
            artifact = f"{relative}#stateMachineBindings/{index}"
            if (
                not isinstance(machine_binding, dict)
                or set(machine_binding) != {"stateMachine", "storageMode", "ddlBindings"}
                or not isinstance(machine_binding.get("storageMode"), str)
                or not machine_binding["storageMode"]
                or not isinstance(machine_binding.get("ddlBindings"), list)
            ):
                result.error(check_id, "FAIL_STATE_MACHINE_DDL_BINDING", "state-machine binding has an invalid closed shape", artifact)
                continue
            seen_bindings: set[tuple[str, str, str]] = set()
            for ddl_binding in machine_binding["ddlBindings"]:
                allowed_binding_fields = {
                    "database", "table", "stateColumn", "transitionTriggers",
                    "initialTrigger", "allowedChangedTables", "mutationColumns",
                }
                if (
                    not isinstance(ddl_binding, dict)
                    or set(ddl_binding) - allowed_binding_fields
                    or not {
                        "database", "table", "stateColumn", "transitionTriggers",
                        "initialTrigger", "allowedChangedTables", "mutationColumns",
                    }.issubset(ddl_binding)
                ):
                    result.error(check_id, "FAIL_STATE_MACHINE_DDL_BINDING", "DDL binding has an invalid closed shape", artifact)
                    continue
                database = ddl_binding.get("database")
                table = ddl_binding.get("table")
                state_column = ddl_binding.get("stateColumn")
                triggers = ddl_binding.get("transitionTriggers")
                initial_trigger = ddl_binding.get("initialTrigger")
                allowed_changed_tables = ddl_binding.get("allowedChangedTables")
                mutation_columns = ddl_binding.get("mutationColumns")
                if (
                    not isinstance(allowed_changed_tables, list)
                    or any(
                        not isinstance(changed_table, str) or not changed_table
                        for changed_table in allowed_changed_tables
                    )
                    or allowed_changed_tables
                    != sorted(set(allowed_changed_tables))
                    or table not in allowed_changed_tables
                ):
                    result.error(
                        check_id, "FAIL_STATE_MACHINE_DDL_BINDING",
                        "allowedChangedTables must be a sorted independent effect inventory containing the target table",
                        artifact,
                    )
                    continue
                if (
                    not isinstance(triggers, list)
                    or not triggers
                    or any(not isinstance(trigger, str) or not trigger for trigger in triggers)
                    or len(triggers) != len(set(triggers))
                ):
                    result.error(
                        check_id, "FAIL_STATE_MACHINE_DDL_BINDING",
                        "transitionTriggers must be a nonempty unique trigger-name array",
                        artifact,
                    )
                    continue
                key = (str(database), str(table), str(state_column))
                if key in seen_bindings:
                    result.error(check_id, "FAIL_STATE_MACHINE_DDL_BINDING", f"duplicate DDL binding {key}", artifact)
                seen_bindings.add(key)
                connection = ddl_connections.get(str(database))
                if connection is None:
                    result.error(check_id, "FAIL_STATE_MACHINE_DDL_BINDING", f"unknown database {database!r}", artifact)
                    continue
                table_row = connection.execute(
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
                    (table,),
                ).fetchone()
                table_columns = (
                    sqlite_introspection(connection, "table_info", str(table))
                    if table_row else []
                )
                columns = {str(row[1]) for row in table_columns}
                primary_key_columns = {
                    str(row[1]) for row in table_columns if int(row[5] or 0) > 0
                }
                if not table_row or state_column not in columns:
                    result.error(
                        check_id,
                        "FAIL_STATE_MACHINE_DDL_BINDING",
                        f"unresolved table/state column: {database}.{table}.{state_column}",
                        artifact,
                    )
                    continue
                if (
                    not isinstance(mutation_columns, dict)
                    or set(mutation_columns) != {"INITIAL", "TRANSITION"}
                    or any(
                        not isinstance(mutation_columns.get(phase), list)
                        or not mutation_columns[phase]
                        or mutation_columns[phase]
                        != sorted(set(mutation_columns[phase]))
                        or any(
                            not isinstance(column, str) or not column
                            for column in mutation_columns[phase]
                        )
                        or state_column not in mutation_columns[phase]
                        or set(mutation_columns[phase]) - columns
                        for phase in ("INITIAL", "TRANSITION")
                    )
                    or not primary_key_columns.issubset(
                        set(mutation_columns["INITIAL"])
                    )
                    or bool(
                        primary_key_columns
                        & set(mutation_columns["TRANSITION"])
                    )
                ):
                    result.error(
                        check_id,
                        "FAIL_STATE_MACHINE_DDL_BINDING",
                        "mutationColumns must independently close the existing "
                        "INITIAL/TRANSITION target columns",
                        artifact,
                    )
                    continue
                database_tables = {
                    str(row[0])
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    )
                }
                if set(allowed_changed_tables) - (
                    database_tables | {"sqlite_sequence"}
                ):
                    result.error(
                        check_id,
                        "FAIL_STATE_MACHINE_DDL_BINDING",
                        "allowedChangedTables contains an unresolved table",
                        artifact,
                    )
                    continue
                machine = machines_by_id.get(machine_binding.get("stateMachine"))
                expected_edges = {
                    tuple(edge)
                    for edge in machine.get("transitions", ())
                    if isinstance(edge, list) and len(edge) == 2
                } if isinstance(machine, dict) else set()
                actual_edges: set[tuple[str, str]] = set()
                unresolved_triggers: list[str] = []
                state_trigger_errors: list[str] = []
                all_trigger_rows = connection.execute(
                    "SELECT name, sql FROM sqlite_master WHERE type='trigger'"
                ).fetchall()
                marker_owners: dict[str, set[str]] = {}
                for trigger_name, trigger_definition in all_trigger_rows:
                    for marker in re.findall(
                        r"(?is)RAISE\s*\(\s*ABORT\s*,\s*'([^']+)'\s*\)",
                        str(trigger_definition or ""),
                    ):
                        marker_owners.setdefault(marker, set()).add(
                            str(trigger_name)
                        )
                for trigger in triggers:
                    trigger_row = connection.execute(
                        "SELECT tbl_name, sql FROM sqlite_master WHERE type='trigger' AND name=?",
                        (trigger,),
                    ).fetchone()
                    if not trigger_row or trigger_row[0] != table:
                        unresolved_triggers.append(trigger)
                        continue
                    trigger_sql = strip_sql_comments(str(trigger_row[1] or ""))
                    trigger_edges = extract_sql_trigger_edges(
                        trigger_sql, str(state_column)
                    )
                    row_columns = {
                        match.group(1)
                        for match in re.finditer(
                            r"(?is)\b(?:OLD|NEW)\.([A-Za-z_][A-Za-z0-9_]*)",
                            trigger_sql,
                        )
                    }
                    trigger_markers = set(re.findall(
                        r"(?is)RAISE\s*\(\s*ABORT\s*,\s*'([^']+)'\s*\)",
                        trigger_sql,
                    ))
                    if (
                        not trigger_edges
                        or row_columns != {state_column}
                        or re.search(r"(?is)\b(?:EXISTS|FROM)\b", trigger_sql)
                        or not trigger_markers
                        or any(
                            marker_owners.get(marker) != {trigger}
                            for marker in trigger_markers
                        )
                    ):
                        state_trigger_errors.append(trigger)
                    actual_edges.update(trigger_edges)
                if unresolved_triggers:
                    result.error(
                        check_id, "FAIL_STATE_MACHINE_DDL_BINDING",
                        "unresolved transition triggers: "
                        + ", ".join(unresolved_triggers), artifact,
                    )
                    continue
                if state_trigger_errors:
                    result.error(
                        check_id,
                        "FAIL_STATE_MACHINE_DDL_BINDING",
                        "transition triggers must be pure state-column guards "
                        "with nonempty edges and globally unique literal markers: "
                        + ", ".join(state_trigger_errors),
                        artifact,
                    )
                    continue
                if (
                    not isinstance(initial_trigger, dict)
                    or set(initial_trigger) not in (
                        {"name", "toState", "contributesTransition"},
                        {
                            "name", "fromState", "toState",
                            "contributesTransition",
                        },
                    )
                    or not isinstance(initial_trigger.get("name"), str)
                    or not initial_trigger.get("name")
                    or not isinstance(initial_trigger.get("toState"), str)
                    or not initial_trigger.get("toState")
                    or not isinstance(
                        initial_trigger.get("contributesTransition"), bool
                    )
                    or (
                        initial_trigger.get("contributesTransition") is True
                        and (
                            not isinstance(initial_trigger.get("fromState"), str)
                            or not initial_trigger.get("fromState")
                        )
                    )
                ):
                    result.error(
                        check_id, "FAIL_STATE_MACHINE_DDL_BINDING",
                        "initialTrigger has an invalid closed shape", artifact,
                    )
                    continue
                initial_row = connection.execute(
                    "SELECT tbl_name, sql FROM sqlite_master "
                    "WHERE type='trigger' AND name=?",
                    (initial_trigger["name"],),
                ).fetchone()
                initial_sql = strip_sql_comments(
                    str(initial_row[1] or "") if initial_row else ""
                )
                initial_row_columns = {
                    match.group(1)
                    for match in re.finditer(
                        r"(?is)\b(?:OLD|NEW)\.([A-Za-z_][A-Za-z0-9_]*)",
                        initial_sql,
                    )
                }
                initial_markers = set(re.findall(
                    r"(?is)RAISE\s*\(\s*ABORT\s*,\s*'([^']+)'\s*\)",
                    initial_sql,
                ))
                initial_state_pattern = re.compile(
                    rf"(?is)NEW\.{re.escape(str(state_column))}\s*"
                    rf"(?:=|<>|IS(?:\s+NOT)?)\s*'"
                    rf"{re.escape(initial_trigger['toState'])}'"
                )
                if (
                    not initial_row
                    or initial_row[0] != table
                    or not re.search(r"(?is)BEFORE\s+INSERT\s+ON", initial_sql)
                    or not initial_state_pattern.search(initial_sql)
                    or initial_row_columns != {state_column}
                    or re.search(r"(?is)\b(?:EXISTS|FROM)\b", initial_sql)
                    or not initial_markers
                    or any(
                        marker_owners.get(marker) != {initial_trigger["name"]}
                        for marker in initial_markers
                    )
                ):
                    result.error(
                        check_id, "FAIL_STATE_MACHINE_DDL_BINDING",
                        "initialTrigger must be an executable INSERT guard for its toState",
                        artifact,
                    )
                    continue
                if initial_trigger["contributesTransition"]:
                    actual_edges.add((
                        initial_trigger["fromState"],
                        initial_trigger["toState"],
                    ))
                if not expected_edges or actual_edges != expected_edges:
                    result.error(
                        check_id,
                        "FAIL_STATE_MACHINE_DDL_EDGE_EQUALITY",
                        f"{database}.{','.join(triggers)} edges differ from {machine_binding.get('stateMachine')}: "
                        f"expected={len(expected_edges)}, actual={len(actual_edges)}",
                        artifact,
                    )
    except (OSError, UnicodeError, sqlite3.Error, ValueError) as exc:
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_DDL_BINDING",
            f"cannot validate state-machine DDL bindings in memory: {exc}",
            relative,
        )
    finally:
        for connection in ddl_connections.values():
            connection.close()
    memory_machine_tokens: list[str] = []
    machine_negative_vectors: list[str] = []
    for index, machine in enumerate(machines):
        artifact = f"{relative}#stateMachines/{index}"
        if not isinstance(machine, dict):
            continue
        required = (
            "id", "initial", "terminal", "states", "transitions",
            "wireProjection", "storage", "negativeVector",
        ) + (
            ("ownerResolution",)
            if machine.get("id") == "SM-MATERIALIZATION"
            else ("owner",)
        )
        missing = [key for key in required if key not in machine]
        if missing:
            result.error(check_id, "FAIL_STATE_MACHINE_FIELDS", f"missing fields: {', '.join(missing)}", artifact)
            continue
        states = machine.get("states")
        terminal = machine.get("terminal")
        transitions = machine.get("transitions")
        terminals = (
            [] if terminal == "NONE"
            else terminal if isinstance(terminal, list)
            else [terminal]
        )
        if not isinstance(states, list) or not states or len(states) != len(set(states)):
            result.error(check_id, "FAIL_STATE_MACHINE_STATES", "states must be a nonempty unique array", artifact)
            states = []
        if machine.get("initial") not in states or any(value not in states for value in terminals):
            result.error(check_id, "FAIL_STATE_MACHINE_BOUNDARY", "initial and every terminal must resolve in states", artifact)
        if not isinstance(transitions, list) or not transitions:
            result.error(check_id, "FAIL_STATE_MACHINE_TRANSITIONS", "transitions must be nonempty", artifact)
        else:
            for transition in transitions:
                if not isinstance(transition, list) or len(transition) != 2 or any(value not in states for value in transition):
                    result.error(check_id, "FAIL_STATE_MACHINE_TRANSITIONS", f"invalid transition: {transition!r}", artifact)
        if not isinstance(machine.get("wireProjection"), str) or not machine["wireProjection"].strip():
            result.error(check_id, "FAIL_STATE_MACHINE_WIRE", "wireProjection must be nonblank", artifact)
        if (
            machine.get("id") == "SM-EPHEMERAL-CHILD"
            and re.search(r"(?i)durable|outbox|checkpoint", str(machine.get("wireProjection")))
        ):
            result.error(
                check_id,
                "FAIL_EPHEMERAL_DURABLE_MESSAGE",
                "SM-EPHEMERAL-CHILD may not have a durable/wire message projection",
                artifact,
            )
        if not isinstance(machine.get("storage"), str) or not machine["storage"].strip():
            result.error(check_id, "FAIL_STATE_MACHINE_STORAGE", "storage must be nonblank", artifact)
        elif machine["storage"] == "MEMORY_ONLY":
            memory_machine_tokens.append(str(machine.get("id", "")).removeprefix("SM-").lower().replace("-", "_"))
        require_reference(machine.get("negativeVector"), vector_ids, f"#/stateMachines/{index}/negativeVector", "contract vectors")
        if isinstance(machine.get("negativeVector"), str):
            machine_negative_vectors.append(machine["negativeVector"])

    if (
        len(machine_negative_vectors) != int(final_config["state_machine_count"])
        or len(machine_negative_vectors) != len(set(machine_negative_vectors))
    ):
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_VECTOR_COVERAGE",
            f"all {final_config['state_machine_count']} state machines must bind distinct registered negative vectors",
            relative,
        )

    ddl_paths = [result.design_root / str(value) for value in final_config["ddl_files"]]
    table_names: set[str] = set()
    for ddl_path in ddl_paths:
        if ddl_path.is_file():
            table_names.update(
                name.lower()
                for name in re.findall(
                    r"(?i)\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[\"`\[]?([A-Za-z_][A-Za-z0-9_]*)",
                    read_text(ddl_path),
                )
            )
    for token in memory_machine_tokens:
        normalized_token = re.sub(r"[^a-z0-9]", "", token.lower())
        if any(
            normalized_token in re.sub(r"[^a-z0-9]", "", table.lower())
            for table in table_names
        ):
            result.error(check_id, "FAIL_EPHEMERAL_DURABLE_TABLE", f"MEMORY_ONLY state machine has a durable table matching {token}", relative)
    if any(
        isinstance(message, dict)
        and "ephemeralchild" in re.sub(
            r"[^a-z0-9]", "", str(message.get("kind", "")).lower()
        )
        and message.get("delivery") != "MEMORY_ONLY"
        for message in registry.get("messages", [])
    ):
        result.error(
            check_id,
            "FAIL_EPHEMERAL_DURABLE_MESSAGE",
            "message registry may not publish ephemeral child state",
            relative,
        )

    storage_paths: list[str] = []
    storage_authority_writers: list[str] = []
    contracts_root = (result.design_root / "contracts").resolve()
    for index, artifact in enumerate(registry.get("storageArtifacts", [])):
        if not isinstance(artifact, dict) or not isinstance(artifact.get("path"), str):
            result.error(check_id, "FAIL_STORAGE_ARTIFACT", "storage artifact must have path", f"{relative}#storageArtifacts/{index}")
            continue
        candidate = (contracts_root / artifact["path"]).resolve(strict=False)
        if not is_within(candidate, contracts_root) or not candidate.is_file() or candidate.is_symlink():
            result.error(check_id, "FAIL_STORAGE_ARTIFACT", f"unsafe or missing storage path: {artifact['path']}", f"{relative}#storageArtifacts/{index}")
        writers = artifact.get("authorityWriters")
        if not isinstance(writers, list) or not writers:
            result.error(check_id, "FAIL_STORAGE_ARTIFACT", "storage artifact needs authorityWriters", f"{relative}#storageArtifacts/{index}")
        else:
            for writer in writers:
                require_reference(writer, owner_ids, f"#/storageArtifacts/{index}/authorityWriters", "owners")
                if isinstance(writer, str):
                    storage_authority_writers.append(writer)
        if not isinstance(artifact.get("physicalTransactionCoordinator"), str) or not artifact["physicalTransactionCoordinator"]:
            result.error(check_id, "FAIL_STORAGE_ARTIFACT", "storage artifact needs a physicalTransactionCoordinator", f"{relative}#storageArtifacts/{index}")
        storage_paths.append(candidate.relative_to(result.design_root).as_posix())
    if storage_paths != list(final_config["ddl_files"]):
        result.error(check_id, "FAIL_STORAGE_ARTIFACT_INVENTORY", "storageArtifacts must exactly name Bridge/Mobile v1 DDL", relative)

    expected_product_capabilities = [
        *[f"K-{index:03d}" for index in range(1, 27)],
        *[f"P-{index:03d}" for index in range(1, 27)],
    ]
    bindings = registry.get("productCapabilityBindings")
    binding_ids: list[str] = []
    binding_required_roles: dict[str, set[str]] = {}
    if not isinstance(bindings, list):
        result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_STRUCTURE", "productCapabilityBindings must be an array", relative)
        bindings = []
    raw_feature_contributions = registry.get("featureContributions")
    contribution_sequence = (
        raw_feature_contributions
        if isinstance(raw_feature_contributions, list)
        else []
    )
    contribution_ids = {
        item.get("contributionId")
        for item in contribution_sequence
        if isinstance(item, dict) and isinstance(item.get("contributionId"), str)
    }
    contributions_by_id = {
        item["contributionId"]: item
        for item in contribution_sequence
        if isinstance(item, dict) and isinstance(item.get("contributionId"), str)
    }
    if len(contribution_ids) != len(contribution_sequence):
        result.error(
            check_id,
            "FAIL_FEATURE_CONTRIBUTION_MODULE",
            "FeatureContribution contributionId values must be unique and nonblank",
            relative,
        )
    message_ids = id_sets.get("messages", set())
    operation_id_set = id_sets.get("operations", set())
    port_ids = id_sets.get("ports", set())
    capability_owner_evidence: dict[str, list[str]] = {
        identifier: [] for identifier in expected_product_capabilities
    }
    owner_sources = (
        ("drafts/K-CAPABILITY-COMPLETION.csv", "capability_id", ("unique_existing_root_owner",)),
        ("drafts/P2-CAPABILITY-P014-P026.csv", "capability_id", ("product_owner",)),
    )
    for source_path, id_column, owner_columns in owner_sources:
        try:
            with (result.design_root / source_path).open("r", encoding="utf-8-sig", newline="") as handle:
                for row in csv.DictReader(handle, strict=True):
                    identifier = row.get(id_column, "")
                    if identifier in capability_owner_evidence:
                        capability_owner_evidence[identifier].extend(row.get(column, "") for column in owner_columns)
        except (OSError, UnicodeError, csv.Error):
            pass
    def normalized_owner(value: str) -> str:
        return re.sub(r"[^a-z0-9]", "", value.lower())

    capability_role_coverage: dict[str, set[str]] = {
        identifier: set() for identifier in expected_product_capabilities
    }
    referenced_contribution_ids: set[str] = set()
    for index, binding in enumerate(bindings):
        artifact = f"{relative}#productCapabilityBindings/{index}"
        if not isinstance(binding, dict) or not isinstance(binding.get("id"), str):
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_STRUCTURE", "capability binding needs an id", artifact)
            continue
        binding_ids.append(binding["id"])
        binding_owners = binding.get("ownerRefs")
        if not isinstance(binding_owners, list) or not binding_owners:
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_OWNER",
                "capability binding ownerRefs must be a nonempty array",
                artifact,
            )
            binding_owners = []
        for owner in binding_owners:
            require_reference(owner, owner_ids, f"#/productCapabilityBindings/{index}/ownerRefs", "owners")
        evidence_text = normalized_owner(" ".join(capability_owner_evidence.get(binding["id"], [])))
        required_roles = binding.get(
            "requiredRoles", binding.get("requiredContributionRoles")
        )
        if (
            not isinstance(required_roles, list)
            or not required_roles
            or any(role not in FEATURE_CAPABILITY_ROLES for role in required_roles)
            or len(required_roles) != len(set(required_roles))
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_CAPABILITY_ROLE",
                "each capability binding needs unique required roles from the closed role set",
                artifact,
            )
            required_roles = []
        binding_required_roles[binding["id"]] = set(required_roles)
        instance_ids = binding.get("contributionInstanceIds")
        if (
            not isinstance(instance_ids, list)
            or not instance_ids
            or any(not isinstance(value, str) or not value for value in instance_ids)
            or len(instance_ids) != len(set(instance_ids))
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_INVENTORY",
                "each K/P binding needs unique nonblank contributionInstanceIds",
                artifact,
            )
            instance_ids = []
        authority_owners: list[str] = []
        for contribution_id in instance_ids:
            referenced_contribution_ids.add(contribution_id)
            contribution = contributions_by_id.get(contribution_id)
            if not isinstance(contribution, dict):
                result.error(
                    check_id,
                    "FAIL_FEATURE_CONTRIBUTION_MODULE",
                    f"unresolved contributionInstanceId: {contribution_id}",
                    artifact,
                )
                continue
            role_rows = [
                row for row in contribution.get("coveredCapabilityRoles", [])
                if isinstance(row, dict) and row.get("capabilityId") == binding["id"]
            ]
            if not role_rows:
                result.error(
                    check_id,
                    "FAIL_FEATURE_CONTRIBUTION_CAPABILITY",
                    f"{contribution_id} does not cover {binding['id']}",
                    artifact,
                )
            for role_row in role_rows:
                role = role_row.get("role")
                if role in FEATURE_CAPABILITY_ROLES:
                    capability_role_coverage.setdefault(binding["id"], set()).add(role)
                    if role == "AUTHORITY" and isinstance(contribution.get("executionOwnerRef"), str):
                        authority_owners.append(contribution["executionOwnerRef"])
            if contribution.get("executionOwnerRef") not in binding_owners:
                result.error(
                    check_id,
                    "FAIL_FEATURE_BINDING_OWNER_MISMATCH",
                    "contribution execution owner is absent from binding ownerRefs",
                    artifact,
                )
        if binding.get("coreBinding") not in {"BOUND", "NO_CORE_CHANGE"} or binding.get("supportEvidence") not in {"NOT_RUN", "UNKNOWN"}:
            result.error(
                check_id,
                "FAIL_FEATURE_SUPPORT_AVAILABILITY_EVIDENCE",
                "binding must be core-bound without a fabricated support result",
                artifact,
            )
        require_reference(
            binding.get("availabilityProvider"),
            owner_ids,
            f"#/productCapabilityBindings/{index}/availabilityProvider",
            "owners",
        )
        owners_to_match = authority_owners or [
            owner for owner in binding_owners if isinstance(owner, str)
        ]
        if (
            binding["id"] == "K-017"
            and set(authority_owners) != {"AutoApprovalPolicyStore"}
        ):
            result.error(
                check_id,
                "FAIL_AUTO_APPROVAL_POLICY_OWNER",
                "K-017 must have exactly one authority contribution owned by AutoApprovalPolicyStore; adapters may not become a second writer",
                artifact,
            )
        evidence_owners = {
            owner for owner in owner_ids
            if normalized_owner(owner) in evidence_text
        }
        if evidence_owners and not (set(owners_to_match) & evidence_owners):
            result.error(
                check_id,
                "FAIL_FEATURE_BINDING_OWNER_MISMATCH",
                "binding authority owner conflicts with a canonical K/P/AUTHORITY owner",
                artifact,
            )
        for key, targets in (("ports", port_ids), ("operationIds", operation_id_set), ("messageKinds", message_ids), ("protocolCapabilities", capability_ids)):
            values = binding.get(key)
            if not isinstance(values, list):
                result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_REFERENCE", f"{key} must be an array", artifact)
            else:
                for value in values:
                    require_reference(value, targets, f"#/productCapabilityBindings/{index}/{key}", key)
        if set(binding.get("operationIds", ())) & public_operation_ids and (
            "operation.submit" not in binding.get("messageKinds", ())
            or "core.operation.v1" not in binding.get("protocolCapabilities", ())
        ):
            result.error(
                check_id,
                "FAIL_PUBLIC_OPERATION_REUSE_BINDING",
                "a public OP/PX binding must reuse operation.submit and core.operation.v1",
                artifact,
            )
        independent_expected = expected_operations_by_capability.get(binding["id"])
        if independent_expected is not None:
            referenced_module_operations = {
                operation_id
                for contribution_id in instance_ids
                for operation_id in (
                    contributions_by_id.get(contribution_id, {}).get(
                        "operationIds", ()
                    )
                    if isinstance(
                        contributions_by_id.get(contribution_id, {}).get(
                            "operationIds", ()
                        ),
                        list,
                    )
                    else ()
                )
                if isinstance(operation_id, str)
            }
            if (
                binding.get("operationIds") != independent_expected["operationIds"]
                or not set(independent_expected["messageKinds"]).issubset(
                    set(binding.get("messageKinds", ()))
                )
                or not set(independent_expected["protocolCapabilities"]).issubset(
                    set(binding.get("protocolCapabilities", ()))
                )
                or not set(independent_expected["operationIds"]).issubset(
                    referenced_module_operations
                )
            ):
                result.error(
                    check_id,
                    "FAIL_EXPECTED_OPERATION_REFS",
                    f"{binding['id']} binding/descriptors do not preserve the independent public operation reuse inventory",
                    artifact,
                )
    if binding_ids != expected_product_capabilities or len(bindings) != int(final_config["feature_contribution_count"]):
        result.error(
            check_id,
            "FAIL_FEATURE_CONTRIBUTION_INVENTORY",
            "productCapabilityBindings must cover K-001..K-026 plus P-001..P-026 exactly once",
            relative,
        )

    contribution_contract = registry.get("featureContributionContract")
    if not isinstance(contribution_contract, dict) or contribution_contract.get("schemaRef") != "schema/domain.schema.json#/$defs/FeatureContributionDescriptorV1":
        result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_DESCRIPTOR", "featureContributionContract must bind FeatureContributionDescriptorV1", relative)

    contributions = raw_feature_contributions
    all_sole_writers: list[str] = []
    sole_writer_hosts: dict[str, str] = {}
    if not isinstance(contributions, list):
        result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_STRUCTURE", "featureContributions runtime modules must be an array", relative)
        contributions = []
    for index, contribution in enumerate(contributions):
        artifact = f"{relative}#featureContributions/{index}"
        if not isinstance(contribution, dict):
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_STRUCTURE", "FeatureContribution must be an object", artifact)
            continue
        if set(contribution) != FEATURE_DESCRIPTOR_FIELDS:
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_STRUCTURE",
                "FeatureContribution instance must have the exact descriptor fields",
                artifact,
            )
        if (
            not isinstance(contribution.get("featureId"), str)
            or not contribution["featureId"]
            or isinstance(contribution.get("version"), bool)
            or not isinstance(contribution.get("version"), int)
            or contribution["version"] < 1
        ):
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_STRUCTURE", "featureId/version is invalid", artifact)
        if contribution.get("hostKind") not in FEATURE_HOST_KINDS:
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_LOCATION",
                "hostKind must be BRIDGE, MOBILE, NATIVE_IOS, or NATIVE_ANDROID",
                artifact,
            )
        execution_owner = contribution.get("executionOwnerRef")
        require_reference(
            execution_owner,
            owner_ids,
            f"#/featureContributions/{index}/executionOwnerRef",
            "owners",
        )
        if (
            isinstance(execution_owner, str)
            and contribution.get("hostKind") in FEATURE_HOST_KINDS
            and contribution["hostKind"] not in host_kinds_by_owner.get(execution_owner, set())
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_HOST_OWNER_BINDING",
                "descriptor hostKind is not registered for its execution owner",
                artifact,
            )
        contributed_ports = contribution.get("ports")
        if not isinstance(contributed_ports, list) or not contributed_ports:
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_PORT", "FeatureContribution needs at least one typed port", artifact)
        else:
            for port in contributed_ports:
                require_reference(port, port_ids, f"#/featureContributions/{index}/ports", "ports")
        for key, targets in (("operationIds", operation_id_set), ("messageKinds", message_ids)):
            values = contribution.get(key)
            if not isinstance(values, list) or len(values) != len({stable_json(value) for value in values}):
                result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_REFERENCE", f"{key} must be a unique array", artifact)
            else:
                for value in values:
                    require_reference(value, targets, f"#/featureContributions/{index}/{key}", key)
        if set(contribution.get("operationIds", ())) & public_operation_ids and "operation.submit" not in contribution.get("messageKinds", ()):
            result.error(
                check_id,
                "FAIL_PUBLIC_OPERATION_REUSE_BINDING",
                "a contribution handling public OP/PX slots must reuse operation.submit",
                artifact,
            )
        for key in ("targetKinds", "limits", "diagnostics", "uiSlots"):
            values = contribution.get(key)
            if (
                not isinstance(values, list)
                or any(not isinstance(value, str) or not value for value in values)
                or len(values) != len({stable_json(value) for value in values})
            ):
                result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_STRUCTURE", f"{key} must be a unique nonblank string array", artifact)
        namespaces = contribution.get("storageNamespaceRefs")
        if not isinstance(namespaces, list):
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_REFERENCE", "storageNamespaceRefs must be an array", artifact)
        else:
            namespace_ids: list[str] = []
            required_namespace_fields = {"namespaceId", "ownerRef", "classification", "clearPolicy"}
            optional_namespace_fields = {"retentionPolicyRef", "backupProtectionPolicyRef"}
            for namespace in namespaces:
                if (
                    not isinstance(namespace, dict)
                    or not required_namespace_fields.issubset(namespace)
                    or not set(namespace).issubset(required_namespace_fields | optional_namespace_fields)
                ):
                    result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_REFERENCE", "storage namespace descriptor is not closed", artifact)
                    continue
                namespace_ids.append(str(namespace.get("namespaceId", "")))
                require_reference(namespace.get("ownerRef"), owner_ids, f"#/featureContributions/{index}/storageNamespaceRefs/ownerRef", "owners")
                registered_namespace = storage_namespace_registry.get(
                    str(namespace.get("namespaceId", ""))
                )
                if registered_namespace != namespace:
                    result.error(
                        check_id,
                        "FAIL_FEATURE_STORAGE_NAMESPACE",
                        "descriptor namespace must exactly resolve in storageNamespaces",
                        artifact,
                    )
            if len(namespace_ids) != len(set(namespace_ids)) or any(not value for value in namespace_ids):
                result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_REFERENCE", "storage namespace IDs must be unique and nonblank", artifact)
        for key, required_keys in (
            ("activationKey", {"cutoverKeyKind", "featureKey", "initialState"}),
            ("rollbackBoundary", {"boundaryKind", "policy"}),
        ):
            value = contribution.get(key)
            if (
                not isinstance(value, dict)
                or set(value) != required_keys
                or any(not isinstance(item, str) or not item for item in value.values())
            ):
                result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_STRUCTURE", f"{key} is incomplete", artifact)
        covered = contribution.get("coveredCapabilityRoles")
        if not isinstance(covered, list) or not covered:
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_CAPABILITY", "contribution needs coveredCapabilityRoles", artifact)
            covered = []
        seen_role_pairs: set[tuple[str, str]] = set()
        for role_binding in covered:
            if not isinstance(role_binding, dict):
                result.error(check_id, "FAIL_FEATURE_CAPABILITY_ROLE", "coveredCapabilityRoles entries must be objects", artifact)
                continue
            capability_id = role_binding.get("capabilityId")
            role = role_binding.get("role")
            pair = (str(capability_id), str(role))
            if capability_id not in capability_role_coverage or role not in FEATURE_CAPABILITY_ROLES:
                result.error(check_id, "FAIL_FEATURE_CAPABILITY_ROLE", f"unknown capability/role pair: {capability_id!r}/{role!r}", artifact)
            elif pair in seen_role_pairs:
                result.error(check_id, "FAIL_FEATURE_CAPABILITY_ROLE", f"duplicate capability/role pair: {capability_id}/{role}", artifact)
            else:
                capability_role_coverage[capability_id].add(role)
                seen_role_pairs.add(pair)
        for key in ("ownerRefs", "soleWriterRefs"):
            values = contribution.get(key)
            if not isinstance(values, list) or (key == "ownerRefs" and not values):
                result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_OWNER", f"{key} must be an array; ownerRefs cannot be empty", artifact)
            else:
                for owner in values:
                    require_reference(owner, owner_ids, f"#/featureContributions/{index}/{key}", "owners")
                if key == "soleWriterRefs":
                    for writer in values:
                        if isinstance(writer, str):
                            all_sole_writers.append(writer)
                            sole_writer_hosts[writer] = str(contribution.get("hostKind", ""))
        owner_refs = contribution.get("ownerRefs")
        if (
            isinstance(execution_owner, str)
            and isinstance(owner_refs, list)
            and execution_owner not in owner_refs
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_OWNER",
                "executionOwnerRef must be one of ownerRefs",
                artifact,
            )
        state_policy = contribution.get("capabilityStatePolicy")
        if (
            not isinstance(state_policy, dict)
            or any(
                not isinstance(state_policy.get(key), str) or not state_policy[key]
                for key in (
                    "supportResolverRef",
                    "availabilityResolverRef",
                    "snapshotPublisherPortRef",
                )
            )
            or not isinstance(state_policy.get("evidenceKinds"), list)
            or not state_policy.get("evidenceKinds")
            or state_policy.get("fallbackSupport") != "UNKNOWN"
            or state_policy.get("fallbackAvailability") not in {"UNKNOWN", "UNAVAILABLE"}
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_SUPPORT_AVAILABILITY_EVIDENCE",
                "capabilityStatePolicy must keep support/availability independent and bind resolver, evidence, UNKNOWN/UNAVAILABLE fallback, and snapshot publisher",
                artifact,
            )
        elif state_policy["snapshotPublisherPortRef"] not in port_ids:
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_REFERENCE",
                "capabilityStatePolicy.snapshotPublisherPortRef must resolve in ports",
                artifact,
            )
        lifecycle = contribution.get("lifecycle")
        if not isinstance(lifecycle, dict) or set(lifecycle) != FEATURE_LIFECYCLE_KEYS or any(
            not isinstance(value, str) or not value for value in lifecycle.values()
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_LIFECYCLE",
                "lifecycle must define the exact seven nonblank policies",
                artifact,
            )

        def scan_static_axes(value: Any) -> bool:
            if isinstance(value, dict):
                for key, nested in value.items():
                    if (
                        key in {"support", "availability"}
                        and isinstance(nested, str)
                        and nested in {"SUPPORTED", "AVAILABLE"}
                    ):
                        return True
                    if scan_static_axes(nested):
                        return True
            elif isinstance(value, list):
                return any(scan_static_axes(nested) for nested in value)
            return False

        if scan_static_axes(contribution):
            result.error(
                check_id,
                "FAIL_FEATURE_STATIC_CAPABILITY_STATE",
                "descriptor may not hard-code actual SUPPORTED/AVAILABLE; only an evidence-bound snapshot may publish those axes",
                artifact,
            )
    if referenced_contribution_ids != contribution_ids:
        result.error(
            check_id,
            "FAIL_FEATURE_CONTRIBUTION_MODULE",
            "binding and descriptor contribution IDs differ; unresolved="
            f"{sorted(referenced_contribution_ids - contribution_ids)}, "
            f"orphan={sorted(contribution_ids - referenced_contribution_ids)}",
            relative,
        )
    if any(not roles for roles in capability_role_coverage.values()):
        result.error(
            check_id,
            "FAIL_FEATURE_CONTRIBUTION_INVENTORY",
            "runtime FeatureContribution modules must cover every K/P capability with at least one role",
            relative,
        )
    missing_roles = {
        identifier: sorted(required - capability_role_coverage.get(identifier, set()))
        for identifier, required in binding_required_roles.items()
        if required - capability_role_coverage.get(identifier, set())
    }
    if missing_roles:
        result.error(
            check_id,
            "FAIL_FEATURE_CAPABILITY_ROLE_COVERAGE",
            "required contribution roles are missing: " + stable_json(missing_roles),
            relative,
        )
    authority_path = result.design_root / "matrices/AUTHORITY-OWNERSHIP.csv"
    expected_writer_inventory = registry.get("expectedSoleWriterInventory")
    expected_writer_hosts: dict[str, str] = {}
    authority_writer_text = ""
    try:
        with authority_path.open("r", encoding="utf-8-sig", newline="") as handle:
            authority_writer_text = " ".join(
                f"{row.get('domain_owner', '')} {row.get('sole_writer', '')}"
                for row in csv.DictReader(handle, strict=True)
            )
    except (OSError, UnicodeError, csv.Error):
        pass
    if (
        not isinstance(expected_writer_inventory, list)
        or not expected_writer_inventory
        or any(
            not isinstance(entry, dict)
            or set(entry) != {"writerRef", "hostKind"}
            or entry.get("writerRef") not in owner_ids
            or entry.get("hostKind") not in FEATURE_HOST_KINDS
            for entry in expected_writer_inventory
        )
    ):
        result.error(
            check_id,
            "FAIL_FEATURE_SOLE_WRITER_MISSING",
            "expectedSoleWriterInventory must be a nonempty unique closed owner inventory",
            relative,
        )
        expected_writer_inventory = []
    else:
        expected_writer_hosts = {
            entry["writerRef"]: entry["hostKind"]
            for entry in expected_writer_inventory
        }
        if len(expected_writer_hosts) != len(expected_writer_inventory):
            result.error(
                check_id,
                "FAIL_FEATURE_SOLE_WRITER_MISSING",
                "expectedSoleWriterInventory contains duplicate writerRef values",
                relative,
            )
    if (
        expected_writer_hosts != FIXED_EXPECTED_SOLE_WRITERS
        or set(expected_writer_hosts) != set(storage_authority_writers)
        or set(expected_writer_hosts) != set(all_sole_writers)
        or sole_writer_hosts != expected_writer_hosts
        or len(all_sole_writers) != len(expected_writer_hosts)
    ):
        result.error(
            check_id,
            "FAIL_FEATURE_SOLE_WRITER_COVERAGE",
            "expected, storage, and descriptor sole-writer inventories must be exact one-to-one sets",
            relative,
        )
    missing_authority_writers = [
        writer for writer in FIXED_EXPECTED_SOLE_WRITERS
        if normalized_owner(writer) not in normalized_owner(authority_writer_text)
    ]
    if missing_authority_writers:
        result.error(
            check_id,
            "FAIL_FEATURE_SOLE_WRITER_COVERAGE",
            "expected writers are absent from independent AUTHORITY-OWNERSHIP evidence: "
            + ", ".join(missing_authority_writers),
            "matrices/AUTHORITY-OWNERSHIP.csv",
        )
    if len(all_sole_writers) != len(set(all_sole_writers)):
        result.error(
            check_id,
            "FAIL_FEATURE_SOLE_WRITER_DUPLICATE",
            "soleWriterRefs must be globally unique across FeatureContribution modules",
            relative,
        )
    dependency_graph: dict[str, list[str]] = {}
    for contribution in contributions:
        if not isinstance(contribution, dict) or not isinstance(contribution.get("contributionId"), str):
            continue
        dependencies = contribution.get("dependencies")
        if not isinstance(dependencies, list) or any(value not in contribution_ids for value in dependencies):
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_DEPENDENCY", f"unresolved dependencies for {contribution['contributionId']}", relative)
            dependencies = []
        dependency_graph[contribution["contributionId"]] = dependencies
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit_module(module_id: str) -> bool:
        if module_id in visiting:
            return False
        if module_id in visited:
            return True
        visiting.add(module_id)
        if any(not visit_module(dependency) for dependency in dependency_graph.get(module_id, [])):
            return False
        visiting.remove(module_id)
        visited.add(module_id)
        return True

    if any(not visit_module(module_id) for module_id in sorted(dependency_graph)):
        result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_DEPENDENCY", "FeatureContribution dependency graph contains a cycle", relative)

    schema_root = (result.design_root / "contracts/schema").resolve()
    schema_documents: dict[Path, Any] = {}
    for schema_path in schema_root.glob("*.schema.json"):
        try:
            schema_documents[schema_path.resolve()] = parse_json_file(schema_path)
        except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError):
            pass
    observed_rule_ids: set[str] = set()
    rule_schema_locations: dict[str, set[str]] = {}
    invalid_semantic_extensions: list[str] = []
    allowed_schema_extensions = {
        "x-ruleIds", "x-utf8MaxBytes", "x-serializedUtf8MaxBytes",
        "x-maxDepth",
    }

    def collect_semantic_extensions(node: Any, location: str) -> None:
        if isinstance(node, dict):
            for key in node:
                if key.startswith("x-") and key not in allowed_schema_extensions:
                    invalid_semantic_extensions.append(f"{location}/{key}")
            if "x-ruleIds" in node:
                rule_ids = node["x-ruleIds"]
                if (
                    not isinstance(rule_ids, list)
                    or not rule_ids
                    or any(
                        not isinstance(rule_id, str) or not rule_id
                        for rule_id in rule_ids
                    )
                    or len(rule_ids) != len(set(rule_ids))
                ):
                    invalid_semantic_extensions.append(f"{location}/x-ruleIds")
                else:
                    for rule_id in rule_ids:
                        observed_rule_ids.add(rule_id)
                        rule_schema_locations.setdefault(rule_id, set()).add(location)
            for key, value in node.items():
                collect_semantic_extensions(value, f"{location}/{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                collect_semantic_extensions(value, f"{location}/{index}")

    for schema_path, schema_document in schema_documents.items():
        collect_semantic_extensions(schema_document, schema_path.name)
    if invalid_semantic_extensions:
        result.error(
            check_id,
            "FAIL_UNKNOWN_CROSS_FIELD_ANNOTATION",
            "prose x-crossField and unknown semantic x-* annotations are forbidden; "
            f"invalid={invalid_semantic_extensions[:8]}",
            "contracts/schema",
        )
    rule_inventory = registry.get("executableRuleInventory")
    supported_rule_handlers = {
        rule_id: handler
        for rule_id, handler, _schema_refs, _vector_ids
        in FIXED_EXECUTABLE_RULES
    }
    inventory_rule_ids: list[str] = []
    if not isinstance(rule_inventory, list) or not rule_inventory:
        result.error(
            check_id,
            "FAIL_EXECUTABLE_RULE_INVENTORY",
            "executableRuleInventory must be a nonempty array",
            relative,
        )
        rule_inventory = []
    for index, rule in enumerate(rule_inventory):
        artifact = f"{relative}#executableRuleInventory/{index}"
        if (
            not isinstance(rule, dict)
            or set(rule) != {"ruleId", "schemaRefs", "handler", "vectorIds"}
            or not isinstance(rule.get("ruleId"), str)
            or not rule["ruleId"]
            or not isinstance(rule.get("handler"), str)
            or not rule["handler"]
            or not isinstance(rule.get("schemaRefs"), list)
            or not rule["schemaRefs"]
            or any(
                not isinstance(value, str) or not value
                for value in rule["schemaRefs"]
            )
            or not isinstance(rule.get("vectorIds"), list)
            or len(rule["vectorIds"]) < 2
            or any(
                not isinstance(value, str) or not value
                for value in rule["vectorIds"]
            )
        ):
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_INVENTORY",
                "rule inventory entry must close ruleId/schemaRefs/handler/two-or-more vectorIds",
                artifact,
            )
            continue
        inventory_rule_ids.append(rule["ruleId"])
        expected_locations = {
            "schema/" + location.replace("/", "#/", 1)
            for location in rule_schema_locations.get(rule["ruleId"], set())
        }
        if set(rule["schemaRefs"]) != expected_locations:
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_INVENTORY",
                f"{rule['ruleId']} schemaRefs differ from actual x-ruleIds locations",
                artifact,
            )
        if supported_rule_handlers.get(rule["ruleId"]) != rule["handler"]:
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_INVENTORY",
                f"{rule['ruleId']} has no exact stdlib handler dispatch",
                artifact,
            )
    if (
        len(inventory_rule_ids) != len(set(inventory_rule_ids))
        or set(inventory_rule_ids) != observed_rule_ids
    ):
        result.error(
            check_id,
            "FAIL_EXECUTABLE_RULE_INVENTORY",
            "schema x-ruleIds and executableRuleInventory must have exact set equality",
            relative,
        )
    descriptor_definitions = [
        document.get("$defs", {}).get("FeatureContributionDescriptorV1")
        for document in schema_documents.values()
        if isinstance(document, dict) and isinstance(document.get("$defs"), dict)
        and "FeatureContributionDescriptorV1" in document["$defs"]
    ]
    if len(descriptor_definitions) != 1 or not isinstance(descriptor_definitions[0], dict):
        result.error(
            check_id,
            "FAIL_FEATURE_CONTRIBUTION_DESCRIPTOR",
            "schemas must define exactly one FeatureContributionDescriptorV1 contract",
            "contracts/schema",
        )
    else:
        descriptor = descriptor_definitions[0]
        required_descriptor_fields = FEATURE_DESCRIPTOR_FIELDS
        if (
            descriptor.get("additionalProperties") is not False
            or set(descriptor.get("required", ())) != required_descriptor_fields
            or set(descriptor.get("properties", ())) != required_descriptor_fields
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_CONTRIBUTION_DESCRIPTOR",
                "FeatureContributionDescriptorV1 must be the closed host-scoped R30 contract",
                "contracts/schema",
            )
        properties = descriptor.get("properties", {})
        host_schema = properties.get("hostKind", {}) if isinstance(properties, dict) else {}
        role_items = (
            properties.get("coveredCapabilityRoles", {}).get("items", {})
            if isinstance(properties, dict)
            and isinstance(properties.get("coveredCapabilityRoles"), dict)
            else {}
        )
        role_schema = (
            role_items.get("properties", {}).get("role", {})
            if isinstance(role_items, dict)
            and isinstance(role_items.get("properties"), dict)
            else {}
        )
        lifecycle_schema = properties.get("lifecycle", {}) if isinstance(properties, dict) else {}
        policy_schema = properties.get("capabilityStatePolicy", {}) if isinstance(properties, dict) else {}
        if set(host_schema.get("enum", ())) != FEATURE_HOST_KINDS:
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_DESCRIPTOR", "hostKind enum is not the exact four-host set", "contracts/schema")
        if set(role_schema.get("enum", ())) != FEATURE_CAPABILITY_ROLES:
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_DESCRIPTOR", "coveredCapabilityRoles.role enum is incomplete", "contracts/schema")
        if (
            not isinstance(lifecycle_schema, dict)
            or set(lifecycle_schema.get("required", ())) != FEATURE_LIFECYCLE_KEYS
            or set(lifecycle_schema.get("properties", ())) != FEATURE_LIFECYCLE_KEYS
        ):
            result.error(check_id, "FAIL_FEATURE_CONTRIBUTION_DESCRIPTOR", "lifecycle schema must close the exact seven policies", "contracts/schema")
        policy_fields = {
            "supportResolverRef",
            "availabilityResolverRef",
            "evidenceKinds",
            "fallbackSupport",
            "fallbackAvailability",
            "snapshotPublisherPortRef",
        }
        policy_properties = policy_schema.get("properties", {}) if isinstance(policy_schema, dict) else {}
        support_fallback = policy_properties.get("fallbackSupport", {}) if isinstance(policy_properties, dict) else {}
        availability_fallback = policy_properties.get("fallbackAvailability", {}) if isinstance(policy_properties, dict) else {}
        support_values = {
            value for value in support_fallback.get("enum", ())
            if isinstance(value, str)
        } if isinstance(support_fallback.get("enum", ()), list) else set()
        availability_values = {
            value for value in availability_fallback.get("enum", ())
            if isinstance(value, str)
        } if isinstance(availability_fallback.get("enum", ()), list) else set()
        if isinstance(support_fallback.get("const"), str):
            support_values.add(support_fallback["const"])
        if isinstance(availability_fallback.get("const"), str):
            availability_values.add(availability_fallback["const"])
        if (
            not isinstance(policy_schema, dict)
            or policy_schema.get("additionalProperties") is not False
            or set(policy_schema.get("required", ())) != policy_fields
            or set(policy_schema.get("properties", ())) != policy_fields
            or support_values != {"UNKNOWN"}
            or "UNKNOWN" not in availability_values
            or not availability_values.issubset({"UNKNOWN", "UNAVAILABLE"})
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_SUPPORT_AVAILABILITY_EVIDENCE",
                "capabilityStatePolicy schema must close independent resolvers, evidence, fail-closed fallbacks, and snapshot publisher",
                "contracts/schema",
            )

    all_definitions = {
        name: definition
        for document in schema_documents.values()
        if isinstance(document, dict) and isinstance(document.get("$defs"), dict)
        for name, definition in document["$defs"].items()
        if isinstance(definition, dict)
    }

    open_object_locations: list[str] = []

    def walk_closed_schema_objects(
        node: Any, location: str, definition_name: str | None = None
    ) -> None:
        if isinstance(node, dict):
            is_object_schema = (
                node.get("type") == "object"
                or "properties" in node
                or "patternProperties" in node
                or "required" in node
            )
            if is_object_schema and node.get("additionalProperties") is not False:
                extension_map = (
                    definition_name == "ExtensionsV1"
                    and isinstance(node.get("additionalProperties"), dict)
                    and isinstance(node.get("maxProperties"), int)
                    and node["maxProperties"] >= 0
                )
                if not extension_map:
                    open_object_locations.append(location)
            for key, value in node.items():
                child_definition = (
                    key if location.endswith("/$defs") else definition_name
                )
                walk_closed_schema_objects(
                    value, f"{location}/{key}", child_definition
                )
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk_closed_schema_objects(
                    value, f"{location}/{index}", definition_name
                )

    for schema_path, schema_document in schema_documents.items():
        walk_closed_schema_objects(schema_document, schema_path.name)
    if open_object_locations:
        result.error(
            check_id,
            "FAIL_SCHEMA_OPEN_OBJECT",
            "reachable object schemas must explicitly close additionalProperties; "
            "only a bounded ExtensionsV1 value map is exempt: "
            + ", ".join(open_object_locations[:12]),
            "contracts/schema",
        )

    numeric_domains = {
        "HeadVersion0": 0,
        "CheckpointSequence0": 0,
        "Ordinal0": 0,
        "BaseSequence0": 0,
        "BoundEpoch1": 1,
        "AggregateRevision1": 1,
        "ObjectGeneration1": 1,
        "StreamSequence1": 1,
    }
    bad_numeric_domains = [
        name
        for name, minimum in numeric_domains.items()
        if not isinstance(all_definitions.get(name), dict)
        or all_definitions[name].get("type") != "integer"
        or all_definitions[name].get("minimum") != minimum
        or all_definitions[name].get("maximum") != 9007199254740991
    ]
    numeric_field_mismatches: list[str] = []

    registry_numeric_inventory = registry.get("numericTypeInventory")
    normalized_numeric_inventory = {
        domain: tuple(fields)
        for domain, fields in registry_numeric_inventory.items()
        if isinstance(domain, str)
        and isinstance(fields, list)
        and all(isinstance(field, str) for field in fields)
    } if isinstance(registry_numeric_inventory, dict) else {}
    if normalized_numeric_inventory != FIXED_NUMERIC_TYPE_INVENTORY:
        numeric_field_mismatches.append(
            "registry numericTypeInventory differs from the independent R47 inventory"
        )

    numeric_field_domains = {
        field: domain
        for domain, fields in FIXED_NUMERIC_TYPE_INVENTORY.items()
        for field in fields
    }
    numeric_domain_names = set(FIXED_NUMERIC_TYPE_INVENTORY)

    def walk_numeric_properties(node: Any, location: str) -> None:
        if isinstance(node, dict):
            properties = node.get("properties")
            if isinstance(properties, dict):
                for field, schema in properties.items():
                    expected = numeric_field_domains.get(field)
                    reference = schema.get("$ref") if isinstance(schema, dict) else None
                    referenced_domain = (
                        reference.rsplit("/", 1)[-1]
                        if isinstance(reference, str)
                        else None
                    )
                    if expected is not None:
                        if referenced_domain != expected:
                            numeric_field_mismatches.append(f"{location}/{field}->{reference!r}, expected {expected}")
                    elif referenced_domain in numeric_domain_names:
                        numeric_field_mismatches.append(
                            f"{location}/{field}->{reference!r}, field absent from independent R47 inventory"
                        )
            for key, value in node.items():
                walk_numeric_properties(value, f"{location}/{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk_numeric_properties(value, f"{location}/{index}")

    for schema_path, schema_document in schema_documents.items():
        walk_numeric_properties(schema_document, schema_path.name)
    if bad_numeric_domains or numeric_field_mismatches:
        result.error(
            check_id,
            "FAIL_NUMERIC_DOMAIN_MAPPING",
            "R47 numeric domains or field mappings differ: "
            f"domains={bad_numeric_domains}, fields={numeric_field_mismatches[:12]}",
            "contracts/schema",
        )

    def local_definition(schema: Any) -> Mapping[str, Any]:
        if not isinstance(schema, dict):
            return {}
        reference = schema.get("$ref")
        if isinstance(reference, str) and "/$defs/" in reference:
            return all_definitions.get(reference.rsplit("/", 1)[-1], {})
        return schema

    error_registry = registry.get("errorRegistry")
    error_entries = (
        error_registry.get("problems", [])
        if isinstance(error_registry, dict)
        else []
    )
    error_sequence = [
        (
            entry["code"], entry["errorClass"], entry["retryDirective"],
            entry["detailSchemaRef"],
        )
        for entry in error_entries
        if isinstance(entry, dict)
        and set(entry)
        == {"code", "errorClass", "retryDirective", "detailSchemaRef"}
        and all(
            isinstance(entry.get(key), str)
            for key in (
                "code", "errorClass", "retryDirective", "detailSchemaRef"
            )
        )
    ] if isinstance(error_entries, list) else []
    error_mapping = {
        entry["code"]: (
            entry["errorClass"], entry["retryDirective"],
            entry["detailSchemaRef"],
        )
        for entry in error_entries
        if isinstance(entry, dict)
        and set(entry)
        == {"code", "errorClass", "retryDirective", "detailSchemaRef"}
        and all(
            isinstance(entry.get(key), str)
            for key in (
                "code", "errorClass", "retryDirective", "detailSchemaRef"
            )
        )
    } if isinstance(error_entries, list) else {}
    problem_v1 = all_definitions.get("ProblemV1")

    def detail_schema_is_closed_bounded(schema: Any) -> bool:
        visited: set[str] = set()

        def visit(node: Any) -> bool:
            if not isinstance(node, dict):
                return True
            reference = node.get("$ref")
            if isinstance(reference, str) and "/$defs/" in reference:
                name = reference.rsplit("/", 1)[-1]
                if name in visited:
                    return True
                visited.add(name)
                return visit(all_definitions.get(name))
            node_type = node.get("type")
            if node_type == "object" and node.get("additionalProperties") is not False:
                return False
            if node_type == "string" and not (
                isinstance(node.get("maxLength"), int)
                or (
                    isinstance(node.get("pattern"), str)
                    and re.search(r"\{[0-9]+(?:,[0-9]+)?\}", node["pattern"])
                )
            ):
                return False
            if node_type == "array" and not isinstance(node.get("maxItems"), int):
                return False
            properties = node.get("properties")
            if isinstance(properties, dict):
                forbidden = {
                    key for key in properties
                    if re.search(
                        r"(?i)(?:raw|exception|stack|sql|filesystempath|providerpayload|credential|token)",
                        key,
                    )
                }
                if forbidden:
                    return False
            return all(
                visit(value)
                for value in node.values()
                if isinstance(value, (dict, list))
                for value in (value if isinstance(value, list) else [value])
            )

        return visit(schema)

    problem_branches = (
        problem_v1.get("oneOf", ())
        if isinstance(problem_v1, dict)
        else ()
    )
    resolved_problem_branches = [
        local_definition(branch) for branch in problem_branches
    ] if isinstance(problem_branches, list) else []
    first_problem_properties = (
        resolved_problem_branches[0].get("properties", {})
        if resolved_problem_branches
        and isinstance(resolved_problem_branches[0], dict)
        else {}
    )
    problem_subject = local_definition(first_problem_properties.get("subject"))
    subject_branches = (
        problem_subject.get("oneOf", ())
        if isinstance(problem_subject, dict)
        else ()
    )
    subject_kinds: set[Any] = set()
    if isinstance(subject_branches, list):
        for branch_ref in subject_branches:
            branch = local_definition(branch_ref)
            properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
            subject_kinds.add(
                local_definition(properties.get("kind", {})).get("const")
            )
    observed_problem_mapping: dict[str, tuple[str, str, str]] = {}
    observed_problem_sequence: list[tuple[str, str, str, str]] = []
    shared_problem_fields = (
        "safeTitle", "subject", "correlationId"
    )
    canonical_shared_problem_schemas = {
        field: stable_json(first_problem_properties.get(field))
        for field in shared_problem_fields
    }
    problem_branch_invalid = False
    for branch in resolved_problem_branches:
        properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
        error_class = local_definition(properties.get("errorClass", {})).get("const")
        problem_code = local_definition(properties.get("problemCode", {})).get("const")
        retry_directive = local_definition(properties.get("retryDirective", {})).get("const")
        branch_detail = properties.get("safeDetail", {}) if isinstance(properties, dict) else {}
        branch_detail_ref = (
            branch_detail.get("$ref")
            if isinstance(branch_detail, dict)
            else None
        )
        normalized_branch_detail_ref = (
            "schema/domain.schema.json" + branch_detail_ref
            if isinstance(branch_detail_ref, str)
            and branch_detail_ref.startswith("#")
            else branch_detail_ref
        )
        if (
            not isinstance(branch, dict)
            or branch.get("additionalProperties") is not False
            or set(properties) != FIXED_PROBLEM_FIELDS
            or set(branch.get("required", ()))
            != FIXED_PROBLEM_REQUIRED_FIELDS
            or not isinstance(error_class, str)
            or not isinstance(problem_code, str)
            or not isinstance(retry_directive, str)
            or not isinstance(normalized_branch_detail_ref, str)
            or problem_code in observed_problem_mapping
            or any(
                stable_json(properties.get(field))
                != canonical_shared_problem_schemas[field]
                for field in shared_problem_fields
            )
        ):
            problem_branch_invalid = True
            continue
        observed_problem_mapping[problem_code] = (
            error_class, retry_directive, normalized_branch_detail_ref,
        )
        observed_problem_sequence.append((
            problem_code, error_class, retry_directive,
            normalized_branch_detail_ref,
        ))
    if (
        not isinstance(problem_v1, dict)
        or "x-ruleIds" in problem_v1
        or not isinstance(problem_branches, list)
        or len(problem_branches) != len(error_mapping)
        or problem_branch_invalid
        or observed_problem_mapping != error_mapping
        or observed_problem_sequence != error_sequence
        or any(
            not detail_schema_is_closed_bounded(
                all_definitions.get(mapping[2].rsplit("/", 1)[-1])
            )
            for mapping in error_mapping.values()
        )
        or not isinstance(subject_branches, list)
        or len(subject_branches) != len(subject_kinds)
        or None in subject_kinds
        or any(
            local_definition(branch).get("additionalProperties") is not False
            for branch in subject_branches
        )
    ):
        result.error(
            check_id,
            "FAIL_PROBLEM_V1_REGISTRY_BINDING",
            "ProblemV1 must close canonical fields/classes/directives, a sealed subject union, and the registry-bound bounded redacted safe-detail schema",
            "contracts/schema/domain.schema.json",
        )

    def local_schema_closure(schema: Any) -> str:
        values: list[Any] = []
        visited: set[str] = set()

        def visit(value: Any) -> None:
            values.append(value)
            if isinstance(value, dict):
                reference = value.get("$ref")
                if isinstance(reference, str) and "/$defs/" in reference:
                    name = reference.rsplit("/", 1)[-1]
                    if name not in visited and name in all_definitions:
                        visited.add(name)
                        visit(all_definitions[name])
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)

        visit(schema)
        return "\n".join(stable_json(value) for value in values)

    required_settings_fields = {
        "model", "approvalPolicy", "approvalsReviewer", "sandboxPolicy",
        "collaborationMode",
    }
    nullable_settings_fields = {
        "modelReasoningEffort", "serviceTier", "activePermissionProfile",
    }
    thread_state_fields = required_settings_fields | nullable_settings_fields
    settings_snapshot = all_definitions.get("SettingsSnapshotValue")
    settings_properties = (
        settings_snapshot.get("properties", {})
        if isinstance(settings_snapshot, dict)
        else {}
    )
    settings_text = stable_json(settings_snapshot or {})

    def observation_variants(schema: Any) -> dict[str, Mapping[str, Any]]:
        definition = local_definition(schema)
        branches = definition.get("oneOf") if isinstance(definition, dict) else None
        if not isinstance(branches, list):
            return {}
        variants: dict[str, Mapping[str, Any]] = {}
        for raw_branch in branches:
            branch = local_definition(raw_branch)
            properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
            state_schema = local_definition(properties.get("state")) if isinstance(properties, dict) else {}
            state = state_schema.get("const") if isinstance(state_schema, dict) else None
            expected_properties = {"state", "value"} if state == "VALUE" else {"state"}
            if (
                not isinstance(state, str)
                or state in variants
                or branch.get("additionalProperties") is not False
                or set(properties) != expected_properties
                or set(branch.get("required", ())) != expected_properties
            ):
                return {}
            variants[state] = branch
        return variants

    observed_variants = {
        field: observation_variants(schema)
        for field, schema in settings_properties.items()
        if field in thread_state_fields
    } if isinstance(settings_properties, dict) else {}

    active_profile_value: Mapping[str, Any] = {}
    active_profile_variant = observed_variants.get(
        "activePermissionProfile", {}
    ).get("VALUE")
    if isinstance(active_profile_variant, dict):
        active_profile_value = local_definition(
            active_profile_variant.get("properties", {}).get("value")
        )
    active_profile_properties = (
        active_profile_value.get("properties", {})
        if isinstance(active_profile_value, dict)
        else {}
    )
    active_profile_required = set(
        active_profile_value.get("required", ())
    ) if isinstance(active_profile_value, dict) else set()
    extends_schema = local_definition(
        active_profile_properties.get("extendsProfileId")
    ) if isinstance(active_profile_properties, dict) else {}
    extends_text = local_schema_closure(extends_schema)
    active_profile_closed = (
        isinstance(active_profile_value, dict)
        and active_profile_value.get("additionalProperties") is False
        and set(active_profile_properties) == {"id", "extendsProfileId"}
        and active_profile_required in (
            {"id"}, {"id", "extendsProfileId"}
        )
        and '"string"' in extends_text
        and (
            "null" in extends_text
            or "extendsProfileId" not in active_profile_required
        )
    )
    expected_settings_contract = {
        "id": "ThreadSettingsContractV1",
        "snapshotSchemaRef": (
            "schema/domain.schema.json#/$defs/SettingsSnapshotPayloadV1"
        ),
        "snapshotFields": [
            {"field": "model", "observation": "REQUIRED", "states": ["UNKNOWN", "VALUE"]},
            {"field": "modelReasoningEffort", "observation": "NULLABLE", "states": ["UNKNOWN", "EXPLICIT_NULL", "VALUE"]},
            {"field": "serviceTier", "observation": "NULLABLE", "states": ["UNKNOWN", "EXPLICIT_NULL", "VALUE"]},
            {"field": "approvalPolicy", "observation": "REQUIRED", "states": ["UNKNOWN", "VALUE"]},
            {"field": "approvalsReviewer", "observation": "REQUIRED", "states": ["UNKNOWN", "VALUE"]},
            {
                "field": "activePermissionProfile",
                "observation": "NULLABLE",
                "states": ["UNKNOWN", "EXPLICIT_NULL", "VALUE"],
                "valueSchemaRef": (
                    "schema/domain.schema.json#/$defs/ActivePermissionProfileV1"
                ),
            },
            {"field": "sandboxPolicy", "observation": "REQUIRED", "states": ["UNKNOWN", "VALUE"]},
            {"field": "collaborationMode", "observation": "REQUIRED", "states": ["UNKNOWN", "VALUE"]},
        ],
        "explicitNullAllowedFields": [
            "modelReasoningEffort", "serviceTier", "activePermissionProfile",
        ],
        "readbackPolicy": (
            "ACTIVE_PERMISSION_PROFILE_AND_SANDBOX_POLICY_MAY_COEXIST"
        ),
        "mutationFieldInventory": [
            {
                "operationId": "OP-024",
                "mutationFields": ["model", "modelReasoningEffort"],
                "intentKinds": {
                    "model": ["VALUE"],
                    "modelReasoningEffort": ["EXPLICIT", "PROVIDER_DEFAULT"],
                },
                "requiredEvidence": "CodexSettingsCapabilitySnapshot",
                "preservedFields": [
                    "serviceTier", "approvalPolicy", "approvalsReviewer",
                    "activePermissionProfile", "sandboxPolicy",
                    "collaborationMode",
                ],
            },
            {
                "operationId": "OP-025",
                "mutationFields": ["serviceTier"],
                "intentKinds": {
                    "serviceTier": ["EXPLICIT", "PROVIDER_DEFAULT"],
                },
                "requiredEvidence": "CodexAdapterCertification",
                "preservedFields": [
                    "model", "modelReasoningEffort", "approvalPolicy",
                    "approvalsReviewer", "activePermissionProfile",
                    "sandboxPolicy", "collaborationMode",
                ],
            },
            {
                "operationId": "OP-026",
                "mutationFields": [
                    "approvalPolicy", "approvalsReviewer",
                    "executionPolicyIntent",
                ],
                "intentKinds": {
                    "executionPolicyIntent": [
                        "PERMISSIONS_PROFILE", "PERMISSIONS_PROFILE_DEFAULT",
                        "SANDBOX_POLICY",
                    ],
                },
                "requiredEvidence": "CodexAdapterCertification",
                "preservedFields": [
                    "model", "modelReasoningEffort", "serviceTier",
                    "collaborationMode",
                ],
            },
            {
                "operationId": "OP-027",
                "mutationFields": ["collaborationMode"],
                "intentKinds": {"collaborationMode": ["default", "plan"]},
                "requiredEvidence": "CodexAdapterCertification",
                "preservedFields": [
                    "model", "modelReasoningEffort", "serviceTier",
                    "approvalPolicy", "approvalsReviewer",
                    "activePermissionProfile", "sandboxPolicy",
                ],
            },
            {
                "operationId": "OP-028",
                "mutationFields": [
                    "approvalPolicy", "approvalsReviewer",
                    "executionPolicyIntent",
                ],
                "intentKinds": {
                    "executionPolicyIntent": [
                        "PERMISSIONS_PROFILE", "PERMISSIONS_PROFILE_DEFAULT",
                        "SANDBOX_POLICY",
                    ],
                },
                "requiredEvidence": "CodexAdapterCertification",
                "preservedFields": [
                    "model", "modelReasoningEffort", "serviceTier",
                    "collaborationMode",
                ],
            },
        ],
        "soleMutators": {
            "modelReasoningEffort": "OP-024",
            "model": "OP-024",
            "serviceTier": "OP-025",
            "collaborationMode": "OP-027",
        },
    }
    if (
        registry.get("settingsContract") != expected_settings_contract
        or
        not isinstance(settings_snapshot, dict)
        or settings_snapshot.get("additionalProperties") is not False
        or set(settings_properties) not in (
            thread_state_fields, thread_state_fields | {"extensions"}
        )
        or set(settings_snapshot.get("required", ())) != thread_state_fields
        or "knownFields" in settings_properties
        or set(observed_variants) != thread_state_fields
        or any(
            set(observed_variants.get(field, ())) != {"UNKNOWN", "VALUE"}
            for field in required_settings_fields
        )
        or any(
            set(observed_variants.get(field, ()))
            != {"UNKNOWN", "EXPLICIT_NULL", "VALUE"}
            for field in nullable_settings_fields
        )
        or not active_profile_closed
        or any(
            key in settings_snapshot
            for key in (
                "oneOf", "anyOf", "allOf", "not", "dependentSchemas",
                "dependentRequired",
            )
        )
        or "SETTINGS_POLICY_EXCLUSIVE" in settings_text
        or any(
            token in settings_text
            for token in (
                '"permissionMode"', '"sandboxMode"', '"PAIR"',
                '"PAIR_PROGRAMMING"', '"on-failure"',
            )
        )
    ):
        result.error(
            check_id,
            "FAIL_THREAD_STATE_PROVIDER_CONTRACT",
            "R62 settingsContract/schema must close the exact five required-value and three nullable observations, retain activePermissionProfile{id,extendsProfileId?}, allow profile+sandbox readback coexistence, and reject masks/flat aliases",
            "contracts/schema/domain.schema.json",
        )

    payload_024 = all_definitions.get("Payload_OP_024", {})
    payload_025 = all_definitions.get("Payload_OP_025", {})
    payload_026 = all_definitions.get("Payload_OP_026", {})
    payload_027 = all_definitions.get("Payload_OP_027", {})
    payload_028 = all_definitions.get("Payload_OP_028", {})
    payloads = {
        operation_id: all_definitions.get(f"Payload_{operation_id.replace('-', '_')}", {})
        for operation_id in [
            identifier for identifier in expand_id_sequence(
                final_config["operation_slots"]
            ) if identifier not in {"OP-007", "OP-023", "OP-037"}
        ]
    }
    payload_property_names: dict[str, set[str]] = {}

    def collect_schema_property_names(schema: Any) -> set[str]:
        names: set[str] = set()
        seen_refs: set[str] = set()

        def visit(node: Any) -> None:
            if isinstance(node, dict):
                reference = node.get("$ref")
                if isinstance(reference, str) and "/$defs/" in reference:
                    name = reference.rsplit("/", 1)[-1]
                    if name not in seen_refs:
                        seen_refs.add(name)
                        visit(all_definitions.get(name))
                properties = node.get("properties")
                if isinstance(properties, dict):
                    names.update(
                        key for key in properties if isinstance(key, str)
                    )
                for key, value in node.items():
                    if key != "$ref":
                        visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)

        visit(schema)
        return names

    for operation_id, payload in payloads.items():
        payload_property_names[operation_id] = collect_schema_property_names(
            payload
        )

    settings_inventory_errors = settings_operation_inventory_errors(
        payload_property_names
    )
    intent_texts = {
        operation_id: local_schema_closure(payload)
        for operation_id, payload in {
            "OP-024": payload_024,
            "OP-025": payload_025,
            "OP-026": payload_026,
            "OP-027": payload_027,
            "OP-028": payload_028,
        }.items()
    }
    if (
        settings_inventory_errors
        or not all(
            token in intent_texts["OP-024"]
            for token in ("EXPLICIT", "PROVIDER_DEFAULT")
        )
        or not all(
            token in intent_texts["OP-025"]
            for token in ("EXPLICIT", "PROVIDER_DEFAULT")
        )
        or not all(
            token in intent_texts[operation_id]
            for operation_id in ("OP-026", "OP-028")
            for token in (
                "PERMISSIONS_PROFILE", "PERMISSIONS_PROFILE_DEFAULT",
                "SANDBOX_POLICY",
            )
        )
        or not all(
            token in intent_texts["OP-027"] for token in ("default", "plan")
        )
    ):
        result.error(
            check_id,
            "FAIL_THREAD_STATE_PROVIDER_CONTRACT",
            "R62 operation schemas must expose typed default intents, keep OP-024 the sole model/effort and sole settings-capability-snapshot consumer, bind OP-025..028 to exact Codex certification, and keep OP-028 execution-policy-only",
            "contracts/schema/operation-union.schema.json",
        )

    def sealed_union_by_consts(expected: set[str]) -> tuple[str | None, Mapping[str, Any] | None, dict[str, Mapping[str, Any]]]:
        for name, definition in all_definitions.items():
            branches = definition.get("oneOf") if isinstance(definition, dict) else None
            if not isinstance(branches, list):
                continue
            indexed: dict[str, Mapping[str, Any]] = {}
            for branch in branches:
                properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
                constants = [
                    schema.get("const")
                    for schema in properties.values()
                    if isinstance(schema, dict) and isinstance(schema.get("const"), str)
                ] if isinstance(properties, dict) else []
                if len(constants) == 1:
                    indexed[constants[0]] = branch
            if set(indexed) == expected and len(indexed) == len(branches):
                return name, definition, indexed
        return None, None, {}

    goal_states = {
        "ABSENT_PROVEN", "CLEARED_PROVEN", "ACTIVE", "PAUSED",
        "BUDGET_LIMITED", "COMPLETED",
    }
    goal_union = all_definitions.get("GoalSnapshotPayloadV1")
    raw_goal_branches = (
        goal_union.get("oneOf", ())
        if isinstance(goal_union, dict)
        else ()
    )
    budget_name, budget_union, budget_branches = sealed_union_by_consts({
        "UNBOUNDED", "TOKEN_BUDGET"
    })
    usage_name, usage_union, usage_branches = sealed_union_by_consts({
        "UNKNOWN", "TOKEN_USAGE"
    })
    no_value_states = {"ABSENT_PROVEN", "CLEARED_PROVEN"}
    value_states = goal_states - no_value_states
    observed_goal_state_sets: set[frozenset[str]] = set()
    goal_shape_bad = (
        not isinstance(raw_goal_branches, list)
        or len(raw_goal_branches) != 2
        or "remaining" in all_definitions.get(
            "GoalSnapshotValue", {}
        ).get("properties", {})
    )
    for branch in raw_goal_branches if isinstance(raw_goal_branches, list) else ():
        properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
        required = set(branch.get("required", ())) if isinstance(branch, dict) else set()
        state_schema = properties.get("goalState", {}) if isinstance(properties, dict) else {}
        states = set(state_schema.get("enum", ())) if isinstance(state_schema, dict) else set()
        if isinstance(state_schema.get("const") if isinstance(state_schema, dict) else None, str):
            states.add(state_schema["const"])
        observed_goal_state_sets.add(frozenset(states))
        value_present = "value" in properties
        if (
            not states
            or branch.get("additionalProperties") is not False
            or not set(branch.get("required", ())).issubset(properties)
            or (states == no_value_states and value_present)
            or (
                states == value_states
                and (not value_present or "value" not in required)
            )
            or states not in (no_value_states, value_states)
        ):
            goal_shape_bad = True
    if observed_goal_state_sets != {
        frozenset(no_value_states), frozenset(value_states)
    }:
        goal_shape_bad = True
    budget_text = local_schema_closure(budget_union or {})
    usage_text = local_schema_closure(usage_union or {})
    budget_token_schema = local_definition(
        budget_branches.get("TOKEN_BUDGET", {}).get("properties", {}).get(
            "tokens"
        )
    )
    positive_budget = (
        "PositiveUInt64Decimal" in budget_text
        or (
            isinstance(budget_token_schema, dict)
            and budget_token_schema.get("type") == "string"
            and budget_token_schema.get("pattern")
            == r"^[1-9][0-9]{0,19}$"
        )
    )
    if (
        goal_shape_bad
        or budget_union is None
        or usage_union is None
        or not positive_budget
        or "UInt64Decimal" not in usage_text
        or "evidenceRef" not in usage_text
    ):
        result.error(
            check_id,
            "FAIL_GOAL_SEALED_UNION",
            "R50/R53 require the six-state canonical Goal union, value absence/presence split, positive token budget, evidence-bound usage, and no independent remaining/status/unknown state",
            "contracts/schema/domain.schema.json",
        )

    expected_lineage_fields = {
        "ARTIFACT": ({"kind", "artifactId", "artifactGeneration"}, "artifact"),
        "GALLERY_ASSET": (
            {"kind", "galleryNamespace", "assetId", "assetGeneration"},
            "gallery",
        ),
        "MESSAGE_IMAGE": (
            {"kind", "threadRef", "providerItemId", "imageGeneration"},
            "messageImage",
        ),
        "CAPTURE": (
            {"kind", "captureScopeId", "captureId", "captureGeneration"},
            "capture",
        ),
        "TRANSFER": (
            {"kind", "transferId", "transferGeneration", "finalizationReceiptId"},
            "transfer",
        ),
        "GIT_MATERIALIZATION": (
            {"kind", "workspaceId", "repositoryGeneration", "materializationId"},
            "git",
        ),
        "EVENT_EXPORT": (
            {"kind", "recordingId", "recordingGeneration", "redactionPolicyRevision"},
            "eventExport",
        ),
    }
    content_ref = all_definitions.get("ContentRef")
    content_branches = content_ref.get("oneOf") if isinstance(content_ref, dict) else None
    observed_lineages: dict[str, tuple[set[str], Any]] = {}
    if isinstance(content_branches, list):
        for branch in content_branches:
            properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
            lineage = properties.get("lineage", {}) if isinstance(properties, dict) else {}
            lineage_properties = lineage.get("properties", {}) if isinstance(lineage, dict) else {}
            kind_schema = lineage_properties.get("kind", {}) if isinstance(lineage_properties, dict) else {}
            kind = kind_schema.get("const") if isinstance(kind_schema, dict) else None
            owner_schema = properties.get("ownerFeatureId", {}) if isinstance(properties, dict) else {}
            owner = owner_schema.get("const") if isinstance(owner_schema, dict) else None
            if isinstance(kind, str):
                observed_lineages[kind] = (set(lineage_properties), owner)
            if (
                not isinstance(branch, dict)
                or branch.get("additionalProperties") is not False
                or not isinstance(lineage, dict)
                or lineage.get("additionalProperties") is not False
                or set(lineage.get("required", ())) != set(lineage_properties)
            ):
                observed_lineages["__INVALID__"] = (set(), None)
    expected_lineages = {
        kind: (fields, owner)
        for kind, (fields, owner) in expected_lineage_fields.items()
    }
    if observed_lineages != expected_lineages:
        result.error(
            check_id,
            "FAIL_CONTENT_LINEAGE_UNION",
            "ContentRef must retain the exact seven sealed lineage/owner variants without nullable generic fields",
            "contracts/schema/domain.schema.json",
        )

    durable_schema_path = (schema_root / "durable-event.schema.json").resolve()
    durable_schema_document = schema_documents.get(durable_schema_path, {})
    durable_definitions = (
        durable_schema_document.get("$defs", {})
        if isinstance(durable_schema_document, dict)
        else {}
    )
    event_key = durable_definitions.get("EventKeyV1")
    message_key = durable_definitions.get("MessageKeyV1")
    durable_envelope = durable_definitions.get("DurableEventEnvelopeV1")
    message_preimage = durable_definitions.get("EnvelopeMessagePreimageV1")
    event_fields = {"sourcePartition", "ownerKind", "aggregateRef", "eventId"}
    message_fields = {"sourcePartition", "subscriptionId", "streamId", "messageId"}
    durable_messages = [
        message
        for message in registry.get("messages", [])
        if isinstance(message, dict) and message.get("delivery") == "DURABLE_STREAM"
    ]
    durable_kinds = [message.get("kind") for message in durable_messages]
    durable_route_mapping = {
        message.get("kind"): (
            tuple(message.get("allowedProjectionRoutes", ())),
            message.get("streamName"),
        )
        for message in durable_messages
    }
    expected_durable_route_mapping = {
        kind: ((route,), stream)
        for kind, (route, stream) in FIXED_DURABLE_MESSAGE_ROUTES.items()
    }
    projection_route = all_definitions.get("ProjectionRouteV1")
    projection_route_branches = (
        projection_route.get("oneOf", ())
        if isinstance(projection_route, dict)
        else ()
    )
    projection_pairs: set[tuple[Any, Any]] = set()
    if isinstance(projection_route_branches, list):
        for branch_ref in projection_route_branches:
            branch = local_definition(branch_ref)
            properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
            projection_pairs.add(
                (
                    local_definition(properties.get("projectionKind", {})).get("const"),
                    local_definition(properties.get("audience", {})).get("const"),
                )
            )
    expected_projection_pairs = {
        tuple(route.split("/", 1))
        for route, _ in FIXED_DURABLE_MESSAGE_ROUTES.values()
    }
    if (
        durable_route_mapping != expected_durable_route_mapping
        or projection_pairs != expected_projection_pairs
        or len(projection_route_branches) != 3
    ):
        result.error(
            check_id,
            "FAIL_PROJECTION_ROUTE_ALGEBRA",
            "R58 requires the exact per-kind route/stream map and sealed three-pair ProjectionRouteV1, never a Cartesian product",
            relative,
        )
    envelope_properties = (
        durable_envelope.get("properties", {})
        if isinstance(durable_envelope, dict)
        else {}
    )
    envelope_kind_values = (
        envelope_properties.get("kind", {}).get("enum", ())
        if isinstance(envelope_properties.get("kind"), dict)
        else ()
    )
    durable_payload_union = durable_definitions.get("DurablePayloadV1", {})
    durable_payload_refs = [
        (
            "durable-event.schema.json" + branch["$ref"]
            if branch.get("$ref", "").startswith("#")
            else branch.get("$ref")
        )
        for branch in durable_payload_union.get("oneOf", ())
        if isinstance(branch, dict) and isinstance(branch.get("$ref"), str)
    ] if isinstance(durable_payload_union, dict) else []
    registered_payload_refs = [
        str(message.get("payloadSchemaRef", "")).removeprefix("schema/")
        for message in durable_messages
    ]
    envelope_required = set(
        durable_envelope.get("required", ())
    ) if isinstance(durable_envelope, dict) else set()
    preimage_properties = (
        message_preimage.get("properties", {})
        if isinstance(message_preimage, dict)
        else {}
    )
    preimage_required = set(
        message_preimage.get("required", ())
    ) if isinstance(message_preimage, dict) else set()
    envelope_rule_ids = [
        rule.get("ruleId")
        for rule in rule_inventory
        if isinstance(rule, dict)
        and "schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1"
        in rule.get("schemaRefs", ())
    ]
    if (
        not isinstance(event_key, dict)
        or event_key.get("additionalProperties") is not False
        or set(event_key.get("properties", ())) != event_fields
        or set(event_key.get("required", ())) != event_fields
        or not isinstance(message_key, dict)
        or message_key.get("additionalProperties") is not False
        or set(message_key.get("properties", ())) != message_fields
        or set(message_key.get("required", ())) != message_fields
        or not isinstance(durable_envelope, dict)
        or durable_envelope.get("additionalProperties") is not False
        or not isinstance(message_preimage, dict)
        or message_preimage.get("additionalProperties") is not False
        or set(envelope_properties) != set(preimage_properties) | {"messageDigest"}
        or envelope_required != preimage_required | {"messageDigest"}
        or set(preimage_properties) != preimage_required | (
            {"extensions"} if "extensions" in preimage_properties else set()
        )
        or message_preimage.get("x-ruleIds") != ["DURABLE_MESSAGE_PREIMAGE"]
        or bool({"frameDigest", "frameByteLength"} & set(envelope_properties))
        or durable_envelope.get("x-ruleIds") != envelope_rule_ids
        or list(envelope_kind_values) != durable_kinds
        or durable_payload_refs != registered_payload_refs
        or any(
            message.get("schemaRef")
            != "schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1"
            or not isinstance(message.get("payloadSchemaRef"), str)
            for message in durable_messages
        )
    ):
        result.error(
            check_id,
            "FAIL_DURABLE_EVENT_ENVELOPE",
            "R49/R54 require distinct EventKey/MessageKey, one shared non-circular envelope without frame metadata, and registry-derived exact durable kind/payload coverage",
            "contracts/schema/durable-event.schema.json",
        )

    materialization_messages = {
        message.get("kind"): message
        for message in durable_messages
        if isinstance(message.get("kind"), str)
        and message["kind"].startswith("materialization.")
    }
    expected_materialization_payload_refs = {
        "materialization.begin": "schema/durable-event.schema.json#/$defs/MaterializationBeginPayloadV1",
        "materialization.page": "schema/durable-event.schema.json#/$defs/MaterializationPagePayloadV1",
        "materialization.commit": "schema/durable-event.schema.json#/$defs/MaterializationCommitPayloadV1",
    }
    subject_name, subject_union, subject_branches = sealed_union_by_consts({
        "CATALOG", "TIMELINE"
    })
    begin_payload = durable_definitions.get("MaterializationBeginPayloadV1", {})
    page_payload = durable_definitions.get("MaterializationPagePayloadV1", {})
    commit_payload = durable_definitions.get("MaterializationCommitPayloadV1", {})
    block_common = durable_definitions.get("MaterializationBlockCommonV1", {})
    receipt_union = all_definitions.get("MaterializationVerificationReceiptV1", {})
    receipt_preimage = all_definitions.get("MaterializationReceiptPreimageV1", {})
    receipt_branches = (
        receipt_union.get("oneOf", ())
        if isinstance(receipt_union, dict)
        else ()
    )
    resolved_receipt_branches = [
        local_definition(branch) for branch in receipt_branches
    ] if isinstance(receipt_branches, list) else []

    def page_count_bounds(definition: Mapping[str, Any]) -> tuple[Any, Any]:
        schema = definition.get("properties", {}).get("pageCount", {})
        return (
            schema.get("minimum") if isinstance(schema, dict) else None,
            schema.get("maximum") if isinstance(schema, dict) else None,
        )

    page_body_schema = page_payload.get("properties", {}).get("pageBody", {})
    page_body_branches = page_body_schema.get("oneOf") if isinstance(page_body_schema, dict) else None
    page_body_definitions: list[Mapping[str, Any]] = []
    if isinstance(page_body_branches, list):
        for branch in page_body_branches:
            resolved = local_definition(branch)
            if isinstance(resolved, dict):
                page_body_definitions.append(resolved)
    if (
        {kind: item.get("payloadSchemaRef") for kind, item in materialization_messages.items()}
        != expected_materialization_payload_refs
        or subject_union is None
        or page_count_bounds(begin_payload) != (0, 128)
        or page_count_bounds(page_payload) != (1, 128)
        or page_count_bounds(commit_payload) != (0, 128)
        or page_payload.get("properties", {}).get("pageIndex", {}).get("minimum") != 0
        or page_payload.get("properties", {}).get("pageIndex", {}).get("maximum") != 127
        or commit_payload.get("properties", {}).get("receipt", {}).get("$ref")
        != "domain.schema.json#/$defs/MaterializationVerificationReceiptV1"
        or len(page_body_definitions) != 2
        or not isinstance(block_common, dict)
        or block_common.get("additionalProperties") is not False
        or set(block_common.get("properties", ())) != {
            "subject", "blockId", "beginHeaderDigest", "receiptId",
            "manifestDigest",
        }
        or set(block_common.get("required", ())) != {
            "subject", "blockId", "beginHeaderDigest", "receiptId",
            "manifestDigest",
        }
        or any(
            payload.get("properties", {}).get("block", {}).get("$ref")
            != "#/$defs/MaterializationBlockCommonV1"
            for payload in (begin_payload, page_payload, commit_payload)
        )
        or not {
            "pageCount", "expectedManifestDigest", "expectedCoverageDigest",
            "declaredCompleteness",
        }.issubset(set(begin_payload.get("required", ())))
        or not isinstance(receipt_branches, list)
        or len(receipt_branches) != 2
        or any(
            branch.get("x-ruleIds") != ["MATERIALIZATION_RECEIPT_DIGEST"]
            or "receiptId" not in branch.get("required", ())
            for branch in resolved_receipt_branches
        )
        or not isinstance(receipt_preimage, dict)
        or receipt_preimage.get("x-ruleIds")
        != ["MATERIALIZATION_RECEIPT_PREIMAGE"]
        or not isinstance(receipt_preimage.get("oneOf"), list)
        or len(receipt_preimage.get("oneOf", ())) != len(
            resolved_receipt_branches
        )
        or any(
            not isinstance(branch, dict)
            or branch.get("additionalProperties") is not False
            or set(branch.get("properties", ()))
            != set(branch.get("required", ()))
            for branch in receipt_preimage.get("oneOf", ())
        )
        or {
            frozenset(branch.get("properties", ()))
            for branch in receipt_preimage.get("oneOf", ())
            if isinstance(branch, dict)
        }
        != {
            frozenset(
                set(branch.get("properties", ())) - {"receiptDigest"}
            )
            for branch in resolved_receipt_branches
            if isinstance(branch, dict)
        }
    ):
        result.error(
            check_id,
            "FAIL_MATERIALIZATION_BLOCK_CONTRACT",
            "R49/R59 require generic CATALOG/TIMELINE whole blocks, exact frozen begin evidence, shared receipt/manifest identity, digest-free page bodies, and a receipt preimage excluding only receiptDigest",
            "contracts/schema/durable-event.schema.json",
        )

    actor_definition_names = {
        "AuthenticatedActor",
        "ActorProjection",
        "AuthenticatedActorTicketBinding",
    }
    if not actor_definition_names.issubset(all_definitions):
        result.error(
            check_id,
            "FAIL_ACTOR_PROJECTION_SCHEMA",
            "schemas must keep internal actor, privacy-safe projection, and ticket binding distinct",
            "contracts/schema/domain.schema.json",
        )
    else:
        for definition_name, allowed_fields, required_fields in (
            (
                "ActorProjection",
                {"actorKind", "principalDigest", "displayLabel"},
                {"actorKind", "principalDigest"},
            ),
            (
                "AuthenticatedActorTicketBinding",
                {"actorKind", "actorBindingDigest"},
                {"actorKind", "actorBindingDigest"},
            ),
        ):
            branches = all_definitions[definition_name].get("oneOf")
            if (
                not isinstance(branches, list)
                or len(branches) != 3
                or any(
                    not isinstance(branch, dict)
                    or branch.get("additionalProperties") is not False
                    or set(branch.get("properties", ())) != allowed_fields
                    or set(branch.get("required", ())) != required_fields
                    for branch in branches
                )
            ):
                result.error(
                    check_id,
                    "FAIL_ACTOR_PROJECTION_SCHEMA",
                    f"{definition_name} must be a closed three-variant privacy-safe union",
                    "contracts/schema/domain.schema.json",
                )
    for schema_path, schema_document in schema_documents.items():
        if schema_path.name not in {
            "envelope.schema.json", "messages.schema.json",
            "operation-union.schema.json",
        }:
            continue
        wire_schema_text = stable_json(schema_document)
        if re.search(
            r"(?:/|#\/$defs/)AuthenticatedActor(?:\"|$)", wire_schema_text
        ):
            result.error(
                check_id,
                "FAIL_ACTOR_PROJECTION_SCHEMA",
                "wire schemas may reference only ActorProjection/TicketBinding, never internal AuthenticatedActor",
                schema_path.relative_to(result.design_root).as_posix(),
            )
    receipt_definition = all_definitions.get("MaterializationVerificationReceiptV1")
    common_receipt_fields = {
        "algorithmVersion", "sourcePartition",
        "materializationId", "receiptId", "readSpecDigest", "readEvidenceDigest",
        "codexCertificationId", "codexCertificationDigest",
        "expectedHeadVersion", "pageCount", "pageManifestDigest",
        "coverageDigest", "manifestDigest", "result", "receiptDigest",
    }
    receipt_definition_branches = (
        receipt_definition.get("oneOf", ())
        if isinstance(receipt_definition, dict)
        else ()
    )
    resolved_definition_branches = [
        local_definition(branch) for branch in receipt_definition_branches
    ] if isinstance(receipt_definition_branches, list) else []
    if (
        not isinstance(receipt_definition, dict)
        or not isinstance(receipt_definition_branches, list)
        or len(resolved_definition_branches) != 2
        or any(
            not isinstance(branch, dict)
            or branch.get("additionalProperties") is not False
            or set(branch.get("properties", ()))
            != set(branch.get("required", ()))
            or not common_receipt_fields.issubset(branch.get("properties", ()))
            or branch.get("x-ruleIds")
            != ["MATERIALIZATION_RECEIPT_DIGEST"]
            for branch in resolved_definition_branches
        )
        or not any(
            {"catalogScopeId", "sessionCount"}.issubset(
                branch.get("properties", ())
            )
            for branch in resolved_definition_branches
        )
        or not any(
            {"threadRef", "turnCount", "itemCount", "islandCount", "gapCount"}
            .issubset(branch.get("properties", ()))
            for branch in resolved_definition_branches
        )
    ):
        result.error(
            check_id,
            "FAIL_MATERIALIZATION_VERIFIER_RECEIPT",
            "MaterializationVerificationReceiptV1 lacks independently recomputable identity/count/digest/result fields",
            "contracts/schema/domain.schema.json",
        )

    read_spec = all_definitions.get("ReadSpec")
    read_branches = read_spec.get("oneOf") if isinstance(read_spec, dict) else None
    read_selectors: set[str] = set()
    if isinstance(read_branches, list):
        for branch in read_branches:
            properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
            selector_schema = properties.get(
                "direction",
                properties.get("selector", properties.get("kind", {})),
            ) if isinstance(properties, dict) else {}
            if isinstance(selector_schema, dict):
                selector = selector_schema.get("const")
                if isinstance(selector, str):
                    read_selectors.add(selector)
                read_selectors.update(
                    value for value in selector_schema.get("enum", ())
                    if isinstance(value, str)
                )
    if (
        not isinstance(read_branches, list)
        or len(read_branches) not in {3, 4}
        or read_selectors != {"TAIL", "BEFORE", "AFTER", "AROUND"}
        or any(
            not isinstance(branch, dict) or branch.get("additionalProperties") is not False
            for branch in read_branches
        )
    ):
        result.error(
            check_id,
            "FAIL_TIMELINE_SELECTOR_UNION",
            "ReadSpec must be one closed TAIL/BEFORE/AFTER/AROUND selector union",
            "contracts/schema/domain.schema.json",
        )
    evidence_definition_names = {
        "CodexAdapterCertification",
        "CodexSettingsCapabilitySnapshot",
        "NativeHostCapabilitySnapshot",
        "FeatureCapabilitySnapshot",
    }
    if not evidence_definition_names.issubset(all_definitions) or any(
        name in all_definitions for name in ("CapabilitySnapshot", "CapabilitySnapshotV1")
    ):
        result.error(
            check_id,
            "FAIL_FEATURE_CAPABILITY_SNAPSHOT",
            "schemas must define the four distinct Codex/settings/native/feature evidence contracts and no ambiguous generic CapabilitySnapshot",
            "contracts/schema",
        )
    else:
        codex_definition = all_definitions["CodexAdapterCertification"]
        settings_capability_definition = all_definitions["CodexSettingsCapabilitySnapshot"]
        native_definition = all_definitions["NativeHostCapabilitySnapshot"]
        feature_definition = all_definitions["FeatureCapabilitySnapshot"]
        codex_properties = codex_definition.get("properties", {})
        settings_capability_properties = settings_capability_definition.get("properties", {})
        native_properties = native_definition.get("properties", {})
        feature_properties = feature_definition.get("properties", {})
        if (
            not {"codexCertificationId", "codexCertificationDigest"}.issubset(codex_properties)
            or not {
                "codexSettingsCapabilitySnapshotId", "snapshotRevision",
                "codexCertificationId", "codexCertificationDigest", "models",
            }.issubset(settings_capability_properties)
            or not {"nativeHostCapabilitySnapshotId", "nativeHostCapabilitySnapshotDigest"}.issubset(native_properties)
            or not {
                "featureCapabilitySnapshotId", "featureCapabilitySnapshotDigest",
                "codexCertificationRefs", "nativeHostCapabilitySnapshotRefs",
                "snapshotRevision", "entries",
            }.issubset(feature_properties)
        ):
            result.error(
                check_id,
                "FAIL_CAPABILITY_EVIDENCE_SCOPE",
                "capability evidence identities/refs are ambiguous or incomplete",
                "contracts/schema/domain.schema.json",
            )
        snapshot_closure_text = "\n".join(
            stable_json(definition)
            for definition in (
                codex_definition, settings_capability_definition,
                native_definition, feature_definition,
            )
        )
        if (
            any(
                definition.get("additionalProperties") is not False
                for definition in (
                    codex_definition, settings_capability_definition,
                    native_definition, feature_definition,
                )
            )
            or not all(
                term in snapshot_closure_text
                for term in (
                    "snapshotRevision", "hostKind", "hostEpoch",
                    "lifecycleEpoch", "version", "evidenceKind",
                    "currentHostKind", "entries",
                )
            )
        ):
            result.error(
                check_id,
                "FAIL_CAPABILITY_EVIDENCE_IMMUTABILITY",
                "R44 snapshots must be closed one-based immutable current-host evidence unions with version/lifecycle and entry bindings",
                "contracts/schema/domain.schema.json",
            )
        snapshot_text = stable_json(feature_definition) + stable_json(
            all_definitions.get("FeatureCapabilityEntry", {})
        )
        missing_snapshot_terms = [
            term for term in ("support", "availability", "revision", "evidence", "cause")
            if not re.search(fr"(?i){term}", snapshot_text)
        ]
        if missing_snapshot_terms:
            result.error(
                check_id,
                "FAIL_FEATURE_CAPABILITY_SNAPSHOT",
                "CapabilitySnapshot is missing evidence-bound axes: " + ", ".join(missing_snapshot_terms),
                "contracts/schema",
            )
    schema_references = 0
    for collection in ("semantics", "messages", "operations"):
        for index, item in enumerate(registry.get(collection, [])):
            if not isinstance(item, dict):
                continue
            for key, reference in item.items():
                if not key.endswith("SchemaRef") or reference is None:
                    continue
                schema_references += 1
                if not isinstance(reference, str):
                    result.error(check_id, "FAIL_REGISTRY_SCHEMA_REFERENCE", f"{key} must be a string", f"{relative}#{collection}/{index}")
                    continue
                file_part, separator, fragment = reference.partition("#")
                target = (schema_root / file_part.removeprefix("schema/")).resolve(strict=False)
                if target not in schema_documents or (separator and not resolve_json_pointer(schema_documents[target], f"#{fragment}")):
                    result.error(check_id, "FAIL_REGISTRY_SCHEMA_REFERENCE", f"unresolved schema reference: {reference}", f"{relative}#{collection}/{index}")

    machine_rendered = stable_json(registry) + "\n" + "\n".join(
        stable_json(document) for document in schema_documents.values()
    )
    receive_order_terms = {
        "materialization": r"(?i)materializationId",
        "TurnSpine": r"(?i)TurnSpine",
        "coverage": r"(?i)coverage(?:Claim|Island|Proof)?",
        "Gap": r"(?i)(?:CatalogGapV1|TimelineGapV1|CoverageGap|GapRepairIntentV1)",
        "order proof": r"(?i)orderProof",
        "last-good": r"(?i)(?:LAST_GOOD|lastGood)",
        "CAS": r"\bCAS\b",
    }
    missing_receive_order = [
        name for name, pattern in receive_order_terms.items()
        if not re.search(pattern, machine_rendered)
    ]
    message_kinds = id_sets.get("messages", set())
    required_materialization_messages = {
        "materialization.begin",
        "materialization.page",
        "materialization.commit",
    }
    required_receive_machines = {
        "SM-READ-ATTEMPT", "SM-TIMELINE-HEAD", "SM-GAP-REPAIR",
        "SM-REPLICA-APPLY",
    }
    if missing_receive_order or not required_materialization_messages.issubset(message_kinds):
        result.error(
            check_id,
            "FAIL_RECEIVE_ORDER_MACHINE_BINDING",
            "receive/order machine binding is incomplete; missing terms/messages: "
            + ", ".join(
                [*missing_receive_order, *sorted(required_materialization_messages - message_kinds)]
            ),
            relative,
        )
    if not required_receive_machines.issubset(set(registry_sm_ids)):
        result.error(
            check_id,
            "FAIL_RECEIVE_ORDER_MACHINE_BINDING",
            "receive/order lacks required state-machine owners: "
            + ", ".join(sorted(required_receive_machines - set(registry_sm_ids))),
            relative,
        )
    messages_by_kind = {
        item.get("kind"): item
        for item in registry.get("messages", [])
        if isinstance(item, dict) and isinstance(item.get("kind"), str)
    }
    for kind in ("materialization.begin",):
        item = messages_by_kind.get(kind)
        reference = item.get("payloadSchemaRef") if isinstance(item, dict) else None
        definition: Any = None
        if isinstance(reference, str):
            file_part, _, fragment = reference.partition("#")
            target_path = (schema_root / file_part.removeprefix("schema/")).resolve(strict=False)
            found, definition = resolve_json_pointer_value(
                schema_documents.get(target_path), f"#{fragment}"
            ) if target_path in schema_documents else (False, None)
        else:
            found = False
        payload = definition if found and isinstance(definition, dict) else None
        payload_properties = payload.get("properties", {}) if isinstance(payload, dict) else {}
        payload_required = set(payload.get("required", ())) if isinstance(payload, dict) else set()
        if (
            not {"codexCertificationId", "codexCertificationDigest"}.issubset(payload_properties)
            or not {"codexCertificationId", "codexCertificationDigest"}.issubset(payload_required)
            or any(
                key in payload_properties
                for key in ("featureCapabilitySnapshotId", "nativeHostCapabilitySnapshotId")
            )
        ):
            result.error(
                check_id,
                "FAIL_CAPABILITY_EVIDENCE_SCOPE",
                f"{kind} payload must bind only Codex certification identity/digest",
                relative,
            )

    domain_path = (schema_root / "domain.schema.json").resolve()
    operation_schema_path = (schema_root / "operation-union.schema.json").resolve()
    operation_schema = schema_documents.get(operation_schema_path)
    if isinstance(operation_schema, dict):
        check_operation_schema_consistency(
            result, check_id, registry.get("operations", []), operation_schema,
            "contracts/schema/operation-union.schema.json",
        )
    domain = schema_documents.get(domain_path)
    if isinstance(domain, dict):
        definitions = domain.get("$defs", {})
        source_schema = definitions.get("SourcePartition", {}) if isinstance(definitions, dict) else {}
        if tuple(source_schema.get("required", ())) != CANONICAL_SOURCE_PARTITION or tuple(source_schema.get("properties", ())) != CANONICAL_SOURCE_PARTITION:
            result.error(check_id, "FAIL_SOURCE_PARTITION", "SourcePartition schema must be the exact ordered triple", "contracts/schema/domain.schema.json#/$defs/SourcePartition")
        check_content_ticket_unions(result, check_id, definitions, "contracts/schema/domain.schema.json")

    operation_key_schemas: list[Mapping[str, Any]] = []
    if isinstance(domain, dict) and isinstance(domain.get("$defs"), dict):
        named_operation_key = domain["$defs"].get("OperationKey")
        if isinstance(named_operation_key, dict):
            operation_key_schemas.append(named_operation_key)
    for document in schema_documents.values():
        definitions = document.get("$defs") if isinstance(document, dict) else None
        if not isinstance(definitions, dict):
            continue
        for name, definition in definitions.items():
            if name.startswith("Fingerprint_") and isinstance(definition, dict):
                operation_key = definition.get("properties", {}).get("operationKey")
                if isinstance(operation_key, dict):
                    operation_key_schemas.append(operation_key)
    if not operation_key_schemas or any(
        tuple(schema.get("required", ())) != ("sourcePartition", "operationId")
        or tuple(schema.get("properties", ())) != ("sourcePartition", "operationId")
        or schema.get("additionalProperties") is not False
        for schema in operation_key_schemas
    ):
        result.error(
            check_id,
            "FAIL_OPERATION_KEY",
            "every OperationKey schema must be the closed SourcePartition+operationId pair",
            "contracts/schema",
        )

    return {
        "arrays": arrays_checked,
        "references": references_checked,
        "required_keys": len(FIXED_MACHINE_SOURCE_KEYS),
        "schema_references": schema_references,
        "state_machines": len(machines),
        "operation_slots": len(operation_ids),
        "lanes": len(lane_values),
        "feature_contributions": len(contributions),
        "product_capability_bindings": len(bindings),
    }


def check_operation_schema_consistency(
    result: ValidationResult,
    check_id: str,
    operations: Any,
    schema: Mapping[str, Any],
    relative: str,
) -> None:
    definitions = schema.get("$defs")
    if not isinstance(operations, list) or not isinstance(definitions, dict):
        result.error(check_id, "FAIL_OPERATION_SCHEMA_STRUCTURE", "operation registry/schema definitions are missing", relative)
        return
    expected_public_refs: list[str] = []
    reserved = {
        "OP-007": ("RETRY_OPERATION_TOMBSTONE", "TOMBSTONE"),
        "OP-023": ("EXPIRE_INTERACTION", "INTERNAL_ONLY"),
        "OP-037": ("CANCEL_SUBAGENT_RESERVED", "DISABLED_UNREACHABLE"),
    }
    for index, operation in enumerate(operations):
        if not isinstance(operation, dict) or not isinstance(operation.get("id"), str):
            continue
        operation_id = operation["id"]
        if operation_id in reserved and (
            operation.get("name"), operation.get("exposure")
        ) != reserved[operation_id]:
            result.error(
                check_id,
                "FAIL_OPERATION_ID_NAME_DRIFT",
                f"{operation_id} reserved name/exposure differs from {reserved[operation_id]!r}",
                relative,
            )
        definition_name = (
            "InternalTransition_OP_023"
            if operation_id == "OP-023"
            else f"Operation_{operation_id.replace('-', '_')}"
        )
        reference = f"#/$defs/{definition_name}"
        if operation.get("exposure") == "PUBLIC":
            expected_public_refs.append(reference)
        definition = definitions.get(definition_name)
        schema_ref = operation.get("operationSchemaRef")
        if schema_ref is None:
            if operation.get("exposure") == "PUBLIC":
                result.error(check_id, "FAIL_OPERATION_ID_NAME_DRIFT", f"public {operation_id} has no operation schema", f"{relative}#/{definition_name}")
            continue
        expected_schema_ref = (
            f"schema/operation-union.schema.json#/$defs/{definition_name}"
        )
        if schema_ref != expected_schema_ref:
            result.error(
                check_id,
                "FAIL_OPERATION_SCHEMA_REFERENCE",
                f"{operation_id} operationSchemaRef must be {expected_schema_ref}",
                f"{relative}#/$defs/{definition_name}",
            )
        kind_field = "transitionKind" if operation_id == "OP-023" else "operationKind"
        kind = (
            definition.get("properties", {}).get(kind_field, {}).get("const")
            if isinstance(definition, dict)
            else None
        )
        if kind != operation.get("name"):
            result.error(
                check_id,
                "FAIL_OPERATION_ID_NAME_DRIFT",
                f"{operation_id} registry name {operation.get('name')!r} differs from schema const {kind!r}",
                f"{relative}#/$defs/{definition_name}",
            )
    public = definitions.get("PublicOperation")
    branches = public.get("oneOf") if isinstance(public, dict) else None
    actual_public_refs = [branch.get("$ref") for branch in branches if isinstance(branch, dict)] if isinstance(branches, list) else []
    if actual_public_refs != expected_public_refs or any(
        marker in actual_public_refs
        for marker in (
            "#/$defs/Operation_OP_007",
            "#/$defs/Operation_OP_023",
            "#/$defs/Operation_OP_037",
        )
    ):
        result.error(
            check_id,
            "FAIL_PUBLIC_OPERATION_UNION",
            "PublicOperation union must exactly match PUBLIC registry slots and exclude OP-007/023/037",
            f"{relative}#/$defs/PublicOperation",
        )


def check_content_ticket_unions(
    result: ValidationResult,
    check_id: str,
    definitions: Any,
    relative: str,
) -> None:
    if not isinstance(definitions, dict) or "ContentRef" not in definitions:
        result.error(check_id, "FAIL_CONTENT_REF_SCHEMA", "ContentRef definition is missing", relative)
        return
    for name in ("ContentAccessTicket", "ContentTicketIssueRequest"):
        schema = definitions.get(name)
        branches = schema.get("oneOf") if isinstance(schema, dict) else None
        if not isinstance(branches, list) or len(branches) != 2:
            result.error(check_id, "FAIL_CONTENT_TICKET_UNION", f"{name} must be an exact two-branch oneOf", relative)
            continue
        kinds: list[Any] = []
        for branch in branches:
            properties = branch.get("properties", {}) if isinstance(branch, dict) else {}
            required = branch.get("required", []) if isinstance(branch, dict) else []
            kind = properties.get("targetKind", {}).get("const") if isinstance(properties, dict) and isinstance(properties.get("targetKind"), dict) else None
            kinds.append(kind)
            expected_field = "offerId" if kind == "OFFER_TARGET" else "contentRefId"
            forbidden_field = "contentRefId" if kind == "OFFER_TARGET" else "offerId"
            if (
                branch.get("additionalProperties") is not False
                or "targetKind" not in required
                or expected_field not in required
                or forbidden_field in properties
            ):
                result.error(check_id, "FAIL_CONTENT_TICKET_UNION", f"{name}/{kind} is not a closed exclusive target branch", relative)
        if set(kinds) != {"OFFER_TARGET", "REF_TARGET"}:
            result.error(check_id, "FAIL_CONTENT_TICKET_UNION", f"{name} must discriminate OFFER_TARGET and REF_TARGET", relative)


def check_full_design(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    relative = "drafts/FULL-DESIGN-SYNTHESIS.md"
    path = result.design_root / relative
    try:
        content = read_text(path)
    except (OSError, UnicodeError) as exc:
        result.error(
            check_id,
            "FAIL_FULL_DESIGN_READ",
            f"FULL-DESIGN-SYNTHESIS.md cannot be read: {exc}",
            relative,
        )
        return {"bytes": 0, "required_terms": 0}
    if len(content.encode("utf-8")) < 4096:
        result.error(
            check_id,
            "FAIL_FULL_DESIGN_INCOMPLETE",
            "FULL-DESIGN-SYNTHESIS.md is too small to be the cumulative design",
            relative,
        )
    leading_lines = content.splitlines()[:20]
    status_lines = [
        line.strip() for line in leading_lines
        if re.match(r"^(?:状态|Status)\s*[：:]", line.strip(), re.IGNORECASE)
    ]
    status_line = status_lines[0] if len(status_lines) == 1 else ""
    if (
        not status_line
        or "IMPLEMENTATION_READY" not in status_line
        or "SOURCE_IMPLEMENTATION_AUTHORIZED" not in status_line
        or "DELIVERY_NOT_AUTHORIZED" not in status_line
        or "MACHINE_BINDING_PENDING" in status_line
        or "INTEGRATED_DRAFT" in status_line
    ):
        result.error(
            check_id,
            "FAIL_FULL_DESIGN_STATUS",
            "the explicit status line must declare IMPLEMENTATION_READY / SOURCE_IMPLEMENTATION_AUTHORIZED / DELIVERY_NOT_AUTHORIZED",
            relative,
        )
    required_terms = (
        "SourcePartition",
        "OperationKey",
        "CanonicalTimelineWriter",
        "ReplicaApplyCoordinator",
        "OUTCOME_UNKNOWN",
        "FT/2",
        "FT/3",
    )
    missing_terms = [term for term in required_terms if term not in content]
    if missing_terms:
        result.error(
            check_id,
            "FAIL_FULL_DESIGN_TERMS",
            f"FULL-DESIGN-SYNTHESIS.md lacks frozen terms: {', '.join(missing_terms)}",
            relative,
        )
    positive_archive_gate = []
    for line_number, line in enumerate(content.splitlines(), 1):
        if not re.search(
            r"(?i)(?:审核压缩包|audit\s+(?:zip|tar|archive|package)|review\s+(?:zip|tar|archive|package))",
            line,
        ):
            continue
        if re.search(
            r"(?i)(?:不生成|不要求|禁止|不得|无需|no\b|not\b|never\b|without\b|forbid|supersed|historical|evidence)",
            line,
        ):
            continue
        positive_archive_gate.append(line_number)
    if positive_archive_gate:
        result.error(
            check_id,
            "FAIL_FORBIDDEN_ARCHIVE_GATE",
            "the implementation-ready design may not require an audit/review archive delivery gate"
            + f"; positive gate lines: {positive_archive_gate}",
            relative,
        )
    return {
        "bytes": len(content.encode("utf-8")),
        "required_terms": len(required_terms),
    }


def resolve_json_pointer(document: Any, fragment: str) -> bool:
    found, _ = resolve_json_pointer_value(document, fragment)
    return found


def resolve_json_pointer_value(document: Any, fragment: str) -> tuple[bool, Any]:
    if fragment in ("", "#"):
        return True, document
    pointer = fragment[1:] if fragment.startswith("#") else fragment
    if not pointer.startswith("/"):
        return False, None
    current = document
    for raw in pointer[1:].split("/"):
        token = urllib.parse.unquote(raw).replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict) and token in current:
            current = current[token]
        elif isinstance(current, list) and token.isdigit() and int(token) < len(current):
            current = current[int(token)]
        else:
            return False, None
    return True, current


def validate_schema_node(
    node: Any,
    path: Path,
    schema_root: Path,
    documents: Mapping[Path, Any],
    location: str,
    errors: list[str],
) -> None:
    if isinstance(node, bool):
        return
    if not isinstance(node, dict):
        errors.append(f"{location}: schema node must be object or boolean")
        return

    type_value = node.get("type")
    if type_value is not None:
        types = [type_value] if isinstance(type_value, str) else type_value
        if (
            not isinstance(types, list)
            or not types
            or any(not isinstance(value, str) or value not in JSON_SCHEMA_TYPES for value in types)
            or len(types) != len(set(types))
        ):
            errors.append(f"{location}/type: invalid JSON Schema type")

    properties = node.get("properties")
    if properties is not None and not isinstance(properties, dict):
        errors.append(f"{location}/properties: must be an object")
    elif isinstance(properties, dict):
        for key, child in properties.items():
            validate_schema_node(
                child, path, schema_root, documents, f"{location}/properties/{key}", errors
            )

    required = node.get("required")
    if required is not None:
        if (
            not isinstance(required, list)
            or any(not isinstance(value, str) or not value for value in required)
            or len(required) != len(set(required))
        ):
            errors.append(f"{location}/required: must be unique nonblank strings")

    for keyword in ("additionalProperties", "unevaluatedProperties", "items", "contains", "not"):
        if keyword in node:
            child = node[keyword]
            if not isinstance(child, (dict, bool)):
                errors.append(f"{location}/{keyword}: must be schema object or boolean")
            else:
                validate_schema_node(
                    child, path, schema_root, documents, f"{location}/{keyword}", errors
                )

    for keyword in ("$defs", "definitions", "patternProperties", "dependentSchemas"):
        if keyword in node:
            children = node[keyword]
            if not isinstance(children, dict):
                errors.append(f"{location}/{keyword}: must be an object")
            else:
                for key, child in children.items():
                    validate_schema_node(
                        child,
                        path,
                        schema_root,
                        documents,
                        f"{location}/{keyword}/{key}",
                        errors,
                    )

    for keyword in ("allOf", "anyOf", "oneOf", "prefixItems"):
        if keyword in node:
            children = node[keyword]
            if not isinstance(children, list) or not children:
                errors.append(f"{location}/{keyword}: must be a nonempty array")
            else:
                for index, child in enumerate(children):
                    validate_schema_node(
                        child,
                        path,
                        schema_root,
                        documents,
                        f"{location}/{keyword}/{index}",
                        errors,
                    )

    if "enum" in node:
        enum = node["enum"]
        if not isinstance(enum, list) or not enum:
            errors.append(f"{location}/enum: must be a nonempty array")
        elif len({stable_json(value) for value in enum}) != len(enum):
            errors.append(f"{location}/enum: values must be unique")

    integer_bounds = (
        "minLength",
        "maxLength",
        "minItems",
        "maxItems",
        "minProperties",
        "maxProperties",
    )
    for keyword in integer_bounds:
        if keyword in node:
            value = node[keyword]
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                errors.append(f"{location}/{keyword}: must be a nonnegative integer")
    for keyword in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"):
        if keyword in node:
            value = node[keyword]
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                errors.append(f"{location}/{keyword}: must be a number")
            elif keyword == "multipleOf" and value <= 0:
                errors.append(f"{location}/multipleOf: must be greater than zero")
    for minimum, maximum in (
        ("minLength", "maxLength"),
        ("minItems", "maxItems"),
        ("minProperties", "maxProperties"),
        ("minimum", "maximum"),
        ("exclusiveMinimum", "exclusiveMaximum"),
    ):
        if minimum in node and maximum in node:
            low, high = node[minimum], node[maximum]
            if (
                isinstance(low, (int, float))
                and not isinstance(low, bool)
                and isinstance(high, (int, float))
                and not isinstance(high, bool)
                and low > high
            ):
                errors.append(f"{location}: {minimum} exceeds {maximum}")
    if "pattern" in node:
        if not isinstance(node["pattern"], str):
            errors.append(f"{location}/pattern: must be a string")
        else:
            try:
                re.compile(node["pattern"])
            except re.error as exc:
                errors.append(f"{location}/pattern: invalid regex: {exc}")

    reference = node.get("$ref")
    if reference is not None:
        if not isinstance(reference, str) or not reference:
            errors.append(f"{location}/$ref: must be a nonblank string")
        elif reference.startswith(("http://", "https://")):
            errors.append(f"{location}/$ref: network references are forbidden")
        else:
            file_part, separator, fragment = reference.partition("#")
            target_path = path if not file_part else (path.parent / file_part).resolve(strict=False)
            if not is_within(target_path, schema_root):
                errors.append(f"{location}/$ref: reference escapes schema directory")
            elif target_path not in documents:
                errors.append(f"{location}/$ref: target schema does not exist")
            elif separator and not resolve_json_pointer(documents[target_path], f"#{fragment}"):
                errors.append(f"{location}/$ref: JSON pointer does not resolve")


def check_json_schemas(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    schema_root = (result.design_root / "contracts/schema").resolve(strict=False)
    paths = sorted(
        path.resolve()
        for path in schema_root.glob("*.schema.json")
        if path.is_file() and not path.is_symlink()
    )
    actual_schema_files = {
        path.relative_to(result.design_root).as_posix() for path in paths
    }
    missing_schema_files = sorted(FIXED_SCHEMA_FILES - actual_schema_files)
    if missing_schema_files:
        result.error(
            check_id,
            "FAIL_JSON_SCHEMA_INVENTORY",
            "required named schemas are missing: " + ", ".join(missing_schema_files),
            "contracts/schema",
        )
    documents: dict[Path, Any] = {}
    for path in paths:
        relative = path.relative_to(result.design_root).as_posix()
        try:
            documents[path] = parse_json_file(path)
        except (
            OSError,
            UnicodeError,
            json.JSONDecodeError,
            StrictJsonError,
        ) as exc:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_PARSE",
                f"schema cannot be parsed: {exc}",
                relative,
            )
    for path, document in sorted(documents.items(), key=lambda pair: str(pair[0])):
        relative = path.relative_to(result.design_root).as_posix()
        if not isinstance(document, dict):
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "schema root must be an object",
                relative,
            )
            continue
        if not isinstance(document.get("$schema"), str) or not document["$schema"]:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "$schema must be a nonblank string",
                relative,
            )
        if not isinstance(document.get("$id"), str) or not document["$id"]:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "$id must be a nonblank string",
                relative,
            )
        if not any(key in document for key in ("type", "oneOf", "anyOf", "allOf", "$ref", "$defs")):
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "schema needs type/oneOf/anyOf/allOf/$ref/$defs",
                relative,
            )
        structural_errors: list[str] = []
        validate_schema_node(
            document, path, schema_root, documents, "#", structural_errors
        )
        for message in structural_errors:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                message,
                relative,
            )

        marker_errors: set[str] = set()

        def walk_schema_markers(node: Any, location: str) -> None:
            if isinstance(node, dict):
                for key, value in node.items():
                    child = f"{location}/{key}"
                    if LEGACY_MARKER_RE.search(key):
                        marker_errors.add(f"{child}: legacy/provider marker in schema key")
                    if "CANDIDATE_BINDING" in key:
                        marker_errors.add(f"{child}: CANDIDATE_BINDING in schema key")
                    lowered_key = key.lower()
                    if lowered_key in {
                        "source_device_id",
                        "claimantid",
                        "deviceid",
                        "faceidpassed",
                        "authenticated",
                    } and "/not/" not in f"{child}/".lower():
                        marker_errors.add(f"{child}: authoritative actor alias in schema")
                    walk_schema_markers(value, child)
            elif isinstance(node, list):
                for index, value in enumerate(node):
                    walk_schema_markers(value, f"{location}/{index}")
            elif isinstance(node, str):
                if LEGACY_MARKER_RE.search(node):
                    marker_errors.add(f"{location}: legacy/provider marker in schema value")
                if "CANDIDATE_BINDING" in node:
                    marker_errors.add(f"{location}: CANDIDATE_BINDING in schema value")
                if any(alias in node for alias in FORBIDDEN_WRITER_ALIASES):
                    marker_errors.add(f"{location}: writer alias in schema value")
                if (
                    any(alias.lower() in node.lower() for alias in FORBIDDEN_ACTOR_ALIASES)
                    and "/not/" not in f"{location}/".lower()
                ):
                    marker_errors.add(f"{location}: authoritative actor alias in schema value")

        walk_schema_markers(document, "#")
        for message in sorted(marker_errors):
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_FORBIDDEN_MARKER",
                message,
                relative,
            )

        def walk_wire_actor_refs(node: Any, location: str) -> None:
            if isinstance(node, dict):
                reference = node.get("$ref")
                if (
                    relative != "contracts/schema/domain.schema.json"
                    and isinstance(reference, str)
                    and reference.partition("#")[2] == "/$defs/AuthenticatedActor"
                ):
                    result.error(
                        check_id,
                        "FAIL_WIRE_INTERNAL_ACTOR_REFERENCE",
                        f"wire schema references internal AuthenticatedActor at {location}",
                        relative,
                    )
                for key, value in node.items():
                    walk_wire_actor_refs(value, f"{location}/{key}")
            elif isinstance(node, list):
                for index, value in enumerate(node):
                    walk_wire_actor_refs(value, f"{location}/{index}")

        walk_wire_actor_refs(document, "#")
    return {"schemas": len(paths)}


def ensure_safe_sql(sql: str) -> str | None:
    match = SQL_FILE_IO_RE.search(sql)
    return match.group(0) if match else None


def sql_authorizer(
    read_only: bool = False,
    allowed_pragmas: frozenset[str] = frozenset(),
) -> Callable[[int, str | None, str | None, str | None, str | None], int]:
    always_denied = {
        value for name in (
            "SQLITE_ATTACH", "SQLITE_DETACH", "SQLITE_CREATE_VTABLE",
            "SQLITE_DROP_VTABLE", "SQLITE_PRAGMA",
        )
        if isinstance((value := getattr(sqlite3, name, None)), int)
    }
    read_only_denied = {
        value for name in (
            "SQLITE_INSERT", "SQLITE_UPDATE", "SQLITE_DELETE", "SQLITE_ALTER_TABLE",
            "SQLITE_CREATE_INDEX", "SQLITE_CREATE_TABLE", "SQLITE_CREATE_TEMP_INDEX",
            "SQLITE_CREATE_TEMP_TABLE", "SQLITE_CREATE_TEMP_TRIGGER",
            "SQLITE_CREATE_TEMP_VIEW", "SQLITE_CREATE_TRIGGER", "SQLITE_CREATE_VIEW",
            "SQLITE_DROP_INDEX", "SQLITE_DROP_TABLE", "SQLITE_DROP_TEMP_INDEX",
            "SQLITE_DROP_TEMP_TABLE", "SQLITE_DROP_TEMP_TRIGGER", "SQLITE_DROP_TEMP_VIEW",
            "SQLITE_DROP_TRIGGER", "SQLITE_DROP_VIEW", "SQLITE_PRAGMA", "SQLITE_REINDEX",
            "SQLITE_TRANSACTION", "SQLITE_SAVEPOINT",
        )
        if isinstance((value := getattr(sqlite3, name, None)), int)
    }
    dangerous_functions = {"load_extension", "readfile", "writefile", "edit"}
    pragma_action = getattr(sqlite3, "SQLITE_PRAGMA", -1)

    def authorize(
        action: int,
        arg1: str | None,
        arg2: str | None,
        database: str | None,
        trigger: str | None,
    ) -> int:
        del database, trigger
        if action == pragma_action:
            return (
                sqlite3.SQLITE_OK
                if (arg1 or "").lower() in allowed_pragmas
                else sqlite3.SQLITE_DENY
            )
        if action in always_denied or (read_only and action in read_only_denied):
            return sqlite3.SQLITE_DENY
        if action == getattr(sqlite3, "SQLITE_FUNCTION", -1):
            function_name = (arg2 or arg1 or "").lower()
            if function_name in dangerous_functions:
                return sqlite3.SQLITE_DENY
        return sqlite3.SQLITE_OK

    return authorize


SQLITE_INTROSPECTION_PRAGMAS = frozenset({
    "foreign_key_check",
    "foreign_key_list",
    "index_info",
    "quick_check",
    "table_info",
})


def sqlite_introspection(
    connection: sqlite3.Connection,
    name: str,
    argument: str | None = None,
) -> list[tuple[Any, ...]]:
    """Run one validator-owned, read-only PRAGMA under a narrow authorizer."""
    if name not in SQLITE_INTROSPECTION_PRAGMAS:
        raise ValueError(f"unregistered SQLite introspection PRAGMA: {name}")
    suffix = ""
    if argument is not None:
        suffix = '("' + argument.replace('"', '""') + '")'
    connection.set_authorizer(
        sql_authorizer(allowed_pragmas=frozenset({name}))
    )
    try:
        return connection.execute(f"PRAGMA {name}{suffix}").fetchall()
    finally:
        connection.set_authorizer(sql_authorizer())


def evaluate_schema_instance(
    instance: Any,
    schema: Any,
    schema_path: Path,
    schema_root: Path,
    documents: Mapping[Path, Any],
    location: str = "$",
) -> list[str]:
    if schema is True:
        return []
    if schema is False or not isinstance(schema, dict):
        return [f"{location}: rejected by schema"]
    errors: list[str] = []
    reference = schema.get("$ref")
    if isinstance(reference, str):
        file_part, _, fragment = reference.partition("#")
        target_path = schema_path if not file_part else (schema_path.parent / file_part).resolve(strict=False)
        target_document = documents.get(target_path)
        found, target_schema = resolve_json_pointer_value(target_document, f"#{fragment}")
        if not found:
            return [f"{location}: unresolved $ref"]
        errors.extend(evaluate_schema_instance(instance, target_schema, target_path, schema_root, documents, location))

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{location}: const mismatch")
    if isinstance(schema.get("enum"), list) and instance not in schema["enum"]:
        errors.append(f"{location}: enum mismatch")

    type_value = schema.get("type")
    expected_types = [type_value] if isinstance(type_value, str) else type_value
    if isinstance(expected_types, list):
        def matches_type(expected: str) -> bool:
            return {
                "null": instance is None,
                "boolean": isinstance(instance, bool),
                "object": isinstance(instance, dict),
                "array": isinstance(instance, list),
                "number": isinstance(instance, (int, float)) and not isinstance(instance, bool),
                "integer": isinstance(instance, int) and not isinstance(instance, bool),
                "string": isinstance(instance, str),
            }.get(expected, False)
        if not any(matches_type(expected) for expected in expected_types):
            return [*errors, f"{location}: type mismatch"]

    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        if isinstance(required, list):
            for key in required:
                if key not in instance:
                    errors.append(f"{location}: missing {key}")
        if isinstance(properties, dict):
            for key, value in instance.items():
                if key in properties:
                    errors.extend(evaluate_schema_instance(value, properties[key], schema_path, schema_root, documents, f"{location}/{key}"))
                elif schema.get("additionalProperties") is False:
                    errors.append(f"{location}: additional property {key}")
                elif isinstance(schema.get("additionalProperties"), dict):
                    errors.extend(evaluate_schema_instance(value, schema["additionalProperties"], schema_path, schema_root, documents, f"{location}/{key}"))
        for keyword, comparator in (("minProperties", lambda a, b: a < b), ("maxProperties", lambda a, b: a > b)):
            bound = schema.get(keyword)
            if isinstance(bound, int) and comparator(len(instance), bound):
                errors.append(f"{location}: {keyword}")
        property_names = schema.get("propertyNames")
        if isinstance(property_names, (dict, bool)):
            for key in instance:
                errors.extend(
                    evaluate_schema_instance(
                        key, property_names, schema_path, schema_root, documents,
                        f"{location}/<propertyName>",
                    )
                )

    if isinstance(instance, list):
        items = schema.get("items")
        if isinstance(items, (dict, bool)):
            for index, value in enumerate(instance):
                errors.extend(evaluate_schema_instance(value, items, schema_path, schema_root, documents, f"{location}/{index}"))
        if schema.get("uniqueItems") is True and len({stable_json(value) for value in instance}) != len(instance):
            errors.append(f"{location}: duplicate array items")
        for keyword, comparator in (("minItems", lambda a, b: a < b), ("maxItems", lambda a, b: a > b)):
            bound = schema.get(keyword)
            if isinstance(bound, int) and comparator(len(instance), bound):
                errors.append(f"{location}: {keyword}")

    if isinstance(instance, str):
        for keyword, comparator in (("minLength", lambda a, b: a < b), ("maxLength", lambda a, b: a > b)):
            bound = schema.get(keyword)
            if isinstance(bound, int) and comparator(len(instance), bound):
                errors.append(f"{location}: {keyword}")
        byte_bound = schema.get("x-utf8MaxBytes")
        if isinstance(byte_bound, int) and len(instance.encode("utf-8")) > byte_bound:
            errors.append(f"{location}: x-utf8MaxBytes")
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and re.search(pattern, instance) is None:
            errors.append(f"{location}: pattern")
        format_name = schema.get("format")
        if format_name == "uint64-decimal" and (
            not re.fullmatch(r"0|[1-9][0-9]{0,19}", instance)
            or int(instance) > 18446744073709551615
        ):
            errors.append(f"{location}: format uint64-decimal")
        elif format_name == "date-time":
            if not re.fullmatch(
                r"[0-9]{4}-[0-9]{2}-[0-9]{2}T"
                r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?"
                r"(?:Z|[+-][0-9]{2}:[0-9]{2})",
                instance,
            ):
                errors.append(f"{location}: format date-time")
            else:
                try:
                    datetime.datetime.fromisoformat(instance.replace("Z", "+00:00"))
                except ValueError:
                    errors.append(f"{location}: format date-time")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        for keyword, comparator in (
            ("minimum", lambda a, b: a < b), ("maximum", lambda a, b: a > b),
            ("exclusiveMinimum", lambda a, b: a <= b), ("exclusiveMaximum", lambda a, b: a >= b),
        ):
            bound = schema.get(keyword)
            if isinstance(bound, (int, float)) and not isinstance(bound, bool) and comparator(instance, bound):
                errors.append(f"{location}: {keyword}")
        multiple_of = schema.get("multipleOf")
        if (
            isinstance(multiple_of, (int, float))
            and not isinstance(multiple_of, bool)
            and multiple_of > 0
            and instance % multiple_of != 0
        ):
            errors.append(f"{location}: multipleOf")
        if schema.get("format") in {"json-safe-uint", "json-safe-integer"}:
            if not isinstance(instance, int) or abs(instance) > 9007199254740991:
                errors.append(f"{location}: format {schema['format']}")
            elif schema["format"] == "json-safe-uint" and instance < 0:
                errors.append(f"{location}: format json-safe-uint")

    serialized_bound = schema.get("x-serializedUtf8MaxBytes")
    if isinstance(serialized_bound, int) and len(
        json.dumps(instance, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ) > serialized_bound:
        errors.append(f"{location}: x-serializedUtf8MaxBytes")

    max_depth = schema.get("x-maxDepth")
    if isinstance(max_depth, int):
        def instance_depth(value: Any) -> int:
            if isinstance(value, dict):
                return 1 + max((instance_depth(item) for item in value.values()), default=0)
            if isinstance(value, list):
                return 1 + max((instance_depth(item) for item in value), default=0)
            return 0
        if instance_depth(instance) > max_depth:
            errors.append(f"{location}: x-maxDepth")

    for keyword in ("allOf", "anyOf", "oneOf"):
        branches = schema.get(keyword)
        if not isinstance(branches, list):
            continue
        results = [evaluate_schema_instance(instance, branch, schema_path, schema_root, documents, location) for branch in branches]
        successes = sum(not branch_errors for branch_errors in results)
        if keyword == "allOf":
            for branch_errors in results:
                errors.extend(branch_errors)
        elif keyword == "anyOf" and successes == 0:
            errors.append(f"{location}: anyOf")
        elif keyword == "oneOf" and successes != 1:
            errors.append(f"{location}: oneOf")
    if "not" in schema and not evaluate_schema_instance(instance, schema["not"], schema_path, schema_root, documents, location):
        errors.append(f"{location}: not")
    condition = schema.get("if")
    if isinstance(condition, (dict, bool)):
        branch = schema.get("then") if not evaluate_schema_instance(instance, condition, schema_path, schema_root, documents, location) else schema.get("else")
        if isinstance(branch, (dict, bool)):
            errors.extend(evaluate_schema_instance(instance, branch, schema_path, schema_root, documents, location))
    return errors


def canonicalize_fingerprint_value(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        if abs(value) > 9007199254740991:
            raise ValueError("JSON integer is outside the safe fingerprint domain")
        return str(value)
    if isinstance(value, float):
        raise ValueError("non-integer JSON numbers are forbidden in fingerprints")
    if isinstance(value, str):
        value.encode("utf-8", "strict")
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(canonicalize_fingerprint_value(item) for item in value) + "]"
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise ValueError("fingerprint object keys must be strings")
        for key in value:
            key.encode("utf-8", "strict")
        ordered_keys = sorted(
            value,
            key=lambda key: key.encode("utf-16-be", "surrogatepass"),
        )
        return "{" + ",".join(
            canonicalize_fingerprint_value(key)
            + ":"
            + canonicalize_fingerprint_value(value[key])
            for key in ordered_keys
        ) + "}"
    raise ValueError(f"unsupported fingerprint value: {type(value).__name__}")


def evaluate_executable_rule(
    rule_id: str,
    instance: Any,
    context: Mapping[str, Any],
    registry: Mapping[str, Any],
) -> list[str]:
    """Independently execute one frozen semantic rule and return reason codes."""
    if not isinstance(instance, dict):
        return ["RULE_INSTANCE_TYPE"]

    def digest(value: Any) -> str:
        canonical = canonicalize_fingerprint_value(value).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()

    def source_key(value: Any) -> tuple[Any, Any, Any]:
        if not isinstance(value, dict):
            return (None, None, None)
        return tuple(value.get(key) for key in CANONICAL_SOURCE_PARTITION)

    def nested_source_keys(value: Any) -> list[tuple[Any, Any, Any]]:
        found: list[tuple[Any, Any, Any]] = []
        if isinstance(value, dict):
            if set(CANONICAL_SOURCE_PARTITION).issubset(value):
                found.append(source_key(value))
            for child in value.values():
                found.extend(nested_source_keys(child))
        elif isinstance(value, list):
            for child in value:
                found.extend(nested_source_keys(child))
        return found

    def failure_if(condition: bool, reason: str) -> list[str]:
        return [reason] if condition else []

    try:
        if rule_id == "MAT_BEGIN_SUBJECT_EQUALITY":
            subject = instance["block"]["subject"]
            body = instance["body"]
            locator = (
                "catalogScopeId" if subject["domain"] == "CATALOG"
                else "threadRef"
            )
            return failure_if(
                subject["domain"] != body["domain"]
                or subject[locator] != body[locator],
                "MATERIALIZATION_SUBJECT_MISMATCH",
            )
        if rule_id == "MAT_BEGIN_HEAD_SUCCESSOR":
            return failure_if(
                instance["candidateHeadVersion"]
                != instance["baseHeadVersion"] + 1,
                "HEAD_VERSION_NOT_SUCCESSOR",
            )
        if rule_id == "MAT_BEGIN_EMPTY_PROOF":
            empty = instance["pageCount"] == 0
            mismatch = (
                empty != (instance["declaredCompleteness"] == "EMPTY_PROVEN")
                or empty != ("emptyProof" in instance)
                or (
                    empty
                    and instance["emptyProof"]["domain"]
                    != instance["body"]["domain"]
                )
            )
            return failure_if(mismatch, "EMPTY_PROOF_MISMATCH")
        if rule_id == "MAT_BLOCK_MANIFEST_EQUALITY":
            return failure_if(
                instance["expectedManifestDigest"]
                != instance["block"]["manifestDigest"],
                "MANIFEST_DIGEST_MISMATCH",
            )
        if rule_id == "MAT_PAGE_INDEX_RANGE":
            return failure_if(
                instance["pageIndex"] >= instance["pageCount"],
                "PAGE_INDEX_OUT_OF_RANGE",
            )
        if rule_id == "MAT_PAGE_SUBJECT_EQUALITY":
            subject = instance["block"]["subject"]
            body = instance["pageBody"]
            locator = (
                "catalogScopeId" if subject["domain"] == "CATALOG"
                else "threadRef"
            )
            return failure_if(
                subject["materializationId"] != body["materializationId"]
                or subject[locator] != body[locator],
                "MATERIALIZATION_SUBJECT_MISMATCH",
            )
        if rule_id == "MAT_PAGE_DIGEST":
            return failure_if(
                instance["pageDigest"] != digest(instance["pageBody"]),
                "PAGE_DIGEST_MISMATCH",
            )
        if rule_id == "MAT_COMMIT_PAGE_COUNT":
            return failure_if(
                len(instance["orderedPageDigests"]) != instance["pageCount"],
                "PAGE_COUNT_MISMATCH",
            )
        if rule_id == "MAT_COMMIT_EMPTY_RECEIPT":
            receipt = instance["receipt"]
            return failure_if(
                instance["pageCount"] == 0
                and (
                    receipt["result"] != "VERIFIED"
                    or receipt["pageCount"] != 0
                ),
                "EMPTY_RECEIPT_UNVERIFIED",
            )
        if rule_id == "MAT_COMMIT_RECEIPT_EQUALITY":
            block = instance["block"]
            receipt = instance["receipt"]
            locator = (
                "catalogScopeId"
                if block["subject"]["domain"] == "CATALOG"
                else "threadRef"
            )
            return failure_if(
                block["receiptId"] != receipt["receiptId"]
                or block["manifestDigest"] != receipt["manifestDigest"]
                or block["subject"]["materializationId"]
                != receipt["materializationId"]
                or block["subject"][locator] != receipt[locator],
                "RECEIPT_IDENTITY_MISMATCH",
            )
        if rule_id == "DURABLE_SOURCE_EQUALITY":
            expected = source_key(instance["eventKey"]["sourcePartition"])
            return failure_if(
                source_key(instance["messageKey"]["sourcePartition"])
                != expected
                or any(
                    key != expected
                    for key in nested_source_keys(instance["payload"])
                ),
                "SOURCE_MISMATCH",
            )
        if rule_id == "DURABLE_SEQUENCE_ALGEBRA":
            return failure_if(
                instance["baseSeq"] != instance["streamSeq"] - 1
                or instance["commitSeq"] < instance["streamSeq"],
                "STREAM_SEQUENCE_INVALID",
            )
        if rule_id == "DURABLE_KIND_PAYLOAD":
            payload_kind = instance["payload"].get("payloadKind")
            return failure_if(
                payload_kind is not None and payload_kind != instance["kind"],
                "MESSAGE_KIND_PAYLOAD_MISMATCH",
            )
        if rule_id == "DURABLE_ROUTE_STREAM":
            message = next(
                (
                    row for row in registry.get("messages", ())
                    if isinstance(row, dict) and row.get("kind") == instance["kind"]
                ),
                None,
            )
            route = (
                instance["projection"]["projectionKind"]
                + "/"
                + instance["projection"]["audience"]
            )
            return failure_if(
                not isinstance(message, dict)
                or message.get("streamName") != instance["streamName"]
                or route not in message.get("allowedProjectionRoutes", ()),
                "PROJECTION_ROUTE_FORBIDDEN",
            )
        if rule_id == "DURABLE_PAYLOAD_DIGEST":
            return failure_if(
                instance["payloadDigest"] != digest(instance["payload"]),
                "PAYLOAD_DIGEST_MISMATCH",
            )
        if rule_id == "DURABLE_MESSAGE_DIGEST":
            preimage = {
                key: value for key, value in instance.items()
                if key != "messageDigest"
            }
            return failure_if(
                instance["messageDigest"] != digest(preimage),
                "MESSAGE_DIGEST_MISMATCH",
            )
        if rule_id == "DURABLE_EVENT_MESSAGE_KEY_IMMUTABILITY":
            prior = context.get("priorEnvelope")
            if not isinstance(prior, dict):
                return []
            if (
                prior.get("eventKey") == instance.get("eventKey")
                and prior.get("eventFactDigest")
                != instance.get("eventFactDigest")
            ):
                return ["EVENT_KEY_FACT_CONFLICT"]
            if (
                prior.get("messageKey") == instance.get("messageKey")
                and canonicalize_fingerprint_value(prior)
                != canonicalize_fingerprint_value(instance)
            ):
                return ["MESSAGE_KEY_BYTES_CONFLICT"]
            return []
        if rule_id == "DURABLE_MESSAGE_PREIMAGE":
            envelope = context.get("envelope")
            expected = context.get("expectedPreimage")
            if not isinstance(envelope, dict) or not isinstance(expected, dict):
                return ["RULE_CONTEXT_MISSING"]
            actual = {
                key: value for key, value in envelope.items()
                if key != "messageDigest"
            }
            return failure_if(
                actual != expected or instance != actual,
                "MESSAGE_PREIMAGE_MISMATCH",
            )
        if rule_id in {
            "BOUND_ORDER_PROOF_DIGEST", "CATALOG_PAGE_DIGEST",
            "TIMELINE_PAGE_DIGEST",
        }:
            preimage = (
                instance.get("proof")
                if rule_id == "BOUND_ORDER_PROOF_DIGEST"
                else instance
            )
            declared = (
                instance.get("proofDigest")
                if rule_id == "BOUND_ORDER_PROOF_DIGEST"
                else context.get("pageDigest")
            )
            if declared is None:
                return ["RULE_CONTEXT_MISSING"]
            return failure_if(
                declared != digest(preimage), "CANONICAL_DIGEST_MISMATCH"
            )
        if rule_id == "BOUND_ORDER_PROOF_CHAIN":
            ordinal = instance.get("nodeOrdinal", context.get("nodeOrdinal"))
            if not isinstance(ordinal, int) or isinstance(ordinal, bool):
                return ["RULE_CONTEXT_MISSING"]
            return failure_if(
                (ordinal == 0) != ("fromNodeId" not in instance),
                "ORDER_PREDECESSOR_INVALID",
            )
        if rule_id == "BOUND_ORDER_PROOF_EVIDENCE":
            keys = (
                "sourcePageIndex", "readEvidenceId",
                "codexCertificationId",
            )
            if not any(key in context for key in keys):
                return ["RULE_CONTEXT_MISSING"]
            return failure_if(
                any(
                    key in context and instance.get(key) != context[key]
                    for key in keys
                ),
                "ORDER_EVIDENCE_MISMATCH",
            )
        if rule_id in {"CATALOG_PAGE_CHAIN", "TIMELINE_PAGE_CHAIN"}:
            first = instance["pageIndex"] == 0
            mismatch = first != ("previousPageDigest" not in instance)
            if not first and not mismatch:
                if "previousPageDigest" not in context:
                    return ["RULE_CONTEXT_MISSING"]
                mismatch = mismatch or (
                    instance.get("previousPageDigest")
                    != context["previousPageDigest"]
                )
            return failure_if(mismatch, "PAGE_PREDECESSOR_INVALID")
        if rule_id == "MATERIALIZATION_RECEIPT_DIGEST":
            preimage = {
                key: value for key, value in instance.items()
                if key != "receiptDigest"
            }
            return failure_if(
                instance["receiptDigest"] != digest(preimage),
                "RECEIPT_DIGEST_MISMATCH",
            )
        if rule_id == "SETTINGS_VALUE_COMPLETENESS":
            completeness = context.get("completeness")
            if completeness not in {"COMPLETE", "SPARSE"}:
                return ["RULE_CONTEXT_MISSING"]
            unknown = any(
                value.get("state") == "UNKNOWN"
                for key, value in instance.items()
                if key != "extensions" and isinstance(value, dict)
            )
            return failure_if(
                (completeness == "COMPLETE") == unknown,
                "SETTINGS_COMPLETENESS_MISMATCH",
            )
        if rule_id == "SETTINGS_READBACK_COEXISTENCE":
            return failure_if(
                context.get("applyOutboundXorToSnapshot") is True,
                "SETTINGS_SNAPSHOT_XOR_FORBIDDEN",
            )
        if rule_id in {
            "SETTINGS_REVISION_SUCCESSOR", "GOAL_REVISION_SUCCESSOR"
        }:
            settings = rule_id.startswith("SETTINGS")
            revision_key = "settingsRevision" if settings else "goalRevision"
            previous_key = (
                "previousSettingsRevision" if settings else "previousGoalRevision"
            )
            revision = instance[revision_key]
            previous = instance.get(previous_key)
            return failure_if(
                (revision == 1) != (previous is None)
                or (revision > 1 and previous != revision - 1),
                "REVISION_NOT_SUCCESSOR",
            )
        if rule_id == "SETTINGS_PAYLOAD_COMPLETENESS":
            return evaluate_executable_rule(
                "SETTINGS_VALUE_COMPLETENESS", instance["value"],
                {"completeness": instance["completeness"]}, registry,
            )
        if rule_id == "GOAL_USAGE_MONOTONIC":
            if "priorUsageTokens" not in context:
                return ["RULE_CONTEXT_MISSING"]
            value = instance.get("value", {})
            usage = value.get("usage", {}) if isinstance(value, dict) else {}
            return failure_if(
                usage.get("kind") == "TOKEN_USAGE"
                and int(usage["tokens"]) < int(context["priorUsageTokens"]),
                "GOAL_USAGE_DECREASED",
            )
        if rule_id == "GOAL_REMAINING_FORBIDDEN":
            value = instance.get("value", {})
            return failure_if(
                "remaining" in instance
                or (isinstance(value, dict) and "remaining" in value)
                or context.get("attemptedField") == "remaining",
                "GOAL_REMAINING_FORBIDDEN",
            )
        if rule_id == "PROBLEM_REGISTRY_MATCH":
            problem = next(
                (
                    row
                    for row in registry.get("errorRegistry", {}).get(
                        "problems", ()
                    )
                    if isinstance(row, dict)
                    and row.get("code") == instance.get("problemCode")
                ),
                None,
            )
            return failure_if(
                not isinstance(problem, dict)
                or instance.get("errorClass") != problem.get("errorClass")
                or instance.get("retryDirective")
                != problem.get("retryDirective"),
                "PROBLEM_REGISTRY_MISMATCH",
            )
        if rule_id == "MATERIALIZATION_RECEIPT_PREIMAGE":
            receipt = context.get("receipt")
            if not isinstance(receipt, dict):
                return ["RULE_CONTEXT_MISSING"]
            expected = {
                key: value for key, value in receipt.items()
                if key != "receiptDigest"
            }
            return failure_if(
                instance != expected, "RECEIPT_PREIMAGE_MISMATCH"
            )
        if rule_id == "OPERATION_STATE_REGISTRY_PAIR":
            operation = next(
                (
                    row for row in registry.get("operations", ())
                    if isinstance(row, dict)
                    and row.get("id") == instance.get("operationRegistryId")
                    and row.get("exposure") == "PUBLIC"
                ),
                None,
            )
            return failure_if(
                not isinstance(operation, dict)
                or operation.get("name") != instance.get("operationKind"),
                "OPERATION_REGISTRY_PAIR_MISMATCH",
            )
        if rule_id == "OPERATION_STATE_ATTEMPT_PRESENCE":
            return failure_if(
                instance["lifecycle"] in {
                    "RECEIVED", "REJECTED_BEFORE_ADMISSION", "ADMITTED",
                    "QUEUED", "BLOCKED_PRECONDITION", "READY",
                }
                and "dispatchAttempt" in instance,
                "DISPATCH_ATTEMPT_NOT_CREATED",
            )
        if rule_id == "OPERATION_STATE_EFFECT_AXIS":
            return failure_if(
                (instance["lifecycle"] == "SUCCEEDED")
                != (instance["effectObservation"] == "OBSERVED_MATCH"),
                "OPERATION_EFFECT_AXIS_MISMATCH",
            )
        if rule_id == "RESTART_EXPECTED_TURN":
            required = (
                instance["restartPolicy"] == "INTERRUPT_EXACT_ACTIVE_TURN"
            )
            return failure_if(
                required != ("expectedProviderTurnId" in instance),
                "EXPECTED_PROVIDER_TURN_MISMATCH",
            )
        return ["UNKNOWN_EXECUTABLE_RULE"]
    except (KeyError, TypeError, ValueError, UnicodeError) as exc:
        return [f"RULE_EXECUTION_ERROR:{type(exc).__name__}"]


def content_ticket_semantic_errors(
    instance: Any, *, access_ticket: bool
) -> list[str]:
    """Evaluate cross-field ticket invariants JSON Schema cannot express."""
    if not isinstance(instance, dict):
        return ["$: content ticket must be an object"]
    errors: list[str] = []
    if access_ticket:
        try:
            issued_at = datetime.datetime.fromisoformat(
                str(instance["issuedAt"]).replace("Z", "+00:00")
            )
            expires_at = datetime.datetime.fromisoformat(
                str(instance["expiresAt"]).replace("Z", "+00:00")
            )
            ttl_seconds = (expires_at - issued_at).total_seconds()
        except (KeyError, TypeError, ValueError):
            errors.append("$: content ticket time interval")
        else:
            if not 0 < ttl_seconds <= 900:
                errors.append("$: content ticket TTL")

    for field in (
        "sourceEpoch", "connectionOrLeaseGeneration",
        "objectGeneration", "offerGeneration",
    ):
        if field in instance:
            try:
                if int(instance[field]) < 1:
                    errors.append(f"$: {field} must be one-based")
            except (TypeError, ValueError):
                errors.append(f"$: {field} must be an integer")
    try:
        if int(instance["maxBytes"]) <= 0:
            errors.append("$: maxBytes must be positive")
    except (KeyError, TypeError, ValueError):
        errors.append("$: maxBytes must be a canonical positive integer")

    has_start = "rangeStart" in instance
    has_end = "rangeEndInclusive" in instance
    if has_start != has_end:
        errors.append("$: content range pair")
        return errors
    if not has_start:
        return errors
    methods = instance.get("methods")
    if not isinstance(methods, list) or "GET" not in methods:
        errors.append("$: content range requires GET")
    try:
        start = int(instance["rangeStart"])
        end = int(instance["rangeEndInclusive"])
        maximum = int(instance["maxBytes"])
    except (KeyError, TypeError, ValueError):
        errors.append("$: content range integer fields")
        return errors
    if start > end:
        errors.append("$: content range reversed")
    elif end - start + 1 > maximum:
        errors.append("$: content range exceeds maxBytes")
    return errors


def check_contract_vectors(
    result: ValidationResult, check_id: str, final_config: Mapping[str, Any]
) -> Mapping[str, Any]:
    relative = str(final_config["vector_source"])
    try:
        document = parse_json_file(result.design_root / relative)
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError) as exc:
        result.error(check_id, "FAIL_CONTRACT_VECTOR_PARSE", f"contract vectors cannot be parsed: {exc}", relative)
        return {"vectors": 0}
    required_keys = {
        "schemaVectors", "fingerprintVectors", "serializationVectors",
        "numericVectors", "admissionVectors", "stateMachineVectors",
        "receiveVectors", "sqlVectors", "injectedFailureInventory",
        "jcsConformanceVectors", "actorProjectionVectors",
        "actorTicketBindingVectors", "featureContributionVectors",
        "wireFrameVectors", "hostResolutionVectors", "stateMachineEdgeVectors",
        "stateMachineSqlVectors", "crossFieldVectors", "durableEnvelopeVectors",
    }
    if not isinstance(document, dict) or not required_keys.issubset(document):
        result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", f"vector source is missing keys from {sorted(required_keys)}", relative)
        return {"vectors": 0}

    schema_root = (result.design_root / "contracts/schema").resolve()
    schema_documents: dict[Path, Any] = {}
    for path in schema_root.glob("*.schema.json"):
        try:
            schema_documents[path.resolve()] = parse_json_file(path)
        except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError):
            pass
    try:
        registry_document = parse_json_file(
            result.design_root / str(final_config["machine_source"])
        )
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError):
        registry_document = {}
    registry_machines = (
        registry_document.get("stateMachines", [])
        if isinstance(registry_document, dict)
        else []
    )
    vector_ids: list[str] = []
    schema_vectors = document["schemaVectors"]
    if not isinstance(schema_vectors, list) or not schema_vectors:
        result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "schemaVectors must be a nonempty array", relative)
        schema_vectors = []
    for index, vector in enumerate(schema_vectors):
        artifact = f"{relative}#schemaVectors/{index}"
        if not isinstance(vector, dict):
            result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "schema vector must be an object", artifact)
            continue
        vector_id = vector.get("id")
        reference = vector.get("schemaRef")
        valid = vector.get("valid")
        if not isinstance(vector_id, str) or not vector_id or not isinstance(reference, str) or not isinstance(valid, bool) or "instance" not in vector:
            result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "schema vector needs id/schemaRef/valid/instance", artifact)
            continue
        vector_ids.append(vector_id)
        if not valid and (not isinstance(vector.get("expectedReason"), str) or not vector["expectedReason"]):
            result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "invalid schema vector needs expectedReason", artifact)
        file_part, separator, fragment = reference.partition("#")
        target = (schema_root / file_part.removeprefix("schema/")).resolve(strict=False)
        if target not in schema_documents or (separator and not resolve_json_pointer(schema_documents[target], f"#{fragment}")):
            result.error(check_id, "FAIL_CONTRACT_VECTOR_SCHEMA_REF", f"unresolved schemaRef: {reference}", artifact)
            continue
        found, target_schema = resolve_json_pointer_value(
            schema_documents[target], f"#{fragment}" if separator else "#"
        )
        evaluation_errors = evaluate_schema_instance(
            vector["instance"], target_schema, target, schema_root,
            schema_documents,
        ) if found else ["unresolved schema"]
        if reference in {
            "schema/domain.schema.json#/$defs/ContentAccessTicket",
            "schema/domain.schema.json#/$defs/ContentTicketIssueRequest",
        }:
            evaluation_errors.extend(
                content_ticket_semantic_errors(
                    vector["instance"],
                    access_ticket=reference.endswith("/ContentAccessTicket"),
                )
            )
        if valid == bool(evaluation_errors):
            result.error(
                check_id,
                "FAIL_CONTRACT_VECTOR_EXPECTATION",
                f"{vector_id} declares valid={valid} but stdlib schema evaluation returned {evaluation_errors[:3]}",
                artifact,
            )

    executable_rules = (
        registry_document.get("executableRuleInventory", [])
        if isinstance(registry_document, dict)
        else []
    )
    rules_by_id = {
        rule.get("ruleId"): rule
        for rule in executable_rules
        if isinstance(rule, dict) and isinstance(rule.get("ruleId"), str)
    } if isinstance(executable_rules, list) else {}
    cross_field_vectors = document.get("crossFieldVectors")
    vectors_by_rule: dict[str, list[dict[str, Any]]] = {}
    if not isinstance(cross_field_vectors, list) or not cross_field_vectors:
        result.error(
            check_id,
            "FAIL_EXECUTABLE_RULE_VECTOR",
            "crossFieldVectors must be a nonempty executable vector array",
            relative,
        )
        cross_field_vectors = []
    for index, vector in enumerate(cross_field_vectors):
        artifact = f"{relative}#crossFieldVectors/{index}"
        allowed_fields = {
            "id", "ruleId", "schemaRef", "instance", "context", "valid",
            "expectedReason",
        }
        if (
            not isinstance(vector, dict)
            or not set(vector).issubset(allowed_fields)
            or not {
                "id", "ruleId", "schemaRef", "instance", "context", "valid"
            }.issubset(vector)
            or not isinstance(vector.get("id"), str)
            or not vector["id"]
            or not isinstance(vector.get("ruleId"), str)
            or vector["ruleId"] not in rules_by_id
            or not isinstance(vector.get("schemaRef"), str)
            or not isinstance(vector.get("context"), dict)
            or not isinstance(vector.get("valid"), bool)
            or (
                vector.get("valid") is False
                and (
                    not isinstance(vector.get("expectedReason"), str)
                    or not vector["expectedReason"]
                )
            )
        ):
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_VECTOR",
                "cross-field vector must close id/ruleId/schemaRef/instance/context/valid/expectedReason",
                artifact,
            )
            continue
        rule = rules_by_id[vector["ruleId"]]
        if vector["schemaRef"] not in rule.get("schemaRefs", ()):
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_VECTOR",
                "cross-field vector schemaRef is not registered for its rule",
                artifact,
            )
        file_part, separator, fragment = vector["schemaRef"].partition("#")
        target = (schema_root / file_part.removeprefix("schema/")).resolve(
            strict=False
        )
        found, target_schema = resolve_json_pointer_value(
            schema_documents.get(target), f"#{fragment}" if separator else "#"
        ) if target in schema_documents else (False, None)
        schema_errors = evaluate_schema_instance(
            vector["instance"], target_schema, target, schema_root,
            schema_documents,
        ) if found else ["unresolved cross-field schemaRef"]
        if schema_errors:
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_VECTOR",
                f"cross-field vector must isolate the rule on schema-valid input: {schema_errors[:3]}",
                artifact,
            )
        execution_errors = evaluate_executable_rule(
            vector["ruleId"], vector["instance"], vector["context"],
            registry_document if isinstance(registry_document, dict) else {},
        )
        if vector["valid"] == bool(execution_errors):
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_EXPECTATION",
                f"{vector['id']} valid={vector['valid']} but handler returned {execution_errors}",
                artifact,
            )
        elif (
            not vector["valid"]
            and vector.get("expectedReason") != execution_errors[0]
        ):
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_EXPECTATION",
                f"{vector['id']} expectedReason differs from exact handler reason {execution_errors[0]}",
                artifact,
            )
        vectors_by_rule.setdefault(vector["ruleId"], []).append(vector)
    for rule_id, rule in rules_by_id.items():
        rule_vectors = vectors_by_rule.get(rule_id, [])
        vector_ids_for_rule = [vector["id"] for vector in rule_vectors]
        if (
            vector_ids_for_rule != rule.get("vectorIds")
            or {vector.get("valid") for vector in rule_vectors} != {True, False}
        ):
            result.error(
                check_id,
                "FAIL_EXECUTABLE_RULE_VECTOR",
                f"{rule_id} must bind its exact registered vector IDs with positive and deliberate-negative outcomes",
                relative,
            )

    serialization_vectors = document.get("serializationVectors")
    expected_boundaries = {
        ("CONTROL_ENVELOPE", 65536): True,
        ("CONTROL_ENVELOPE", 65537): False,
        ("CONTROL_PAYLOAD", 57344): True,
        ("CONTROL_PAYLOAD", 57345): False,
        ("INTERACTION_ANSWER", 49152): True,
        ("INTERACTION_ANSWER", 49153): False,
    }
    observed_boundaries: dict[tuple[str, int], bool] = {}
    if isinstance(serialization_vectors, list):
        for index, vector in enumerate(serialization_vectors):
            if not isinstance(vector, dict) or vector.get("surface") not in {
                "CONTROL_ENVELOPE", "CONTROL_PAYLOAD", "INTERACTION_ANSWER"
            }:
                continue
            artifact = f"{relative}#serializationVectors/{index}"
            byte_length = vector.get("actualUtf8Bytes")
            limit = vector.get("limitBytes")
            valid = vector.get("valid")
            value = vector.get("value")
            if (
                not isinstance(byte_length, int)
                or isinstance(byte_length, bool)
                or not isinstance(limit, int)
                or isinstance(limit, bool)
                or not isinstance(valid, bool)
                or reconstructed_utf8_length(value) != byte_length
                or valid != (byte_length <= limit)
            ):
                result.error(
                    check_id,
                    "FAIL_PREDECODE_CAPACITY_VECTOR",
                    "capacity vector must bind actual UTF-8 bytes, exact limit, and outcome",
                    artifact,
                )
                continue
            observed_boundaries[(vector["surface"], byte_length)] = valid
            if not valid and (
                vector.get("rejectionPhase") != "PRE_DECODE"
                or set(vector.get("zeroEffects", ())) != FIXED_PREDECODE_ZERO_EFFECTS
            ):
                result.error(
                    check_id,
                    "FAIL_PREDECODE_CAPACITY_VECTOR",
                    "over-limit vector must reject PRE_DECODE with exact zero durable/execution effects",
                    artifact,
                )
    if observed_boundaries != expected_boundaries:
        result.error(
            check_id,
            "FAIL_PREDECODE_CAPACITY_VECTOR",
            "serializationVectors lack exact 65536/65537, 57344/57345, 49152/49153 byte pairs",
            relative,
        )

    wire_frame_vectors = document.get("wireFrameVectors")
    expected_wire_frames = (
        ("WIRE-ENVELOPE-65536-PASS", "ENVELOPE", 65536, True, "NONE"),
        ("WIRE-ENVELOPE-65537-REJECT", "ENVELOPE", 65537, False, "CONTROL_ENVELOPE_TOO_LARGE"),
        ("WIRE-PAYLOAD-57344-PASS", "PAYLOAD", 57344, True, "NONE"),
        ("WIRE-PAYLOAD-57345-REJECT", "PAYLOAD", 57345, False, "CONTROL_PAYLOAD_TOO_LARGE"),
        ("WIRE-INTERACTION-49152-PASS", "INTERACTION_ANSWER", 49152, True, "NONE"),
        ("WIRE-INTERACTION-49153-REJECT", "INTERACTION_ANSWER", 49153, False, "INTERACTION_ANSWER_TOO_LARGE"),
    )
    observed_wire_frames: list[tuple[Any, ...]] = []
    if isinstance(wire_frame_vectors, list):
        for index, vector in enumerate(wire_frame_vectors[:6]):
            artifact = f"{relative}#wireFrameVectors/{index}"
            if not isinstance(vector, dict):
                result.error(check_id, "FAIL_PREDECODE_WIRE_VECTOR", "wire frame vector must be an object", artifact)
                continue
            observed_wire_frames.append(
                (
                    vector.get("id"), vector.get("scope"),
                    vector.get("targetBytes"), vector.get("valid"),
                    vector.get("expectedReason"),
                )
            )
            if not vector.get("valid") and (
                vector.get("rejectionPhase") != "PRE_DECODE"
                or not isinstance(vector.get("expectedZeroEffects"), dict)
                or set(vector["expectedZeroEffects"]) != FIXED_PREDECODE_ZERO_EFFECTS
                or any(value != 0 for value in vector["expectedZeroEffects"].values())
            ):
                result.error(
                    check_id,
                    "FAIL_PREDECODE_WIRE_VECTOR",
                    "over-limit wire frame must fail PRE_DECODE with the exact all-zero effect oracle",
                    artifact,
                )
    if tuple(observed_wire_frames) != expected_wire_frames:
        result.error(
            check_id,
            "FAIL_PREDECODE_WIRE_VECTOR",
            "wireFrameVectors must preserve the exact ordered six byte-boundary outcomes",
            relative,
        )
    wire_frame_ids = [
        vector.get("id") for vector in wire_frame_vectors if isinstance(vector, dict)
    ] if isinstance(wire_frame_vectors, list) else []
    if wire_frame_ids != [
        *[value[0] for value in expected_wire_frames],
        "WIRE-MALFORMED-UTF8-REJECT",
        "WIRE-DUPLICATE-KEY-REJECT",
    ]:
        result.error(
            check_id,
            "FAIL_PREDECODE_WIRE_VECTOR",
            "wireFrameVectors must include only the six boundaries plus malformed-UTF8 and duplicate-key negatives",
            relative,
        )
    elif isinstance(wire_frame_vectors, list):
        for vector, expected_reason in zip(
            wire_frame_vectors[6:], ("MALFORMED_UTF8", "DUPLICATE_JSON_KEY")
        ):
            artifact = f"{relative}#wireFrameVectors/{wire_frame_ids.index(vector['id'])}"
            zero_effects = vector.get("expectedZeroEffects")
            if (
                vector.get("valid") is not False
                or vector.get("expectedReason") != expected_reason
                or vector.get("rejectionPhase") != "PRE_DECODE"
                or not isinstance(zero_effects, dict)
                or set(zero_effects) != FIXED_PREDECODE_ZERO_EFFECTS
                or any(value != 0 for value in zero_effects.values())
            ):
                result.error(check_id, "FAIL_PREDECODE_WIRE_VECTOR", "decoder negative lacks exact reason/phase/zero effects", artifact)
        try:
            bytes.fromhex(str(wire_frame_vectors[6]["rawHex"])).decode("utf-8", "strict")
        except (KeyError, ValueError, UnicodeDecodeError):
            pass
        else:
            result.error(check_id, "FAIL_PREDECODE_WIRE_VECTOR", "malformed UTF-8 negative decodes successfully", f"{relative}#wireFrameVectors/6")
        try:
            json.loads(
                str(wire_frame_vectors[7]["rawUtf8"]),
                object_pairs_hook=unique_json_object,
                parse_constant=reject_json_constant,
            )
        except (json.JSONDecodeError, StrictJsonError):
            pass
        else:
            result.error(check_id, "FAIL_PREDECODE_WIRE_VECTOR", "duplicate-key negative parses successfully", f"{relative}#wireFrameVectors/7")

    host_vectors = document.get("hostResolutionVectors")
    expected_host_ids = (
        "FEATURE-HOST-IOS-EXACT",
        "FEATURE-HOST-ANDROID-DOES-NOT-USE-IOS",
    )
    if not isinstance(host_vectors, list) or tuple(
        vector.get("id") for vector in host_vectors if isinstance(vector, dict)
    ) != expected_host_ids:
        result.error(
            check_id,
            "FAIL_FEATURE_HOST_RESOLUTION_VECTOR",
            "hostResolutionVectors must contain the exact resolved/mismatched-host pair",
            relative,
        )
        host_vectors = host_vectors if isinstance(host_vectors, list) else []
    for index, vector in enumerate(host_vectors):
        artifact = f"{relative}#hostResolutionVectors/{index}"
        candidates = vector.get("candidateHostKinds") if isinstance(vector, dict) else None
        current = vector.get("currentHostKind") if isinstance(vector, dict) else None
        independently_resolved = (
            isinstance(candidates, list)
            and current in candidates
            and all(candidate in FEATURE_HOST_KINDS for candidate in candidates)
        )
        if (
            not isinstance(vector, dict)
            or not isinstance(vector.get("resolved"), bool)
            or vector["resolved"] != independently_resolved
            or vector.get("support") != "UNKNOWN"
            or vector.get("availability") != "TEMPORARILY_UNAVAILABLE"
            or (
                not independently_resolved
                and vector.get("expectedReason")
                != "FEATURE_CURRENT_HOST_CONTRIBUTION_MISSING"
            )
        ):
            result.error(
                check_id,
                "FAIL_FEATURE_HOST_RESOLUTION_VECTOR",
                "host resolution must use the current upstream host exactly and fail closed without evidence",
                artifact,
            )

    durable_envelope_vectors = document.get("durableEnvelopeVectors")
    expected_durable_vector_ids = [
        vector_id
        for kind in FIXED_DURABLE_MESSAGE_ROUTES
        for vector_id in (
            f"POS-DURABLE-{kind}", f"NEG-DURABLE-{kind}-ROUTE"
        )
    ]
    durable_vector_ids = [
        vector.get("id") for vector in durable_envelope_vectors
        if isinstance(vector, dict)
    ] if isinstance(durable_envelope_vectors, list) else []
    if durable_vector_ids != expected_durable_vector_ids:
        result.error(
            check_id,
            "FAIL_DURABLE_ROUTE_VECTOR_INVENTORY",
            "durableEnvelopeVectors must contain the exact ordered positive/illegal-route pair for every durable kind",
            relative,
        )
        durable_envelope_vectors = (
            durable_envelope_vectors
            if isinstance(durable_envelope_vectors, list)
            else []
        )
    durable_rule_ids = (
        "DURABLE_SOURCE_EQUALITY", "DURABLE_SEQUENCE_ALGEBRA",
        "DURABLE_KIND_PAYLOAD", "DURABLE_ROUTE_STREAM",
        "DURABLE_PAYLOAD_DIGEST", "DURABLE_MESSAGE_DIGEST",
    )

    def has_recipient_payload_field(value: Any) -> bool:
        if isinstance(value, dict):
            return any(
                re.search(
                    r"(?i)(?:recipient|audience|originConnection|targetDevice)",
                    key,
                )
                or has_recipient_payload_field(child)
                for key, child in value.items()
            )
        if isinstance(value, list):
            return any(has_recipient_payload_field(child) for child in value)
        return False

    for index, vector in enumerate(durable_envelope_vectors):
        artifact = f"{relative}#durableEnvelopeVectors/{index}"
        if (
            not isinstance(vector, dict)
            or not isinstance(vector.get("instance"), dict)
            or vector.get("schemaRef")
            != "schema/durable-event.schema.json#/$defs/DurableEventEnvelopeV1"
            or not isinstance(vector.get("valid"), bool)
        ):
            result.error(
                check_id,
                "FAIL_DURABLE_ROUTE_VECTOR",
                "durable route vector has an invalid shape/schemaRef",
                artifact,
            )
            continue
        instance = vector["instance"]
        schema_target = (
            schema_root / "durable-event.schema.json"
        ).resolve(strict=False)
        found, durable_schema = resolve_json_pointer_value(
            schema_documents.get(schema_target),
            "#/$defs/DurableEventEnvelopeV1",
        ) if schema_target in schema_documents else (False, None)
        schema_errors = evaluate_schema_instance(
            instance, durable_schema, schema_target, schema_root,
            schema_documents,
        ) if found else ["unresolved DurableEventEnvelopeV1"]
        if schema_errors or has_recipient_payload_field(instance.get("payload")):
            result.error(
                check_id,
                "FAIL_DURABLE_ROUTE_VECTOR",
                f"route vector must be schema-valid and keep recipient provenance out of payload: {schema_errors[:3]}",
                artifact,
            )
        rule_errors = {
            rule_id: evaluate_executable_rule(
                rule_id, instance, {},
                registry_document if isinstance(registry_document, dict) else {},
            )
            for rule_id in durable_rule_ids
        }
        expected_rule_failures = (
            {} if vector["valid"]
            else {"DURABLE_ROUTE_STREAM": ["PROJECTION_ROUTE_FORBIDDEN"]}
        )
        actual_rule_failures = {
            rule_id: errors for rule_id, errors in rule_errors.items() if errors
        }
        if (
            actual_rule_failures != expected_rule_failures
            or (
                not vector["valid"]
                and vector.get("expectedReason")
                != "PROJECTION_ROUTE_FORBIDDEN"
            )
        ):
            result.error(
                check_id,
                "FAIL_DURABLE_ROUTE_VECTOR",
                f"durable route vector has wrong independent rule outcome: {actual_rule_failures}",
                artifact,
            )

    active_operation_ids = [
        identifier
        for identifier in expand_id_sequence(final_config["operation_slots"])
        if identifier not in {"OP-007", "OP-023", "OP-037"}
    ]
    schema_vector_ids = set(vector_ids)
    missing_operation_vectors = [
        identifier
        for operation_id in active_operation_ids
        for identifier in (f"POS-{operation_id}", f"NEG-{operation_id}-CLOSED")
        if identifier not in schema_vector_ids
    ]
    if missing_operation_vectors:
        result.error(check_id, "FAIL_OPERATION_VECTOR_COVERAGE", f"active operation vector coverage missing: {', '.join(missing_operation_vectors)}", relative)

    fingerprint_vectors = document["fingerprintVectors"]
    if not isinstance(fingerprint_vectors, list) or not fingerprint_vectors:
        result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "fingerprintVectors must be nonempty", relative)
        fingerprint_vectors = []
    for index, vector in enumerate(fingerprint_vectors):
        artifact = f"{relative}#fingerprintVectors/{index}"
        required_fingerprint_fields = {
            "id", "schemaRef", "left", "right", "relationship",
            "expectedLeftCanonicalUtf8", "expectedLeftSha256",
            "expectedRightCanonicalUtf8", "expectedRightSha256",
        }
        if (
            not isinstance(vector, dict)
            or not isinstance(vector.get("id"), str)
            or not required_fingerprint_fields.issubset(vector)
            or vector.get("relationship") not in {"EQUAL", "DIFFERENT"}
        ):
            result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "fingerprint vector is incomplete", artifact)
        else:
            vector_ids.append(vector["id"])
            reference = vector["schemaRef"]
            file_part, separator, fragment = reference.partition("#") if isinstance(reference, str) else ("", "", "")
            target = (schema_root / file_part.removeprefix("schema/")).resolve(strict=False)
            found, target_schema = resolve_json_pointer_value(
                schema_documents.get(target), f"#{fragment}" if separator else "#"
            ) if target in schema_documents else (False, None)
            if not found:
                result.error(check_id, "FAIL_CONTRACT_VECTOR_SCHEMA_REF", f"unresolved fingerprint schemaRef: {reference}", artifact)
                continue
            for side in ("left", "right"):
                schema_errors = evaluate_schema_instance(
                    vector[side], target_schema, target, schema_root,
                    schema_documents,
                )
                if schema_errors:
                    result.error(
                        check_id,
                        "FAIL_FINGERPRINT_SCHEMA_INPUT",
                        f"{vector['id']} {side} is not schema-valid: {schema_errors[:3]}",
                        artifact,
                    )
            try:
                left_canonical = canonicalize_fingerprint_value(vector["left"])
                right_canonical = canonicalize_fingerprint_value(vector["right"])
            except (UnicodeError, ValueError) as exc:
                result.error(check_id, "FAIL_FINGERPRINT_CANONICALIZATION", f"{vector['id']} cannot canonicalize: {exc}", artifact)
                continue
            left_digest = hashlib.sha256(left_canonical.encode("utf-8")).hexdigest()
            right_digest = hashlib.sha256(right_canonical.encode("utf-8")).hexdigest()
            if (
                vector["expectedLeftCanonicalUtf8"] != left_canonical
                or vector["expectedRightCanonicalUtf8"] != right_canonical
                or vector["expectedLeftSha256"] != left_digest
                or vector["expectedRightSha256"] != right_digest
            ):
                result.error(
                    check_id,
                    "FAIL_FINGERPRINT_GOLDEN_DRIFT",
                    f"{vector['id']} expected bytes/digest differs from independent UTF-16-order canonicalization",
                    artifact,
                )
            actual_relationship = "EQUAL" if left_digest == right_digest else "DIFFERENT"
            if vector["relationship"] != actual_relationship:
                result.error(
                    check_id,
                    "FAIL_FINGERPRINT_RELATIONSHIP",
                    f"{vector['id']} relationship is {vector['relationship']} but digest relationship is {actual_relationship}",
                    artifact,
                )

    jcs_vectors = document.get("jcsConformanceVectors")
    if not isinstance(jcs_vectors, list) or [
        value.get("id") for value in jcs_vectors if isinstance(value, dict)
    ] != list(FIXED_JCS_VECTOR_IDS):
        result.error(
            check_id,
            "FAIL_JCS_VECTOR_INVENTORY",
            "jcsConformanceVectors must contain the exact ordered R34 inventory",
            relative,
        )
        jcs_vectors = jcs_vectors if isinstance(jcs_vectors, list) else []
    for index, vector in enumerate(jcs_vectors):
        artifact = f"{relative}#jcsConformanceVectors/{index}"
        if (
            not isinstance(vector, dict)
            or not isinstance(vector.get("id"), str)
            or not isinstance(vector.get("valid"), bool)
            or "value" not in vector
        ):
            result.error(check_id, "FAIL_JCS_VECTOR_STRUCTURE", "JCS vector is incomplete", artifact)
            continue
        if vector["valid"]:
            if (
                not isinstance(vector.get("expectedCanonicalUtf8"), str)
                or not isinstance(vector.get("expectedSha256"), str)
            ):
                result.error(check_id, "FAIL_JCS_VECTOR_STRUCTURE", "valid JCS vector needs expected bytes and digest", artifact)
                continue
            try:
                canonical = canonicalize_fingerprint_value(vector["value"])
            except (UnicodeError, ValueError) as exc:
                result.error(check_id, "FAIL_JCS_CANONICALIZATION", f"valid JCS vector was rejected: {exc}", artifact)
                continue
            digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
            if canonical != vector["expectedCanonicalUtf8"] or digest != vector["expectedSha256"]:
                result.error(
                    check_id,
                    "FAIL_JCS_GOLDEN_DRIFT",
                    "R34 canonical UTF-8 bytes or SHA-256 differ from independent canonicalization",
                    artifact,
                )
        else:
            if not isinstance(vector.get("expectedReason"), str) or not vector["expectedReason"]:
                result.error(check_id, "FAIL_JCS_VECTOR_STRUCTURE", "invalid JCS vector needs expectedReason", artifact)
            try:
                canonicalize_fingerprint_value(vector["value"])
            except (UnicodeError, ValueError):
                pass
            else:
                result.error(
                    check_id,
                    "FAIL_JCS_NEGATIVE_ACCEPTED",
                    "deliberately invalid float/unsafe integer canonicalized successfully",
                    artifact,
                )

    def check_actor_vector_array(key: str, expected_ids: Sequence[str]) -> None:
        vectors = document.get(key)
        if not isinstance(vectors, list) or [
            value.get("id") for value in vectors if isinstance(value, dict)
        ] != list(expected_ids):
            result.error(
                check_id,
                "FAIL_ACTOR_PROJECTION_VECTOR_INVENTORY",
                f"{key} must contain the exact ordered R35 inventory",
                relative,
            )
            vectors = vectors if isinstance(vectors, list) else []
        for index, vector in enumerate(vectors):
            artifact = f"{relative}#{key}/{index}"
            if (
                not isinstance(vector, dict)
                or not isinstance(vector.get("id"), str)
                or not isinstance(vector.get("schemaRef"), str)
                or not isinstance(vector.get("valid"), bool)
                or "instance" not in vector
            ):
                result.error(check_id, "FAIL_ACTOR_PROJECTION_VECTOR_STRUCTURE", "actor vector is incomplete", artifact)
                continue
            file_part, separator, fragment = vector["schemaRef"].partition("#")
            target = (schema_root / file_part.removeprefix("schema/")).resolve(strict=False)
            found, target_schema = resolve_json_pointer_value(
                schema_documents.get(target), f"#{fragment}" if separator else "#"
            ) if target in schema_documents else (False, None)
            if not found:
                result.error(check_id, "FAIL_CONTRACT_VECTOR_SCHEMA_REF", f"unresolved actor schemaRef: {vector['schemaRef']}", artifact)
                continue
            evaluation_errors = evaluate_schema_instance(
                vector["instance"], target_schema, target, schema_root,
                schema_documents,
            )
            if vector["valid"] == bool(evaluation_errors):
                result.error(
                    check_id,
                    "FAIL_ACTOR_PROJECTION_VECTOR_EXPECTATION",
                    f"{vector['id']} valid={vector['valid']} but evaluation returned {evaluation_errors[:3]}",
                    artifact,
                )
            if not vector["valid"] and vector.get("expectedReason") != "ACTOR_FIELD_FORBIDDEN":
                result.error(
                    check_id,
                    "FAIL_ACTOR_PROJECTION_VECTOR_STRUCTURE",
                    "R35 raw actor-field negatives must fail with ACTOR_FIELD_FORBIDDEN",
                    artifact,
                )

    check_actor_vector_array(
        "actorProjectionVectors", FIXED_ACTOR_PROJECTION_VECTOR_IDS
    )
    check_actor_vector_array(
        "actorTicketBindingVectors", FIXED_ACTOR_TICKET_VECTOR_IDS
    )

    machines_by_id = {
        machine.get("id"): machine
        for machine in registry_machines
        if isinstance(machine, dict) and isinstance(machine.get("id"), str)
    }
    machine_ids = list(machines_by_id)
    edge_vectors = document.get("stateMachineEdgeVectors")
    edge_vector_machine_ids = [
        vector.get("stateMachine")
        for vector in edge_vectors
        if isinstance(vector, dict)
    ] if isinstance(edge_vectors, list) else []
    if edge_vector_machine_ids != machine_ids:
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_EDGE_VECTOR_COVERAGE",
            "stateMachineEdgeVectors must cover the exact ordered registry machine inventory",
            relative,
        )
        edge_vectors = edge_vectors if isinstance(edge_vectors, list) else []
    for index, vector in enumerate(edge_vectors):
        artifact = f"{relative}#stateMachineEdgeVectors/{index}"
        if not isinstance(vector, dict) or set(vector) != {
            "stateMachine", "allowedEdges"
        }:
            result.error(
                check_id,
                "FAIL_STATE_MACHINE_EDGE_VECTOR_STRUCTURE",
                "state-machine edge vector must contain exactly stateMachine/allowedEdges",
                artifact,
            )
            continue
        machine = machines_by_id.get(vector.get("stateMachine"))
        expected_edges = machine.get("transitions") if isinstance(machine, dict) else None
        actual_edges = vector.get("allowedEdges")
        if (
            not isinstance(expected_edges, list)
            or not isinstance(actual_edges, list)
            or any(not isinstance(edge, list) or len(edge) != 2 for edge in actual_edges)
            or len(actual_edges) != len({tuple(edge) for edge in actual_edges if isinstance(edge, list) and len(edge) == 2})
            or actual_edges != expected_edges
        ):
            result.error(
                check_id,
                "FAIL_STATE_MACHINE_EDGE_VECTOR_EQUALITY",
                "allowedEdges must exactly equal the ordered registry transition set",
                artifact,
            )

    negative_machine_vectors = document.get("stateMachineVectors")
    negative_machine_ids = [
        vector.get("stateMachine")
        for vector in negative_machine_vectors
        if isinstance(vector, dict)
    ] if isinstance(negative_machine_vectors, list) else []
    if negative_machine_ids != machine_ids:
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_NEGATIVE_VECTOR_COVERAGE",
            "stateMachineVectors must cover the exact ordered registry machine inventory",
            relative,
        )
        negative_machine_vectors = (
            negative_machine_vectors
            if isinstance(negative_machine_vectors, list)
            else []
        )
    for index, vector in enumerate(negative_machine_vectors):
        artifact = f"{relative}#stateMachineVectors/{index}"
        machine = machines_by_id.get(vector.get("stateMachine")) if isinstance(vector, dict) else None
        states = set(machine.get("states", ())) if isinstance(machine, dict) else set()
        allowed_edges = {
            tuple(edge)
            for edge in machine.get("transitions", ())
            if isinstance(edge, list) and len(edge) == 2
        } if isinstance(machine, dict) else set()
        edge = (
            (vector.get("from"), vector.get("to"))
            if isinstance(vector, dict)
            else (None, None)
        )
        if (
            not isinstance(vector, dict)
            or set(vector) != {"id", "stateMachine", "from", "to", "expectedReason"}
            or vector.get("id") != (machine.get("negativeVector") if isinstance(machine, dict) else None)
            or vector.get("expectedReason") != "FORBIDDEN_TRANSITION"
            or edge[0] not in states
            or edge[1] not in states
            or edge in allowed_edges
        ):
            result.error(
                check_id,
                "FAIL_STATE_MACHINE_NEGATIVE_VECTOR",
                "negative vector must be the registered in-vocabulary forbidden edge",
                artifact,
            )

    state_sql_vectors = document.get("stateMachineSqlVectors")
    state_bindings = (
        registry_document.get("stateMachineBindings", [])
        if isinstance(registry_document, dict)
        else []
    )
    expected_state_sql_specs: list[tuple[Any, ...]] = []
    state_sql_bindings: dict[tuple[Any, ...], Mapping[str, Any]] = {}
    for binding in state_bindings if isinstance(state_bindings, list) else []:
        if not isinstance(binding, dict):
            continue
        machine_id = binding.get("stateMachine")
        machine = machines_by_id.get(machine_id)
        if not isinstance(machine, dict):
            continue
        states = machine.get("states", [])
        allowed = {
            tuple(edge) for edge in machine.get("transitions", ())
            if isinstance(edge, list) and len(edge) == 2
        }
        if not isinstance(states, list) or any(
            not isinstance(state, str) for state in states
        ):
            continue
        for ddl_binding in binding.get("ddlBindings", ()):
            if not isinstance(ddl_binding, dict):
                continue
            common = (
                machine_id, ddl_binding.get("database"),
                ddl_binding.get("table"), ddl_binding.get("stateColumn"),
            )
            state_sql_bindings[common] = ddl_binding
            initial_trigger = ddl_binding.get("initialTrigger")
            initial_target = (
                initial_trigger.get("toState")
                if isinstance(initial_trigger, dict)
                else machine.get("initial")
            )
            contributed_initial_edge = (
                (
                    initial_trigger.get("fromState"),
                    initial_trigger.get("toState"),
                )
                if isinstance(initial_trigger, dict)
                and initial_trigger.get("contributesTransition") is True
                else None
            )
            physical_update_edges = allowed - (
                {contributed_initial_edge}
                if contributed_initial_edge is not None else set()
            )
            expected_state_sql_specs.extend(
                (*common, "INITIAL", None, target, target == initial_target)
                for target in states
            )
            expected_state_sql_specs.extend(
                (
                    *common, "TRANSITION", source, target,
                    (source, target) in physical_update_edges,
                )
                for source in states
                for target in states
                if source != target or (source, target) in physical_update_edges
            )
    observed_state_sql_specs: list[tuple[Any, ...]] = []
    state_sql_families: dict[tuple[Any, ...], set[str]] = {}
    if not isinstance(state_sql_vectors, list) or not state_sql_vectors:
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_SQL_EXECUTION_COVERAGE",
            "stateMachineSqlVectors must exhaust every DDL-bound initial candidate and state edge",
            relative,
        )
        state_sql_vectors = []
    ddl_by_database = {
        "bridge": result.design_root / "contracts/sql/bridge-v1.sql",
        "mobile": result.design_root / "contracts/sql/mobile-v1.sql",
    }
    for index, vector in enumerate(state_sql_vectors):
        artifact = f"{relative}#stateMachineSqlVectors/{index}"
        if not isinstance(vector, dict):
            result.error(
                check_id, "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                "state-machine SQL vector must be an object", artifact,
            )
            continue
        vector_id = vector.get("id")
        if isinstance(vector_id, str) and vector_id:
            vector_ids.append(vector_id)
        observed_state_sql_specs.append((
            vector.get("stateMachine"), vector.get("database"),
            vector.get("table"), vector.get("stateColumn"),
            vector.get("phase"), vector.get("from"), vector.get("to"),
            vector.get("valid"),
        ))
        target_mutation = vector.get("targetMutation")
        mutation_key = (
            "insertValues" if vector.get("phase") == "INITIAL"
            else "setValues"
        )
        mutation_values = (
            target_mutation.get(mutation_key)
            if isinstance(target_mutation, dict) else None
        )
        non_state_mutation = (
            {
                key: value for key, value in mutation_values.items()
                if key != vector.get("stateColumn")
            }
            if isinstance(mutation_values, dict) else None
        )
        family_key = (
            vector.get("stateMachine"), vector.get("database"),
            vector.get("table"), vector.get("stateColumn"),
            vector.get("phase"), vector.get("from"),
        )
        family_signature = stable_json({
            "setupSteps": vector.get("setupSteps"),
            "rowKey": vector.get("rowKey"),
            "nonStateMutation": non_state_mutation,
        })
        state_sql_families.setdefault(family_key, set()).add(family_signature)
        database = vector.get("database")
        ddl_path = ddl_by_database.get(database)
        if ddl_path is None:
            result.error(
                check_id, "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                f"unknown state-vector database: {database!r}", artifact,
            )
            continue
        binding_key = (
            vector.get("stateMachine"), vector.get("database"),
            vector.get("table"), vector.get("stateColumn"),
        )
        ddl_binding = state_sql_bindings.get(binding_key)
        if ddl_binding is None:
            result.error(
                check_id, "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                "state vector does not resolve to one registry DDL binding",
                artifact,
            )
            continue
        error_code, message = execute_state_machine_sql_vector(
            ddl_path, vector, ddl_binding
        )
        if error_code:
            result.error(check_id, error_code, message, artifact)
    divergent_families = sorted(
        (family, len(signatures))
        for family, signatures in state_sql_families.items()
        if len(signatures) != 1
    )
    if divergent_families:
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_SQL_VECTOR_FAMILY",
            "all candidate targets for one binding/phase/from must share the "
            "same setup, row key, and non-state mutation values: "
            f"{divergent_families[:8]}",
            relative,
        )
    if observed_state_sql_specs != expected_state_sql_specs:
        missing = [
            spec for spec in expected_state_sql_specs
            if spec not in observed_state_sql_specs
        ]
        extra = [
            spec for spec in observed_state_sql_specs
            if spec not in expected_state_sql_specs
        ]
        result.error(
            check_id,
            "FAIL_STATE_MACHINE_SQL_EXECUTION_COVERAGE",
            "state SQL execution inventory differs from the independent registry/DDL binding closure: "
            f"missing={missing[:8]}, extra={extra[:8]}",
            relative,
        )

    sql_vectors = document["sqlVectors"]
    if not isinstance(sql_vectors, list) or not sql_vectors:
        result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "sqlVectors must be nonempty", relative)
        sql_vectors = []
    for index, vector in enumerate(sql_vectors):
        artifact = f"{relative}#sqlVectors/{index}"
        if not isinstance(vector, dict) or not isinstance(vector.get("id"), str):
            result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "SQL vector needs an id", artifact)
        else:
            vector_ids.append(vector["id"])

    admission_vectors = document["admissionVectors"]
    if not isinstance(admission_vectors, list) or not admission_vectors:
        result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "admissionVectors must be nonempty", relative)
        admission_vectors = []
    for index, vector in enumerate(admission_vectors):
        artifact = f"{relative}#admissionVectors/{index}"
        zero_effects = vector.get("expectedZeroEffects") if isinstance(vector, dict) else None
        if (
            not isinstance(vector, dict)
            or not isinstance(vector.get("id"), str)
            or not isinstance(vector.get("expectedReason"), str)
            or not isinstance(zero_effects, dict)
            or set(zero_effects) != FIXED_PREDECODE_ZERO_EFFECTS
            or any(value != 0 for value in zero_effects.values())
            or vector.get("providerCalls", zero_effects.get("providerCalls")) != 0
        ):
            result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", "admission vector must bind the exact all-zero pre-dispatch oracle", artifact)
        else:
            vector_ids.append(vector["id"])

    processed_vector_keys = {
        "schemaVectors", "fingerprintVectors", "admissionVectors", "sqlVectors",
        "stateMachineEdgeVectors", "stateMachineSqlVectors",
    }
    for key, values in document.items():
        if key in processed_vector_keys or not key.endswith("Vectors"):
            continue
        if not isinstance(values, list) or not values:
            result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", f"{key} must be a nonempty vector array", relative)
            continue
        for index, vector in enumerate(values):
            if not isinstance(vector, dict) or not isinstance(vector.get("id"), str):
                result.error(check_id, "FAIL_CONTRACT_VECTOR_STRUCTURE", f"{key}[{index}] needs an id", relative)
            else:
                vector_ids.append(vector["id"])

    injected = document["injectedFailureInventory"]
    if not isinstance(injected, list) or len(injected) < 4 or any(not isinstance(value, str) or not value for value in injected) or len(injected) != len(set(injected)):
        result.error(check_id, "FAIL_INJECTED_FAILURE_INVENTORY", "injectedFailureInventory must contain at least four unique nonblank cases", relative)
    if len(vector_ids) != len(set(vector_ids)):
        result.error(check_id, "FAIL_CONTRACT_VECTOR_DUPLICATE_ID", "contract vector IDs must be globally unique", relative)
    return {
        "fingerprint_vectors": len(fingerprint_vectors),
        "admission_vectors": len(admission_vectors),
        "schema_vectors": len(schema_vectors),
        "sql_vectors": len(sql_vectors),
        "vectors": len(vector_ids),
    }


def load_ddl(connection: sqlite3.Connection, paths: Sequence[Path]) -> None:
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA temp_store=MEMORY")
    connection.set_authorizer(sql_authorizer())
    for path in paths:
        sql = read_text(path)
        unsafe = ensure_safe_sql(sql)
        if unsafe:
            raise ValueError(f"file/config-capable SQL is forbidden: {unsafe}")
        connection.executescript(sql)


def strip_sql_comments(sql: str) -> str:
    return re.sub(
        r"/\*.*?\*/|--[^\r\n]*", " ", sql,
        flags=re.DOTALL,
    )


def extract_sql_trigger_edges(
    definition: str, column: str
) -> set[tuple[str, str]]:
    """Extract the closed OLD/NEW state edge algebra from a SQLite trigger."""
    definition = strip_sql_comments(definition)
    edges: set[tuple[str, str]] = set()
    pattern = re.compile(
        rf"(?is)OLD\.{re.escape(column)}\s*=\s*'([^']+)'\s+AND\s+"
        rf"NEW\.{re.escape(column)}\s*(?:=\s*'([^']+)'|IN\s*\(([^)]*)\))"
    )
    for match in pattern.finditer(definition):
        targets = [match.group(2)] if match.group(2) else re.findall(
            r"'([^']+)'", match.group(3) or ""
        )
        edges.update((match.group(1), target) for target in targets)
    reverse_pattern = re.compile(
        rf"(?is)NEW\.{re.escape(column)}\s*=\s*'([^']+)'\s+AND\s+"
        rf"OLD\.{re.escape(column)}\s*(?:=\s*'([^']+)'|IN\s*\(([^)]*)\))"
    )
    for match in reverse_pattern.finditer(definition):
        sources = [match.group(2)] if match.group(2) else re.findall(
            r"'([^']+)'", match.group(3) or ""
        )
        edges.update((source, match.group(1)) for source in sources)
    old_not_in = re.search(
        rf"(?is)OLD\.{re.escape(column)}\s+NOT\s+IN\s*\(([^)]*)\)",
        definition,
    )
    new_not_in = re.search(
        rf"(?is)NEW\.{re.escape(column)}\s+NOT\s+IN\s*\(([^)]*)\)",
        definition,
    )
    if old_not_in and new_not_in:
        sources = re.findall(r"'([^']+)'", old_not_in.group(1))
        targets = re.findall(r"'([^']+)'", new_not_in.group(1))
        edges.update((source, target) for source in sources for target in targets)
    return edges


def execute_sql_negative_vector(
    ddl_path: Path,
    setup_sql: str,
    statement: str,
    expected_error: str,
) -> tuple[str | None, str]:
    unsafe = ensure_safe_sql(setup_sql + "\n" + statement)
    if unsafe:
        return "FAIL_SQL_FILE_IO", f"negative vector contains file/config-capable SQL: {unsafe}"
    connection = sqlite3.connect(":memory:")
    try:
        load_ddl(connection, [ddl_path])
        if setup_sql.strip():
            connection.executescript(setup_sql)
        try:
            connection.execute(statement)
            connection.commit()
        except sqlite3.Error as exc:
            if expected_error not in str(exc):
                return (
                    "FAIL_SQL_NEGATIVE_WRONG_ERROR",
                    f"raised {exc!s}, expected substring {expected_error!r}",
                )
            return None, str(exc)
        return "FAIL_SQL_NEGATIVE_ACCEPTED", "deliberate negative statement unexpectedly succeeded"
    except (OSError, UnicodeError, sqlite3.Error, ValueError) as exc:
        return "FAIL_SQL_NEGATIVE_SETUP", f"setup failed before the deliberate statement: {exc}"
    finally:
        connection.close()


def sqlite_database_snapshot(
    connection: sqlite3.Connection,
) -> tuple[tuple[str, tuple[tuple[Any, ...], ...]], ...]:
    tables = [
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
    ]
    snapshot: list[tuple[str, tuple[tuple[Any, ...], ...]]] = []
    for table in tables:
        quoted = '"' + str(table).replace('"', '""') + '"'
        rows = tuple(tuple(row) for row in connection.execute(f"SELECT * FROM {quoted}"))
        snapshot.append((str(table), rows))
    return tuple(snapshot)


def execute_state_machine_sql_vector(
    ddl_path: Path,
    vector: Mapping[str, Any],
    ddl_binding: Mapping[str, Any],
) -> tuple[str | None, str]:
    required_fields = {
        "id", "stateMachine", "database", "table", "stateColumn",
        "phase", "from", "to", "setupSteps", "targetMutation",
        "valid", "rowKey", "postconditions",
    }
    valid = vector.get("valid")
    setup_steps = vector.get("setupSteps")
    target_mutation = vector.get("targetMutation")
    postconditions = vector.get("postconditions")
    row_key = vector.get("rowKey")
    if (
        set(vector) != required_fields
        or not isinstance(vector.get("id"), str)
        or not vector["id"]
        or vector.get("phase") not in {"INITIAL", "TRANSITION"}
        or not isinstance(vector.get("to"), str)
        or (
            vector.get("phase") == "INITIAL" and vector.get("from") is not None
        )
        or (
            vector.get("phase") == "TRANSITION"
            and not isinstance(vector.get("from"), str)
        )
        or not isinstance(setup_steps, list)
        or any(not isinstance(step, str) or not step.strip() for step in setup_steps)
        or not isinstance(target_mutation, dict)
        or not isinstance(valid, bool)
        or not isinstance(row_key, dict)
        or not row_key
        or any(
            not isinstance(key, str)
            or not key
            or not isinstance(value, (str, int))
            or isinstance(value, bool)
            for key, value in row_key.items()
        )
        or not isinstance(postconditions, list)
        or not postconditions
        or any(
            not isinstance(item, dict)
            or set(item) != {"query", "rows"}
            or not isinstance(item.get("query"), str)
            or not item["query"].strip()
            or not isinstance(item.get("rows"), list)
            for item in postconditions
        )
    ):
        return (
            "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
            "state SQL vector must use the exact executable setup/transaction/error/postcondition shape",
        )
    all_vector_sql = "\n".join(setup_steps)
    unsafe = ensure_safe_sql(all_vector_sql)
    if unsafe:
        return (
            "FAIL_SQL_FILE_IO",
            f"state SQL vector contains file/config-capable SQL: {unsafe}",
        )
    if re.search(
        r"(?i)\b(?:CREATE|DROP|ALTER|REINDEX|ANALYZE|BEGIN|COMMIT|END|"
        r"ROLLBACK|SAVEPOINT|RELEASE)\b",
        strip_sql_comments(all_vector_sql),
    ):
        return (
            "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
            "state SQL fixtures/cases may use DML only and may not replace schema guards",
        )
    mutation_key = (
        "insertValues" if vector.get("phase") == "INITIAL" else "setValues"
    )
    mutation_values = target_mutation.get(mutation_key)
    if (
        set(target_mutation) != {mutation_key}
        or not isinstance(mutation_values, dict)
        or not mutation_values
        or any(
            not isinstance(key, str)
            or not key
            or (
                value is not None
                and (
                    not isinstance(value, (str, int))
                    or isinstance(value, bool)
                )
            )
            for key, value in mutation_values.items()
        )
    ):
        return (
            "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
            "targetMutation must be one closed scalar insertValues/setValues object",
        )
    connection = sqlite3.connect(":memory:")
    try:
        load_ddl(connection, [ddl_path])
        table_name = str(vector["table"])
        state_column = str(vector["stateColumn"])
        table_columns = sqlite_introspection(
            connection, "table_info", table_name
        )
        primary_key_columns = [
            row[1]
            for row in sorted(table_columns, key=lambda row: int(row[5] or 0))
            if int(row[5] or 0) > 0
        ]
        if set(row_key) != set(primary_key_columns):
            return (
                "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                f"rowKey must equal the real primary key columns {primary_key_columns!r}",
            )
        actual_column_names = {str(row[1]) for row in table_columns}
        if (
            not set(mutation_values).issubset(actual_column_names)
            or state_column not in mutation_values
            or mutation_values[state_column] != vector["to"]
            or not isinstance(ddl_binding.get("mutationColumns"), dict)
            or set(ddl_binding["mutationColumns"])
            != {"INITIAL", "TRANSITION"}
            or set(mutation_values)
            != set(ddl_binding["mutationColumns"].get(vector["phase"], ()))
            or (
                vector["phase"] == "INITIAL"
                and any(
                    mutation_values.get(column) != row_key[column]
                    for column in primary_key_columns
                )
            )
            or (
                vector["phase"] == "TRANSITION"
                and set(mutation_values) & set(primary_key_columns)
            )
        ):
            return (
                "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                "targetMutation must assign the exact target state and may not change the registered primary key",
            )
        table_names = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        ]
        fk_neighbors = {table_name}
        for candidate_table in table_names:
            foreign_rows = sqlite_introspection(
                connection, "foreign_key_list", str(candidate_table)
            )
            referenced = {str(row[2]) for row in foreign_rows}
            if candidate_table == table_name:
                fk_neighbors.update(referenced)
            if table_name in referenced:
                fk_neighbors.add(str(candidate_table))
        allowed_changed_tables = ddl_binding.get("allowedChangedTables")
        if (
            not isinstance(allowed_changed_tables, list)
            or allowed_changed_tables != sorted(set(allowed_changed_tables))
            or table_name not in allowed_changed_tables
            or set(allowed_changed_tables) - fk_neighbors
        ):
            return (
                "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                "DDL binding allowedChangedTables must independently name the target "
                "and only real one-hop FK neighbors",
            )
        neighbor_postconditions: dict[str, str] = {}
        for changed_table in allowed_changed_tables:
            if changed_table == table_name:
                continue
            changed_columns = sqlite_introspection(
                connection, "table_info", changed_table
            )
            changed_primary_key = [
                str(row[1])
                for row in sorted(
                    changed_columns, key=lambda row: int(row[5] or 0)
                )
                if int(row[5] or 0) > 0
            ]
            if not changed_primary_key:
                return (
                    "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                    f"changed neighbor {changed_table!r} has no primary key for exact post-state proof",
                )
            neighbor_postconditions[changed_table] = (
                "SELECT * FROM "
                + '"' + changed_table.replace('"', '""') + '"'
                + " ORDER BY "
                + ",".join(
                    '"' + column.replace('"', '""') + '"'
                    for column in changed_primary_key
                )
            )
        postcondition_queries = {
            item["query"].strip() for item in postconditions
        }
        missing_neighbor_proofs = sorted(
            table for table, query in neighbor_postconditions.items()
            if query not in postcondition_queries
        )
        if missing_neighbor_proofs:
            return (
                "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                "changed FK neighbors need canonical full-table PK-ordered "
                "postconditions: " + ", ".join(missing_neighbor_proofs),
            )

        quoted_table = '"' + table_name.replace('"', '""') + '"'
        quoted_state = '"' + state_column.replace('"', '""') + '"'
        ordered_key_columns = primary_key_columns
        where_clause = " AND ".join(
            '"' + column.replace('"', '""') + '"=?'
            for column in ordered_key_columns
        )
        key_parameters = tuple(row_key[column] for column in ordered_key_columns)

        def observed_bound_state() -> list[Any]:
            return [
                row[0]
                for row in connection.execute(
                    f"SELECT {quoted_state} FROM {quoted_table} WHERE {where_clause}",
                    key_parameters,
                ).fetchall()
            ]

        if vector["phase"] == "INITIAL":
            initial_trigger = ddl_binding.get("initialTrigger")
            trigger_names = (
                [initial_trigger.get("name")]
                if isinstance(initial_trigger, dict)
                and isinstance(initial_trigger.get("name"), str)
                else []
            )
        else:
            trigger_names = ddl_binding.get("transitionTriggers", [])
        trigger_markers: set[str] = set()
        if not isinstance(trigger_names, list) or not trigger_names:
            return (
                "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                "every executable state phase needs registered guard trigger names",
            )
        marker_owners: dict[str, set[str]] = {}
        for candidate_name, candidate_sql in connection.execute(
            "SELECT name, sql FROM sqlite_master WHERE type='trigger'"
        ):
            for marker in re.findall(
                r"(?is)RAISE\s*\(\s*ABORT\s*,\s*'([^']+)'\s*\)",
                str(candidate_sql or ""),
            ):
                marker_owners.setdefault(marker, set()).add(
                    str(candidate_name)
                )
        for trigger_name in trigger_names:
            trigger_row = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?",
                (trigger_name,),
            ).fetchone()
            if trigger_row is None or not isinstance(trigger_row[0], str):
                return (
                    "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                    f"registered state guard trigger is missing: {trigger_name!r}",
                )
            trigger_sql = strip_sql_comments(trigger_row[0])
            candidate_markers = set(re.findall(
                r"(?is)RAISE\s*\(\s*ABORT\s*,\s*'([^']+)'\s*\)",
                trigger_sql,
            ))
            row_columns = {
                match.group(1)
                for match in re.finditer(
                    r"(?is)\b(?:OLD|NEW)\.([A-Za-z_][A-Za-z0-9_]*)",
                    trigger_sql,
                )
            }
            if (
                row_columns != {state_column}
                or re.search(r"(?is)\b(?:EXISTS|FROM)\b", trigger_sql)
                or not candidate_markers
                or any(
                    marker_owners.get(marker) != {trigger_name}
                    for marker in candidate_markers
                )
                or (
                    vector["phase"] == "TRANSITION"
                    and not extract_sql_trigger_edges(
                        trigger_sql, state_column
                    )
                )
            ):
                return (
                    "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                    f"registered trigger is not a pure unique-marker state guard: {trigger_name!r}",
                )
            trigger_markers.update(candidate_markers)
        if not trigger_markers:
            return (
                "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
                "registered state guard triggers need literal RAISE(ABORT) markers",
            )

        def quoted_identifier(value: str) -> str:
            return '"' + value.replace('"', '""') + '"'

        mutation_columns = list(mutation_values)
        mutation_parameters = tuple(
            mutation_values[column] for column in mutation_columns
        )
        if vector["phase"] == "INITIAL":
            target_sql = (
                f"INSERT INTO {quoted_table} ("
                + ",".join(quoted_identifier(column) for column in mutation_columns)
                + ") VALUES ("
                + ",".join("?" for _ in mutation_columns)
                + ")"
            )
            target_parameters = mutation_parameters
        else:
            target_sql = (
                f"UPDATE {quoted_table} SET "
                + ",".join(
                    f"{quoted_identifier(column)}=?"
                    for column in mutation_columns
                )
                + f" WHERE {where_clause}"
            )
            target_parameters = mutation_parameters + key_parameters

        for statement in setup_steps:
            connection.execute(statement)
        connection.commit()
        before_state = observed_bound_state()
        expected_before_state = (
            [] if vector["phase"] == "INITIAL" else [vector["from"]]
        )
        if before_state != expected_before_state:
            return (
                "FAIL_STATE_MACHINE_SQL_SETUP",
                f"registered row state after setup is {before_state!r}, expected {expected_before_state!r}",
            )
        before = sqlite_database_snapshot(connection)
        caught: sqlite3.Error | None = None
        target_row_count: int | None = None
        try:
            connection.execute("BEGIN")
            target_row_count = connection.execute(
                target_sql, target_parameters
            ).rowcount
            connection.commit()
        except sqlite3.Error as exc:
            caught = exc
            if connection.in_transaction:
                connection.rollback()
        if valid:
            if caught is not None:
                return (
                    "FAIL_STATE_MACHINE_SQL_ALLOWED_EDGE",
                    f"allowed state case raised {getattr(caught, 'sqlite_errorname', None)}/{caught}",
                )
            if target_row_count != 1:
                return (
                    "FAIL_STATE_MACHINE_SQL_ALLOWED_EDGE",
                    f"target mutation rowcount is {target_row_count!r}, expected 1",
                )
            after_state = observed_bound_state()
            if after_state != [vector["to"]]:
                return (
                    "FAIL_STATE_MACHINE_SQL_ALLOWED_EDGE",
                    f"allowed case left registered row state {after_state!r}, expected {[vector['to']]!r}",
                )
            after = sqlite_database_snapshot(connection)
            before_by_table = dict(before)
            after_by_table = dict(after)
            changed_tables = sorted(
                table
                for table in set(before_by_table) | set(after_by_table)
                if before_by_table.get(table) != after_by_table.get(table)
            )
            if changed_tables != allowed_changed_tables:
                return (
                    "FAIL_STATE_MACHINE_SQL_POSTSTATE",
                    f"changed tables are {changed_tables!r}, expected binding-owned {allowed_changed_tables!r}",
                )
        else:
            if caught is None:
                return (
                    "FAIL_STATE_MACHINE_SQL_FORBIDDEN_EDGE",
                    "forbidden state case unexpectedly committed",
                )
            if (
                getattr(caught, "sqlite_errorname", None)
                != "SQLITE_CONSTRAINT_TRIGGER"
                or str(caught) not in trigger_markers
            ):
                return (
                    "FAIL_STATE_MACHINE_SQL_WRONG_ERROR",
                    "forbidden state case did not fail at a registered guard marker; "
                    f"markers={sorted(trigger_markers)!r}, observed="
                    f"{getattr(caught, 'sqlite_errorname', None)}/{caught}",
                )
            after = sqlite_database_snapshot(connection)
            if after != before:
                return (
                    "FAIL_STATE_MACHINE_SQL_POSTSTATE",
                    "forbidden state case changed database state",
                )
        connection.set_authorizer(sql_authorizer(read_only=True))
        try:
            for item in postconditions:
                if ensure_safe_sql(item["query"]):
                    return (
                        "FAIL_SQL_FILE_IO",
                        "state SQL postcondition contains forbidden SQL",
                    )
                actual = [
                    list(row) for row in connection.execute(item["query"]).fetchall()
                ]
                if actual != item["rows"]:
                    return (
                        "FAIL_STATE_MACHINE_SQL_POSTSTATE",
                        f"postcondition returned {actual!r}, expected {item['rows']!r}",
                    )
        finally:
            connection.set_authorizer(sql_authorizer())
        return None, "executed"
    except (OSError, UnicodeError, sqlite3.Error, ValueError) as exc:
        return (
            "FAIL_STATE_MACHINE_SQL_SETUP",
            f"state SQL fixture failed before its registered case: {exc}",
        )
    finally:
        connection.close()


def apply_sql_fixture(connection: sqlite3.Connection, name: str) -> bool:
    """Install a frozen vector fixture without reading or writing a product DB."""
    zero = "0" * 64

    def seed_source(codex: str = "source-a") -> None:
        connection.execute(
            "INSERT INTO source_partition VALUES (?,?,?,1)",
            ("bridge", "instance", codex),
        )

    def seed_thread(thread: str = "thread-a", codex: str = "source-a") -> None:
        try:
            seed_source(codex)
        except sqlite3.IntegrityError:
            pass
        connection.execute(
            """INSERT OR IGNORE INTO catalog_head
            (bridge_identity_id,bridge_instance_id,codex_source_id,catalog_scope_id,
             head_version,state,manifest_digest,writer_owner)
            VALUES (?,?,?,?,1,'PRESENT',?,'ConversationCatalogWriter')""",
            ("bridge", "instance", codex, "catalog", zero),
        )
        connection.execute(
            "INSERT OR IGNORE INTO catalog_session VALUES (?,?,?,?,?,1,?)",
            ("bridge", "instance", codex, thread, "catalog", thread),
        )

    def seed_certification(codex: str = "source-a") -> None:
        try:
            seed_source(codex)
        except sqlite3.IntegrityError:
            pass
        connection.execute(
            """INSERT OR IGNORE INTO codex_adapter_certification
            (bridge_identity_id,bridge_instance_id,codex_source_id,
             codex_certification_id,certification_revision,provider_build_digest,
             method_set_digest,schema_digest,history_read_certification,
             ordering_certification,codex_certification_digest)
            VALUES ('bridge','instance',?,'cert-1',1,?,?,?,
                    'CERTIFIED','CERTIFIED',?)""",
            (codex, zero, zero, zero, "c" * 64),
        )

    def seed_timeline_head() -> None:
        seed_thread()
        seed_certification()
        connection.execute(
            """INSERT INTO timeline_head
            (bridge_identity_id,bridge_instance_id,codex_source_id,
             provider_thread_id,head_version,current_materialization_id,state,
             read_spec_digest,manifest_digest,codex_certification_id,
             codex_certification_digest,writer_owner)
            VALUES ('bridge','instance','source-a','thread-a',0,NULL,'ABSENT',
                    ?,?,NULL,NULL,'CanonicalTimelineWriter')""",
            (zero, zero),
        )

    def insert_materialization(
        materialization_id: str,
        base: int,
        candidate: int,
        page_count: int,
        flags: int = 0,
    ) -> None:
        seed_certification()
        completeness = "COMPLETE" if page_count == 1 else "PARTIAL"
        empty = "e" * 64 if completeness == "COMPLETE" else None
        connection.execute(
            """INSERT INTO timeline_materialization
            (bridge_identity_id,bridge_instance_id,codex_source_id,
             provider_thread_id,materialization_id,base_head_version,
             candidate_head_version,read_spec_digest,read_evidence_digest,
             codex_certification_id,codex_certification_digest,
             expected_manifest_digest,coverage_digest,page_count,completeness,
             empty_proof_digest,computed_manifest_digest,computed_coverage_digest,
             order_proof_digest,verification_artifact_digest,state)
            VALUES (?,?,?,?,?,?,?,?,?,'cert-1',?,?,?,?,?,?,?,?,?,?,'STAGING')""",
            (
                "bridge", "instance", "source-a", "thread-a",
                materialization_id, base, candidate, zero, zero, "c" * 64,
                "1" * 64, zero, page_count, completeness, empty,
                "1" * 64 if flags else None,
                zero if flags else None,
                "2" * 64 if flags else None,
                "3" * 64 if flags else None,
            ),
        )

    def commit_empty_materialization(materialization_id: str = "mat-good") -> None:
        insert_materialization(materialization_id, 0, 1, 1, 1)
        connection.execute(
            "INSERT INTO timeline_materialization_page VALUES "
            "('bridge','instance','source-a','thread-a',?,0,?,NULL,0)",
            (materialization_id, "1" * 64),
        )
        connection.execute(
            "UPDATE timeline_materialization SET state='SEALED' "
            "WHERE materialization_id=?",
            (materialization_id,),
        )
        connection.execute(
            """UPDATE timeline_head
            SET head_version=1,current_materialization_id=?,state='ACTIVE',
                read_spec_digest=?,manifest_digest=?,
                codex_certification_id='cert-1',codex_certification_digest=?
            WHERE provider_thread_id='thread-a'""",
            (materialization_id, zero, "1" * 64, "c" * 64),
        )

    def seed_operation(
        operation_id: str,
        codex: str = "source-a",
        registry_id: str = "OP-001",
        state: str = "ADMITTED",
    ) -> None:
        if registry_id == "OP-001":
            seed_thread("thread-a", codex)
        else:
            try:
                seed_source(codex)
            except sqlite3.IntegrityError:
                pass
        connection.execute(
            """INSERT INTO operation
            (bridge_identity_id,bridge_instance_id,codex_source_id,operation_id,
             operation_registry_id,operation_kind,source_epoch,deadline_epoch_ms,
             accepted_deadline_policy,retry_of_operation_id,client_message_id,
             target_provider_thread_id,target_interaction_id,target_resource_id,
             actor_kind,actor_principal_id,actor_binding_digest,fingerprint,
             target_json,payload_json,preconditions_json,lifecycle_state,
             effect_observation_state,operation_revision,active_attempt_id)
            VALUES (?,?,?,?,?,?,1,999999,'REJECT_IF_EXPIRED',?,?,?,?,?,
                    'paired_device','actor',?,?, '{}','{}','{}','RECEIVED',
                    'NONE',1,NULL)""",
            (
                "bridge", "instance", codex, operation_id, registry_id,
                "START_TURN" if registry_id == "OP-001" else registry_id,
                None,
                "client-" + operation_id if registry_id == "OP-001" else None,
                "thread-a" if registry_id == "OP-001" else None,
                None, None, zero, zero,
            ),
        )
        if state != "RECEIVED":
            connection.execute(
                "UPDATE operation SET lifecycle_state='ADMITTED',operation_revision=2 "
                "WHERE operation_id=? AND codex_source_id=?",
                (operation_id, codex),
            )
        if state == "READY":
            connection.execute(
                "UPDATE operation SET lifecycle_state='READY',operation_revision=3 "
                "WHERE operation_id=? AND codex_source_id=?",
                (operation_id, codex),
            )

    if name == "BRIDGE_SOURCE_ONLY":
        seed_source()
    elif name == "BRIDGE_TWO_THREADS":
        seed_thread("thread-a")
        seed_thread("thread-b")
    elif name == "BRIDGE_INTERACTION_WITH_ACTIVE_CLAIM":
        seed_thread()
        seed_operation("op-claim", registry_id="OP-016")
        seed_operation("op-claim-2", registry_id="OP-016")
        connection.execute(
            """INSERT INTO interaction
            (bridge_identity_id,bridge_instance_id,codex_source_id,
             provider_thread_id,interaction_id,variant,state,
             interaction_revision,source_epoch,provider_request_id,
             provider_request_generation,provider_deadline_epoch_ms,
             request_turn_locator_id,request_descriptor_json)
            VALUES ('bridge','instance','source-a','thread-a','interaction-1',
                    'APPROVAL','OPEN_UNCLAIMED',1,1,'request-1',1,999999,
                    'turn-1','{}')"""
        )
        connection.execute(
            """INSERT INTO interaction_claim
            (bridge_identity_id,bridge_instance_id,codex_source_id,interaction_id,
             claim_id,admission_operation_id,actor_kind,actor_principal_id,
             actor_binding_digest,source_epoch,provider_request_generation,
             claim_revision,state,lease_deadline_ms)
            VALUES ('bridge','instance','source-a','interaction-1','claim-1',
                    'op-claim','paired_device','actor',?,1,1,1,'ACTIVE',999999)""",
            (zero,),
        )
    elif name == "BRIDGE_TWO_SOURCE_TRUST_CLAIM":
        seed_operation("op-a", "source-a")
        seed_operation("op-b", "source-b")
        connection.execute(
            "INSERT INTO execution_conflict_claim VALUES "
            "('bridge','instance','source-a','op-a',1,'BRIDGE_TRUST',"
            "'BRIDGE_INSTALLATION',NULL,'trust:principal-1','ACTIVE')"
        )
    elif name == "BRIDGE_CONFLICT_OWNER_AND_CANDIDATE":
        seed_operation("op-owner")
        seed_operation("op-candidate")
        connection.execute(
            "INSERT INTO execution_conflict_claim VALUES "
            "('bridge','instance','source-a','op-owner',1,'FILE_ROOT',"
            "'SOURCE','source-a','file:z-busy','ACTIVE')"
        )
    elif name in {"BRIDGE_QUEUE", "BRIDGE_QUEUE_WITH_DISPATCH_OWNER"}:
        seed_thread()
        seed_operation("op-a", state="ADMITTED")
        connection.execute(
            "INSERT INTO operation_queue_lane VALUES "
            "('bridge','instance','source-a','lane-1','THREAD_PROVIDER',"
            "'thread-a',1,16)"
        )
        if name.endswith("DISPATCH_OWNER"):
            seed_operation("op-b", registry_id="OP-001", state="ADMITTED")
            connection.execute(
                "INSERT INTO queue_entry VALUES "
                "('bridge','instance','source-a','lane-1','entry-1','op-a',"
                "1,1,?,'a','DISPATCH_OWNED')",
                (zero,),
            )
            connection.execute(
                "INSERT INTO queue_entry VALUES "
                "('bridge','instance','source-a','lane-1','entry-2','op-b',"
                "2,1,?,'b','QUEUED')",
                (zero,),
            )
    elif name == "BRIDGE_CALL_STARTED":
        seed_operation("op-a", state="READY")
        connection.execute(
            "INSERT INTO dispatch_attempt VALUES "
            "('bridge','instance','source-a','op-a','attempt-1',1,'PREPARED',?,NULL,NULL)",
            (zero,),
        )
        connection.execute(
            "UPDATE operation SET lifecycle_state='DISPATCHING',"
            "active_attempt_id='attempt-1',operation_revision=4 "
            "WHERE operation_id='op-a'"
        )
        connection.execute(
            "UPDATE dispatch_attempt SET state='CALL_STARTED' WHERE operation_id='op-a'"
        )
    elif name == "BRIDGE_DISPATCH_PREPARED":
        seed_operation("op-a", state="READY")
        connection.execute(
            "INSERT INTO dispatch_attempt VALUES "
            "('bridge','instance','source-a','op-a','attempt-1',1,'PREPARED',?,NULL,NULL)",
            (zero,),
        )
    elif name == "BRIDGE_RESOURCE_POLICY_REV1":
        seed_source()
        connection.execute(
            "INSERT INTO resource_policy VALUES "
            "('bridge','instance','source-a','auto-approval',1,?)",
            (zero,),
        )
    elif name == "MOBILE_SOURCE_WITH_PROTECTED_DRAFT":
        seed_source()
        connection.execute(
            "INSERT INTO protected_draft VALUES ('draft-1','{}',NULL,1,'draft','[]')"
        )
    elif name in {"MOBILE_APPLIED_NOT_READBACK", "MOBILE_RECEIVED"}:
        seed_source()
        connection.execute(
            """INSERT INTO inbox_event
            (bridge_identity_id,bridge_instance_id,codex_source_id,source_epoch,
             stream_kind,stream_id,subscription_generation,stream_seq,base_seq,
             commit_seq,event_id,event_kind,repair_kind,payload_hash,apply_state)
            VALUES ('bridge','instance','source-a',1,'SOURCE_PROJECTION','stream-a',
                    1,1,0,1,'event-1','catalog.snapshot','CONTIGUOUS',?,'RECEIVED')""",
            (zero,),
        )
        if name == "MOBILE_APPLIED_NOT_READBACK":
            connection.execute(
                "UPDATE inbox_event SET apply_state='STAGED',apply_revision=2 WHERE event_id='event-1'"
            )
            connection.execute(
                "UPDATE inbox_event SET apply_state='APPLIED',apply_revision=3 WHERE event_id='event-1'"
            )
    elif name == "BRIDGE_THREAD_HEAD_ONLY":
        seed_timeline_head()
    elif name == "BRIDGE_LAST_GOOD_STAGING":
        seed_timeline_head()
        commit_empty_materialization()
        insert_materialization("mat-bad", 1, 2, 1, 0)
    elif name in {
        "BRIDGE_MATERIALIZATION_EMPTY", "BRIDGE_MATERIALIZATION_PAGE0",
        "BRIDGE_MATERIALIZATION_MISSING_PAGE",
        "BRIDGE_MATERIALIZATION_STALE_SEALED",
        "BRIDGE_MATERIALIZATION_SEALED",
        "BRIDGE_MATERIALIZATION_TWO_PAGES",
    }:
        seed_timeline_head()
        materialization_id = "mat-stale" if name == "BRIDGE_MATERIALIZATION_STALE_SEALED" else "mat-1"
        if name == "BRIDGE_MATERIALIZATION_STALE_SEALED":
            insert_materialization(materialization_id, 1, 2, 1, 1)
        elif name == "BRIDGE_MATERIALIZATION_SEALED":
            insert_materialization(materialization_id, 0, 1, 1, 1)
        elif name in {"BRIDGE_MATERIALIZATION_MISSING_PAGE", "BRIDGE_MATERIALIZATION_TWO_PAGES"}:
            insert_materialization(materialization_id, 0 if name == "BRIDGE_MATERIALIZATION_TWO_PAGES" else 1, 1 if name == "BRIDGE_MATERIALIZATION_TWO_PAGES" else 2, 2, 0)
        else:
            insert_materialization(materialization_id, 1, 2, 1, 0)
        if name != "BRIDGE_MATERIALIZATION_EMPTY":
            connection.execute(
                "INSERT INTO timeline_materialization_page VALUES "
                "('bridge','instance','source-a','thread-a',?,0,?,NULL,0)",
                (materialization_id, "1" * 64),
            )
        if name in {"BRIDGE_MATERIALIZATION_STALE_SEALED", "BRIDGE_MATERIALIZATION_SEALED"}:
            connection.execute(
                "UPDATE timeline_materialization SET state='SEALED' "
                "WHERE materialization_id=?",
                (materialization_id,),
            )
    elif name in {"BRIDGE_CONTENT_OFFER_CREATED", "BRIDGE_CONTENT_OFFER_OFFERED"}:
        seed_source()
        connection.execute(
            """INSERT INTO content_offer
            (bridge_identity_id,bridge_instance_id,codex_source_id,offer_id,
             offer_generation,owner_feature_id,backend_id,state,
             expires_at_epoch_ms,capacity_reservation_bytes_decimal,
             current_offset_bytes_decimal,offer_revision)
            VALUES ('bridge','instance','source-a','offer-1',1,'artifact',
                    'backend-1','OFFERED',999999,'1024','0',1)"""
        )
    elif name == "MOBILE_MATERIALIZATION_REPARENT":
        seed_source()
        connection.execute(
            "INSERT INTO m_catalog_head VALUES "
            "('bridge','instance','source-a','catalog',0,'ABSENT',?)",
            (zero,),
        )
        connection.execute(
            "INSERT INTO m_catalog_session VALUES "
            "('bridge','instance','source-a','thread-a','catalog',1,'thread-a')"
        )
        connection.execute(
            """INSERT INTO m_codex_adapter_certification
            (bridge_identity_id,bridge_instance_id,codex_source_id,
             codex_certification_id,codex_certification_digest,
             provider_build_digest,method_set_digest,schema_digest,
             history_read_certification,ordering_certification,
             certification_revision)
            VALUES ('bridge','instance','source-a','cert-1',?,?,?,?,
                    'CERTIFIED','CERTIFIED',1)""",
            ("c" * 64, zero, zero, zero),
        )
        for materialization_id in ("mat-a", "mat-b"):
            connection.execute(
                """INSERT INTO m_timeline_materialization
                (bridge_identity_id,bridge_instance_id,codex_source_id,
                 provider_thread_id,materialization_id,base_head_version,
                 candidate_head_version,read_spec_digest,expected_manifest_digest,
                 coverage_digest,read_evidence_digest,codex_certification_id,
                 codex_certification_digest,page_count,completeness,
                 empty_proof_digest,state)
                VALUES ('bridge','instance','source-a','thread-a',?,0,1,?,?,?,?,
                        'cert-1',?,1,'PARTIAL',NULL,'STAGING')""",
                (materialization_id, zero, "1" * 64, zero, zero, "c" * 64),
            )
        connection.execute(
            "INSERT INTO m_timeline_materialization_page VALUES "
            "('bridge','instance','source-a','thread-a','mat-a',0,?,NULL,0)",
            ("1" * 64,),
        )
    else:
        return False
    return True


def sql_parameters(raw: Any) -> tuple[Any, ...] | None:
    if raw is None:
        return ()
    if not isinstance(raw, list):
        return None
    values: list[Any] = []
    for item in raw:
        if isinstance(item, dict) and isinstance(item.get("repeat"), str) and isinstance(item.get("count"), int) and not isinstance(item.get("count"), bool) and item["count"] >= 0:
            values.append(item["repeat"] * item["count"])
        elif isinstance(item, (str, int, float)) or item is None:
            values.append(item)
        else:
            return None
    return tuple(values)


def execute_registered_sql_vector(
    ddl_path: Path, vector: Mapping[str, Any]
) -> tuple[str | None, str]:
    fixture_name = vector.get("setupFixture")
    if not isinstance(fixture_name, str):
        return "FAIL_SQL_NEGATIVE_FIXTURE", f"unknown setupFixture: {fixture_name!r}"
    statement = vector.get("statement")
    steps = vector.get("steps")
    if not isinstance(statement, str) and not isinstance(steps, list):
        return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "vector needs statement or steps"
    params = sql_parameters(vector.get("parameters"))
    if params is None:
        return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "invalid parameters"
    if isinstance(statement, str):
        statements = [statement]
    else:
        if any(
            not isinstance(step, dict)
            or not isinstance(step.get("statement"), str)
            or not step["statement"]
            for step in steps
        ):
            return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "steps contain an invalid statement"
        statements = [step["statement"] for step in steps]
    if not statements or any(not isinstance(value, str) or not value for value in statements):
        return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "steps contain an invalid statement"
    unsafe = ensure_safe_sql("\n".join(statements))
    if unsafe:
        return "FAIL_SQL_FILE_IO", f"negative vector contains file/config-capable SQL: {unsafe}"
    ddl_text = read_text(ddl_path)
    expected_constraint = vector.get("expectedConstraint")
    expected_reason = vector.get("expectedReason")
    expected_failure_mode = vector.get("expectedFailureMode")
    if (
        not isinstance(expected_constraint, str)
        or not expected_constraint
        or not isinstance(expected_reason, str)
        or not expected_reason
        or expected_failure_mode not in {"SQLITE_ERROR", "ROWCOUNT_ZERO", "NONE"}
    ):
        return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "expected reason/constraint/failure mode must be explicit"
    constraint_token = expected_constraint.split(".")[0]
    if " " not in expected_constraint and constraint_token not in ddl_text:
        return "FAIL_SQL_NEGATIVE_CONSTRAINT", f"expectedConstraint is absent from DDL: {expected_constraint}"
    connection = sqlite3.connect(":memory:", isolation_level=None)
    caught: sqlite3.Error | None = None
    caught_statement_index: int | None = None
    row_count: int | None = None
    try:
        load_ddl(connection, [ddl_path])
        if not apply_sql_fixture(connection, fixture_name):
            return "FAIL_SQL_NEGATIVE_FIXTURE", f"unknown setupFixture: {fixture_name!r}"
        constraint_object = None
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", expected_constraint):
            constraint_object = connection.execute(
                "SELECT type,tbl_name,sql FROM sqlite_master WHERE name=?",
                (expected_constraint,),
            ).fetchone()
        if expected_failure_mode == "SQLITE_ERROR" and constraint_object is None:
            normalized_constraint = re.sub(r"\s+", " ", expected_constraint).strip()
            normalized_binding_text = re.sub(
                r"\s+", " ", ddl_text + "\n" + "\n".join(statements)
            )
            if normalized_constraint not in normalized_binding_text:
                return (
                    "FAIL_SQL_NEGATIVE_CONSTRAINT",
                    f"expectedConstraint is not bound to executed DDL/statement: {expected_constraint}",
                )
        postconditions = vector.get("postconditions", [])
        post_state_mode = vector.get("postStateMode")
        expect_success = vector.get("expectSuccess") is True
        if not expect_success and (
            post_state_mode not in {
                "UNCHANGED_FROM_BEFORE_FAILURE", "UNCHANGED_FROM_SETUP"
            }
            or not isinstance(postconditions, list)
            or not postconditions
        ):
            return "FAIL_SQL_NEGATIVE_POSTCONDITION", "negative vector needs an unchanged-state mode and executable postcondition"
        if not isinstance(postconditions, list) or any(
            not isinstance(postcondition, dict)
            or not isinstance(postcondition.get("query"), str)
            or "equals" not in postcondition
            or not re.match(r"(?is)^SELECT\b", postcondition["query"].strip())
            for postcondition in postconditions
        ):
            return "FAIL_SQL_NEGATIVE_POSTCONDITION", "invalid read-only postcondition"

        def read_postconditions() -> list[Any]:
            connection.set_authorizer(sql_authorizer(read_only=True))
            try:
                return [
                    (lambda row: row[0] if row else None)(
                        connection.execute(postcondition["query"].strip()).fetchone()
                    )
                    for postcondition in postconditions
                ]
            finally:
                connection.set_authorizer(sql_authorizer())

        baseline_values: list[Any] = []
        prefix_count = (
            len(statements) - 1
            if post_state_mode == "UNCHANGED_FROM_BEFORE_FAILURE"
            and isinstance(steps, list)
            and len(statements) > 1
            else 0
        )
        if post_state_mode == "UNCHANGED_FROM_SETUP":
            baseline_values = read_postconditions()
        try:
            for index, sql in enumerate(statements[:prefix_count]):
                cursor = connection.execute(sql, params if index == 0 and isinstance(statement, str) else ())
                row_count = cursor.rowcount
            if post_state_mode == "UNCHANGED_FROM_BEFORE_FAILURE":
                baseline_values = read_postconditions()
            for index, sql in enumerate(statements[prefix_count:], prefix_count):
                cursor = connection.execute(sql, params if index == 0 and isinstance(statement, str) else ())
                row_count = cursor.rowcount
        except sqlite3.Error as exc:
            caught = exc
            caught_statement_index = index
            if connection.in_transaction:
                connection.rollback()
        if (
            caught is not None
            and post_state_mode == "UNCHANGED_FROM_BEFORE_FAILURE"
            and isinstance(steps, list)
            and caught_statement_index != len(statements) - 1
        ):
            return "FAIL_SQL_NEGATIVE_SETUP", "failure occurred before the registered final fault statement"
        expected_row_count = vector.get("expectRowCount")
        if expect_success:
            if expected_failure_mode != "NONE":
                return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "successful vector must declare expectedFailureMode=NONE"
            if caught is not None:
                return "FAIL_SQL_NEGATIVE_WRONG_ERROR", f"expected success but raised {caught}"
        elif isinstance(expected_row_count, int) and not isinstance(expected_row_count, bool):
            if expected_failure_mode != "ROWCOUNT_ZERO":
                return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "CAS rowcount vector must declare ROWCOUNT_ZERO"
            if caught is not None or row_count != expected_row_count:
                return "FAIL_SQL_NEGATIVE_ROW_COUNT", f"expected rowcount {expected_row_count}, got {row_count}, error={caught}"
        elif caught is None:
            return "FAIL_SQL_NEGATIVE_ACCEPTED", "deliberate negative statement unexpectedly succeeded"
        elif expected_failure_mode != "SQLITE_ERROR":
            return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "SQLite rejection must declare SQLITE_ERROR"
        expected_sql_error_name = vector.get("expectedSqlErrorName")
        expected_sql_message = vector.get("expectedSqlMessageContains")
        if caught is not None:
            if (
                not isinstance(expected_sql_error_name, str)
                or not expected_sql_error_name
                or not isinstance(expected_sql_message, str)
                or not expected_sql_message
            ):
                return "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE", "SQLite error vector needs exact name and message marker"
            actual_error_name = getattr(caught, "sqlite_errorname", None)
            if actual_error_name != expected_sql_error_name or expected_sql_message not in str(caught):
                return (
                    "FAIL_SQL_NEGATIVE_WRONG_ERROR",
                    f"expected {expected_sql_error_name}/{expected_sql_message!r}; "
                    f"observed {actual_error_name}/{caught!s}",
                )
            if constraint_object is not None and constraint_object[0] == "index":
                index_columns = [
                    row[2]
                    for row in sqlite_introspection(
                        connection, "index_info", str(expected_constraint)
                    )
                    if isinstance(row[2], str)
                ]
                if not index_columns or any(
                    f"{constraint_object[1]}.{column}" not in str(caught)
                    for column in index_columns
                ):
                    return (
                        "FAIL_SQL_NEGATIVE_WRONG_ERROR",
                        "SQLite UNIQUE failure does not name the registered index columns",
                    )
        try:
            actual_values = read_postconditions()
        except sqlite3.Error as exc:
            return "FAIL_SQL_NEGATIVE_POSTCONDITION", f"unsafe or invalid postcondition: {exc}"
        for index, (postcondition, actual) in enumerate(zip(postconditions, actual_values)):
            baseline = baseline_values[index] if index < len(baseline_values) else actual
            if actual != baseline:
                return (
                    "FAIL_SQL_NEGATIVE_POSTCONDITION",
                    f"post-state changed from {baseline!r} to {actual!r}",
                )
            if actual != postcondition["equals"]:
                return "FAIL_SQL_NEGATIVE_POSTCONDITION", f"postcondition returned {actual!r}, expected {postcondition['equals']!r}"
        quick = [
            row[0]
            for row in sqlite_introspection(connection, "quick_check")
        ]
        if quick != ["ok"]:
            return "FAIL_SQLITE_QUICK_CHECK", f"quick_check returned {quick!r}"
        return None, str(caught) if caught is not None else "rejected by rowcount/postcondition"
    except (OSError, UnicodeError, sqlite3.Error, ValueError) as exc:
        return "FAIL_SQL_NEGATIVE_SETUP", f"setup failed before the deliberate statement: {exc}"
    finally:
        connection.close()


def check_sqlite_ddl(
    result: ValidationResult, check_id: str, final_config: Mapping[str, Any]
) -> Mapping[str, Any]:
    sql_root = result.design_root / "contracts/sql"
    paths = sorted(
        path for path in sql_root.glob("*.sql") if path.is_file() and not path.is_symlink()
    )
    actual_paths = [path.relative_to(result.design_root).as_posix() for path in paths]
    if actual_paths != sorted(str(value) for value in final_config["ddl_files"]):
        result.error(
            check_id,
            "FAIL_SQLITE_DDL_INVENTORY",
            "contracts/sql must contain exactly bridge-v1.sql and mobile-v1.sql",
            "contracts/sql",
        )
    for path in paths:
        relative = path.relative_to(result.design_root).as_posix()
        sql_text = read_text(path)
        forbidden_markers = sorted(
            {
                match.group(0)
                for line in sql_text.splitlines()
                if not line_has_allow_context(line)
                for match in LEGACY_MARKER_RE.finditer(line)
            }
        )
        forbidden_aliases = [
            alias
            for alias in FORBIDDEN_ACTOR_ALIASES + FORBIDDEN_WRITER_ALIASES
            if alias.lower() in sql_text.lower()
        ]
        if forbidden_markers or forbidden_aliases or "CANDIDATE_BINDING" in sql_text:
            result.error(
                check_id,
                "FAIL_SQLITE_FORBIDDEN_MARKER",
                "DDL contains forbidden runtime/actor/writer marker: "
                + ", ".join(
                    [*forbidden_markers, *forbidden_aliases]
                    + (["CANDIDATE_BINDING"] if "CANDIDATE_BINDING" in sql_text else [])
                ),
                relative,
            )
        connection = sqlite3.connect(":memory:")
        try:
            load_ddl(connection, [path])
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            if any(
                "ephemeralchild" in re.sub(r"[^a-z0-9]", "", table.lower())
                for table in tables
            ):
                result.error(
                    check_id,
                    "FAIL_EPHEMERAL_DURABLE_TABLE",
                    "fresh DDL contains an ephemeral-child durable table",
                    relative,
                )
            prefix = "m_" if path.name == "mobile-v1.sql" else ""
            settings_table = f"{prefix}settings_head"
            settings_columns = tuple(
                row[1] for row in sqlite_introspection(
                    connection, "table_info", settings_table
                )
            ) if settings_table in tables else ()
            settings_table_sql = next(
                (
                    str(row[0] or "")
                    for row in connection.execute(
                        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
                        (settings_table,),
                    )
                ),
                "",
            )
            compact_settings_sql = re.sub(
                r"\s+", "", settings_table_sql.lower()
            )
            required_settings_checks = (
                "model_statein('unknown','value')",
                "effort_statein('unknown','explicit_null','value')",
                "service_tier_statein('unknown','explicit_null','value')",
                "approval_policy_statein('unknown','value')",
                "approvals_reviewer_statein('unknown','value')",
                "active_permission_profile_statein('unknown','explicit_null','value')",
                "sandbox_policy_statein('unknown','value')",
                "collaboration_mode_statein('unknown','value')",
                "(active_permission_profile_state='value')=(active_permission_profile_idisnotnull)",
                "active_permission_profile_state='value'oractive_permission_profile_extends_idisnull",
                "collaboration_mode_state='value'or(collaboration_mode_valueisnullandcollaboration_settings_modelisnullandcollaboration_effort_stateisnullandcollaboration_effort_valueisnull)",
            )
            if (
                settings_columns != FIXED_SETTINGS_DDL_COLUMNS
                or any(
                    forbidden in compact_settings_sql
                    for forbidden in (
                        "known_fields", "permission_mode", "sandbox_mode",
                    )
                )
                or any(
                    required not in compact_settings_sql
                    for required in required_settings_checks
                )
            ):
                result.error(
                    check_id,
                    "FAIL_SETTINGS_DDL_CONTRACT",
                    "R62 Bridge/Mobile settings head must exactly encode the eight required-vs-nullable observations, forbid legacy masks/aliases, and reject stray profile/collaboration branch fields",
                    relative,
                )
            content_ref_table = f"{prefix}content_ref"
            auto_policy_table = f"{prefix}auto_approval_policy"
            if (
                content_ref_table not in tables
                or (
                    path.name == "bridge-v1.sql"
                    and auto_policy_table not in tables
                )
                or any("resource_policy" in table.lower() for table in tables)
            ):
                result.error(
                    check_id,
                    "FAIL_CONTENT_POLICY_STORAGE",
                    "R45 requires ContentRef plus the unique AutoApproval policy table and forbids generic resource_policy storage",
                    relative,
                )
            required_evidence_tables = {
                f"{prefix}codex_adapter_certification",
                f"{prefix}codex_settings_capability_snapshot",
                f"{prefix}native_host_capability_snapshot",
                f"{prefix}feature_capability_snapshot",
                f"{prefix}timeline_head",
                f"{prefix}timeline_materialization",
                f"{prefix}materialization_verification_receipt",
            }
            missing_evidence_tables = sorted(required_evidence_tables - tables)
            if missing_evidence_tables:
                result.error(
                    check_id,
                    "FAIL_CAPABILITY_EVIDENCE_SCOPE",
                    "DDL lacks distinct capability evidence/read tables: "
                    + ", ".join(missing_evidence_tables),
                    relative,
                )
            immutable_evidence_tables = {
                f"{prefix}codex_adapter_certification",
                f"{prefix}codex_settings_capability_snapshot",
                f"{prefix}native_host_capability_snapshot",
                f"{prefix}feature_capability_snapshot",
            }
            trigger_rows = connection.execute(
                "SELECT tbl_name,sql FROM sqlite_master WHERE type='trigger'"
            ).fetchall()
            if path.name == "bridge-v1.sql":
                materialization_namespaces = {
                    "catalog_head", "catalog_materialization",
                    "catalog_materialization_page",
                    "catalog_materialization_receipt", "timeline_head",
                    "timeline_materialization", "timeline_materialization_page",
                    "materialization_verification_receipt",
                }
                catalog_page_fks = {
                    row[2] for row in sqlite_introspection(
                        connection, "foreign_key_list",
                        "catalog_materialization_page",
                    )
                } if "catalog_materialization_page" in tables else set()
                timeline_page_fks = {
                    row[2] for row in sqlite_introspection(
                        connection, "foreign_key_list",
                        "timeline_materialization_page",
                    )
                } if "timeline_materialization_page" in tables else set()
                catalog_head_sql = next(
                    (
                        str(row[0] or "")
                        for row in connection.execute(
                            "SELECT sql FROM sqlite_master WHERE type='table' AND name='catalog_head'"
                        )
                    ),
                    "",
                )
                timeline_head_sql = next(
                    (
                        str(row[0] or "")
                        for row in connection.execute(
                            "SELECT sql FROM sqlite_master WHERE type='table' AND name='timeline_head'"
                        )
                    ),
                    "",
                )
                if (
                    not materialization_namespaces.issubset(tables)
                    or "catalog_materialization" not in catalog_page_fks
                    or "timeline_materialization" in catalog_page_fks
                    or "timeline_materialization" not in timeline_page_fks
                    or "catalog_materialization" in timeline_page_fks
                    or "ConversationCatalogWriter" not in catalog_head_sql
                    or "CanonicalTimelineWriter" not in timeline_head_sql
                ):
                    result.error(
                        check_id,
                        "FAIL_MATERIALIZATION_WRITER_NAMESPACE",
                        "CATALOG/TIMELINE must use separate owner-bound tables/FKs with no cross-writer parent",
                        relative,
                    )
                expected_aggregate_tables = {
                    entry["aggregate"] for entry in FIXED_EXPECTED_AGGREGATE_EVENTS
                }
                expected_event_tables = {
                    entry["eventTable"] for entry in FIXED_EXPECTED_AGGREGATE_EVENTS
                }
                actual_domain_event_tables = {
                    table for table in tables
                    if table.endswith("_event")
                    and table not in {"durable_outbox_event", "inbox_event"}
                }
                if (
                    not expected_aggregate_tables.issubset(tables)
                    or actual_domain_event_tables != expected_event_tables
                ):
                    result.error(
                        check_id,
                        "FAIL_AGGREGATE_EVENT_DDL_EQUALITY",
                        "Bridge DDL aggregate/event tables must exactly equal expectedAggregateEventInventory",
                        relative,
                    )
                for entry in FIXED_EXPECTED_AGGREGATE_EVENTS:
                    aggregate = entry["aggregate"]
                    event_table = entry["eventTable"]
                    event_columns = {
                        row[1] for row in sqlite_introspection(
                            connection, "table_info", event_table
                        )
                    } if event_table in tables else set()
                    event_foreign_tables = {
                        row[2] for row in sqlite_introspection(
                            connection, "foreign_key_list", event_table
                        )
                    } if event_table in tables else set()
                    event_trigger_sql = [
                        str(sql or "") for table_name, sql in trigger_rows
                        if table_name == event_table
                    ]
                    aggregate_trigger_sql = [
                        str(sql or "") for table_name, sql in trigger_rows
                        if table_name == aggregate
                    ]
                    if (
                        "event_revision" not in event_columns
                        or aggregate not in event_foreign_tables
                        or not any(
                            re.search(r"(?i)BEFORE\s+UPDATE", sql)
                            for sql in event_trigger_sql
                        )
                        or not any(
                            re.search(r"(?i)BEFORE\s+DELETE", sql)
                            for sql in event_trigger_sql
                        )
                        or not any(
                            event_table in sql
                            and re.search(r"(?i)(?:revision|event)", sql)
                            for sql in aggregate_trigger_sql
                        )
                    ):
                        result.error(
                            check_id,
                            "FAIL_AGGREGATE_EVENT_ATOMICITY",
                            f"{aggregate}/{event_table} lacks FK, immutable event, and same-revision transaction guard",
                            relative,
                        )
            for evidence_table in sorted(immutable_evidence_tables & tables):
                table_triggers = [
                    str(sql or "") for table_name, sql in trigger_rows
                    if table_name == evidence_table
                ]
                selector_exists = any(
                    candidate != evidence_table
                    and candidate.startswith(evidence_table)
                    and re.search(r"(?i)(?:current|selector)", candidate)
                    for candidate in tables
                )
                if (
                    not selector_exists
                    or not any(re.search(r"(?i)BEFORE\s+UPDATE", sql) for sql in table_triggers)
                    or not any(re.search(r"(?i)BEFORE\s+DELETE", sql) for sql in table_triggers)
                ):
                    result.error(
                        check_id,
                        "FAIL_CAPABILITY_EVIDENCE_IMMUTABILITY",
                        f"{evidence_table} needs UPDATE/DELETE rejection and a separate exact-CAS current selector",
                        relative,
                    )
            for table in (
                f"{prefix}timeline_head", f"{prefix}timeline_materialization"
            ):
                if table not in tables:
                    continue
                columns = {
                    row[1]
                    for row in sqlite_introspection(
                        connection, "table_info", table
                    )
                }
                if not {"codex_certification_id", "codex_certification_digest"}.issubset(columns):
                    result.error(
                        check_id,
                        "FAIL_CAPABILITY_EVIDENCE_SCOPE",
                        f"{table} must bind immutable Codex certification identity/digest",
                        relative,
                    )
                if any(
                    column.startswith((
                        "feature_capability_snapshot",
                        "native_host_capability_snapshot",
                    ))
                    for column in columns
                ):
                    result.error(
                        check_id,
                        "FAIL_CAPABILITY_EVIDENCE_SCOPE",
                        f"{table} may bind only Codex certification, not negotiation/native snapshot identity",
                        relative,
                    )
            materialization_table = f"{prefix}timeline_materialization"
            if materialization_table in tables:
                materialization_columns = {
                    row[1] for row in sqlite_introspection(
                        connection, "table_info", materialization_table
                    )
                }
                if not {
                    "verification_receipt_id", "verification_receipt_digest"
                }.issubset(materialization_columns):
                    result.error(
                        check_id,
                        "FAIL_MATERIALIZATION_VERIFIER_RECEIPT",
                        f"{materialization_table} must strongly bind receipt identity/digest",
                        relative,
                    )
            receipt_table = f"{prefix}materialization_verification_receipt"
            if receipt_table in tables:
                receipt_columns = {
                    row[1] for row in sqlite_introspection(
                        connection, "table_info", receipt_table
                    )
                }
                required_receipt_columns = {
                    "algorithm_version", "receipt_id", "bridge_identity_id",
                    "bridge_instance_id", "codex_source_id", "materialization_id",
                    "begin_header_digest", "base_head_version",
                    "candidate_head_version",
                    "read_spec_digest", "read_evidence_digest",
                    "codex_certification_id", "codex_certification_digest",
                    "order_digest", "coverage_digest", "manifest_digest",
                    "verification_result", "receipt_digest",
                }
                forbidden_component_digest_columns = {
                    "page_manifest_digest", "session_manifest_digest",
                    "turn_graph_digest", "item_graph_digest",
                    "order_proof_set_digest", "island_graph_digest",
                    "gap_graph_digest",
                }
                if (
                    not required_receipt_columns.issubset(receipt_columns)
                    or forbidden_component_digest_columns & receipt_columns
                ):
                    result.error(
                        check_id,
                        "FAIL_MATERIALIZATION_VERIFIER_RECEIPT",
                        f"{receipt_table} lacks independently recomputable receipt columns",
                        relative,
                    )
            expected_state_vocabularies: dict[tuple[str, str], set[str]] = {
                (f"{prefix}catalog_head", "state"): {
                    "ABSENT", "PRESENT"
                },
                (f"{prefix}timeline_head", "state"): {
                    "ABSENT", "PRESENT", "TOMBSTONED_PROVEN"
                },
                (f"{prefix}timeline_materialization", "state"): {
                    "STAGING", "SEALED", "REJECTED", "QUARANTINED"
                },
            }
            if path.name == "bridge-v1.sql":
                expected_state_vocabularies[("content_offer", "state")] = {
                    "OFFERED", "TRANSFERRING", "VERIFYING", "FINALIZING",
                    "FINALIZED", "FAILED", "CANCELLED", "EXPIRED",
                }
            else:
                expected_state_vocabularies[("inbox_event", "apply_state")] = {
                    "RECEIVED", "STAGED", "APPLIED", "READBACK_VERIFIED",
                    "PUBLISHED", "ACKED", "REJECTED", "SNAPSHOT_REQUIRED",
                }
            for (table, column), expected_states in expected_state_vocabularies.items():
                row = connection.execute(
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
                    (table,),
                ).fetchone()
                definition = row[0] if row and isinstance(row[0], str) else ""
                match = re.search(
                    rf"(?is)\b{re.escape(column)}\s+TEXT\b.*?"
                    rf"CHECK\s*\(\s*{re.escape(column)}\s+IN\s*\(([^)]*)\)",
                    definition,
                )
                actual_states = set(re.findall(r"'([^']+)'", match.group(1))) if match else set()
                if actual_states != expected_states:
                    result.error(
                        check_id,
                        "FAIL_DDL_STATE_VOCABULARY",
                        f"{table}.{column} states differ; expected={sorted(expected_states)}, actual={sorted(actual_states)}",
                        relative,
                    )
            trigger_names = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='trigger'"
                )
            }
            content_ref_trigger_sql = [
                str(row[0] or "")
                for row in connection.execute(
                    "SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name=?",
                    (content_ref_table,),
                )
            ]
            if (
                content_ref_table in tables
                and (
                    not any(re.search(r"(?i)BEFORE\s+UPDATE", sql) for sql in content_ref_trigger_sql)
                    or not any(re.search(r"(?i)BEFORE\s+DELETE", sql) for sql in content_ref_trigger_sql)
                )
            ):
                result.error(
                    check_id,
                    "FAIL_CONTENT_REF_IMMUTABILITY",
                    f"{content_ref_table} must reject every post-insert update/delete",
                    relative,
                )
            def trigger_edges(trigger_name: str, column: str) -> set[tuple[str, str]]:
                row = connection.execute(
                    "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?",
                    (trigger_name,),
                ).fetchone()
                definition = row[0] if row and isinstance(row[0], str) else ""
                return extract_sql_trigger_edges(definition, column)

            catalog_trigger = f"{prefix}catalog_head_transition_cas"
            expected_catalog_edges = {
                ("ABSENT", "PRESENT"), ("PRESENT", "PRESENT"),
            }
            if trigger_edges(catalog_trigger, "state") != expected_catalog_edges:
                result.error(
                    check_id,
                    "FAIL_DDL_STATE_EDGE_BINDING",
                    "catalog head edges differ from SM-CATALOG-HEAD",
                    relative,
                )
            timeline_trigger = f"{prefix}timeline_head_atomic_commit_guard"
            expected_timeline_edges = {
                ("ABSENT", "PRESENT"), ("PRESENT", "PRESENT"),
                ("PRESENT", "TOMBSTONED_PROVEN"),
            }
            if trigger_edges(timeline_trigger, "state") != expected_timeline_edges:
                result.error(
                    check_id,
                    "FAIL_DDL_STATE_EDGE_BINDING",
                    "timeline head edges differ from SM-TIMELINE-HEAD",
                    relative,
                )
            expected_materialization_edges = {
                ("STAGING", "SEALED"),
                ("STAGING", "REJECTED"),
                ("STAGING", "QUARANTINED"),
            }
            if trigger_edges(
                f"{prefix}materialization_state_transition", "state"
            ) != expected_materialization_edges:
                result.error(
                    check_id,
                    "FAIL_DDL_STATE_EDGE_BINDING",
                    "materialization edges differ from SM-MATERIALIZATION",
                    relative,
                )

            if path.name == "bridge-v1.sql":
                expected_offer_edges = {
                    ("OFFERED", "TRANSFERRING"),
                    ("TRANSFERRING", "VERIFYING"),
                    ("VERIFYING", "FINALIZING"),
                    ("FINALIZING", "FINALIZED"),
                    *((source, target) for source in ("OFFERED", "TRANSFERRING", "VERIFYING") for target in ("FAILED", "CANCELLED", "EXPIRED")),
                    ("FINALIZING", "FAILED"),
                }
                actual_offer_edges = trigger_edges("content_offer_transition", "state")
                if actual_offer_edges != expected_offer_edges:
                    result.error(
                        check_id,
                        "FAIL_DDL_STATE_EDGE_BINDING",
                        "content_offer_transition edges differ from SM-CONTENT-OFFER",
                        relative,
                    )
            else:
                expected_replica_edges = {
                    ("RECEIVED", "STAGED"),
                    ("STAGED", "APPLIED"),
                    ("APPLIED", "READBACK_VERIFIED"),
                    ("READBACK_VERIFIED", "PUBLISHED"),
                    ("PUBLISHED", "ACKED"),
                    *((source, target) for source in ("RECEIVED", "STAGED", "APPLIED", "READBACK_VERIFIED", "PUBLISHED") for target in ("REJECTED", "SNAPSHOT_REQUIRED")),
                }
                actual_replica_edges = trigger_edges("inbox_apply_transition", "apply_state")
                if actual_replica_edges != expected_replica_edges:
                    result.error(
                        check_id,
                        "FAIL_DDL_STATE_EDGE_BINDING",
                        "inbox_apply_transition edges differ from SM-REPLICA-APPLY",
                        relative,
                    )
            required_trigger_groups = (
                ({f"{prefix}materialization_seal_guard"}, "seal-once materialization guard"),
                ({f"{prefix}materialization_state_transition"}, "materialization edge guard"),
                (
                    {f"{prefix}materialization_fields_immutable", f"{prefix}materialization_immutable_fields"},
                    "materialization immutable-parent guard",
                ),
            )
            for alternatives, purpose in required_trigger_groups:
                if not alternatives & trigger_names:
                    result.error(
                        check_id,
                        "FAIL_DDL_STATE_EDGE_BINDING",
                        f"DDL lacks {purpose}",
                        relative,
                    )
            if path.name == "mobile-v1.sql":
                for trigger in (
                    "inbox_apply_transition",
                    "inbox_event_identity_body_immutable",
                    "inbox_event_post_readback_immutable",
                ):
                    if trigger not in trigger_names:
                        result.error(
                            check_id,
                            "FAIL_DDL_STATE_EDGE_BINDING",
                            f"Mobile DDL lacks required inbox guard {trigger}",
                            relative,
                        )
            foreign = sqlite_introspection(connection, "foreign_key_check")
            if foreign:
                result.error(
                    check_id,
                    "FAIL_SQLITE_FOREIGN_KEY_CHECK",
                    f"foreign_key_check returned {len(foreign)} rows",
                    relative,
                )
            quick = [
                row[0]
                for row in sqlite_introspection(connection, "quick_check")
            ]
            if quick != ["ok"]:
                result.error(
                    check_id,
                    "FAIL_SQLITE_QUICK_CHECK",
                    f"quick_check returned {quick!r}",
                    relative,
                )
        except (OSError, UnicodeError, sqlite3.Error, ValueError) as exc:
            result.error(
                check_id,
                "FAIL_SQLITE_DDL_LOAD",
                f"fresh in-memory DDL load failed: {exc}",
                relative,
            )
        finally:
            connection.close()
    return {"ddl_files": len(paths), "database": ":memory:"}


def check_sql_negative_vectors(
    result: ValidationResult,
    check_id: str,
    final_config: Mapping[str, Any],
) -> Mapping[str, Any]:
    relative = str(final_config["vector_source"])
    path = result.design_root / relative
    try:
        document = parse_json_file(path)
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError) as exc:
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REGISTRY_PARSE",
            f"negative-vector registry cannot be parsed: {exc}",
            relative,
        )
        return {"vectors": 0}
    if not isinstance(document, dict):
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REGISTRY_STRUCTURE",
            "contract vector source must be an object",
            relative,
        )
        return {"vectors": 0}
    vectors = document.get("sqlVectors")
    if not isinstance(vectors, list) or not vectors:
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REGISTRY_STRUCTURE",
            "sqlVectors must be a nonempty array",
            relative,
        )
        return {"vectors": 0}
    ids: list[str] = []
    database_paths = {
        Path(value).stem.removesuffix("-v1"): result.design_root / str(value)
        for value in final_config["ddl_files"]
    }
    for index, vector in enumerate(vectors):
        artifact = f"{relative}#sqlVectors/{index}"
        if not isinstance(vector, dict):
            result.error(
                check_id,
                "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE",
                "vector must be an object",
                artifact,
            )
            continue
        vector_id = vector.get("id")
        database = vector.get("database")
        statement = vector.get("statement")
        steps = vector.get("steps")
        expected_reason = vector.get("expectedReason")
        if not isinstance(vector_id, str) or not vector_id.strip():
            result.error(
                check_id,
                "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE",
                "id must be a nonblank string",
                artifact,
            )
            continue
        ids.append(vector_id)
        if (
            not isinstance(database, str)
            or database not in database_paths
            or (not isinstance(statement, str) and not isinstance(steps, list))
            or not isinstance(vector.get("setupFixture"), str)
            or not isinstance(expected_reason, str)
            or not expected_reason
            or not isinstance(vector.get("expectedConstraint"), str)
            or not isinstance(vector.get("postconditions"), list)
        ):
            result.error(
                check_id,
                "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE",
                "database/setupFixture/statement-or-steps/expectedReason/expectedConstraint/postconditions is invalid",
                artifact,
            )
            continue
        ddl_path = database_paths[database]
        if not ddl_path.is_file() or ddl_path.is_symlink():
            result.error(check_id, MISSING, f"negative vector DDL is missing: {ddl_path.name}", artifact)
            continue
        error_code, message = execute_registered_sql_vector(ddl_path, vector)
        if error_code is not None:
            result.error(check_id, error_code, f"{vector_id} {message}", artifact)
    if len(ids) != len(set(ids)):
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_DUPLICATE_ID",
            "negative-vector ids are not unique",
            relative,
        )
    missing_ids = sorted(REQUIRED_SQL_VECTOR_IDS - set(ids))
    if missing_ids:
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REQUIRED_IDS",
            f"missing required negative vectors: {', '.join(missing_ids)}",
            relative,
        )
    return {
        "database": ":memory:",
        "required_ids": len(REQUIRED_SQL_VECTOR_IDS),
        "vectors": len(vectors),
    }


def check_final_matrices(
    result: ValidationResult,
    check_id: str,
    tables: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    final_tables = [config for config in tables if config.get("modes") == ["final"]]
    for raw_config in final_tables:
        config = dict(raw_config)
        config.setdefault("min_columns", len(config.get("required_columns", [])))
        config["exact_header"] = config.get("required_columns", [])
        relative = str(config["path"])
        errors = validate_csv_table(result.design_root / relative, config)
        for error in errors:
            result.error(check_id, error["code"], error["message"], relative)
    try:
        with (result.design_root / "matrices/DECISION-LEDGER.csv").open(
            "r", encoding="utf-8-sig", newline=""
        ) as handle:
            decision_ids = {
                row["decision_id"] for row in csv.DictReader(handle, strict=True)
            }
        closure_id_sets: list[set[str]] = []
        for relative in (
            "matrices/DESIGN-CLOSURE.csv",
            "drafts/AUDIT-COVERAGE-CLOSURE.csv",
        ):
            with (result.design_root / relative).open(
                "r", encoding="utf-8-sig", newline=""
            ) as handle:
                closure_id_sets.append({
                    row["id"] for row in csv.DictReader(handle, strict=True)
                })
    except (OSError, UnicodeError, csv.Error, KeyError) as exc:
        result.error(
            check_id,
            "FAIL_CLOSURE_ID_NAMESPACE",
            f"cannot verify R48 decision/input closure namespaces: {exc}",
            "matrices",
        )
    else:
        root_decisions = {f"D-{index:03d}" for index in range(1, 16)}
        input_closures = {f"INPUT-D-{index:03d}" for index in range(1, 13)}
        if (
            not root_decisions.issubset(decision_ids)
            or any(input_closures != ids & input_closures for ids in closure_id_sets)
            or any(ids & root_decisions for ids in closure_id_sets)
            or closure_id_sets[0] != closure_id_sets[1]
        ):
            result.error(
                check_id,
                "FAIL_CLOSURE_ID_NAMESPACE",
                "R48 requires root D-001..015 decisions and distinct INPUT-D-001..012 closure IDs with exact authoritative/stale-view parity",
                "matrices/DESIGN-CLOSURE.csv",
            )
    host_map_relative = "evidence/I01-UPSTREAM-HOST-INTEGRATION-MAP.md"
    try:
        host_map = read_text(result.design_root / host_map_relative)
    except (OSError, UnicodeError) as exc:
        result.error(
            check_id,
            "FAIL_I01_HOST_INTEGRATION_MAP",
            f"cannot read I01 host map: {exc}",
            host_map_relative,
        )
    else:
        required_host_terms = (
            "docs/design/codex-kernel-v4/contracts/**",
            "packages/conversation-contract",
            "packages/bridge/src/conversation-core/protocol/generated/",
            "apps/mobile/lib/conversation_core/protocol/generated/",
            "machine source, generated TS and generated Dart share one exact source digest",
            "old handler inventory has zero diff and no new import/reachability",
            "packages/bridge/src/parser.ts",
            "packages/bridge/src/websocket.ts",
            "apps/mobile/lib/models/messages.dart",
            "apps/mobile/lib/services/bridge_service.dart",
            "apps/mobile/lib/services/chat_message_handler.dart",
            "apps/mobile/lib/features/file_upload/**",
            "apps/mobile/lib/services/replay_bridge_service.dart",
            "every Claude route/factory/default",
        )
        if not all(term in host_map for term in required_host_terms):
            result.error(
                check_id,
                "FAIL_I01_HOST_INTEGRATION_MAP",
                "R60 host map must freeze the unique source, final TS/Dart targets, source digest, and every zero-handler/import/reachability boundary",
                host_map_relative,
            )
    return {"matrices": len(final_tables)}


def check_no_symlinks(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    symlinks: list[str] = []
    for path in sorted(result.design_root.rglob("*")):
        if path.is_symlink():
            symlinks.append(path.relative_to(result.design_root).as_posix())
    for relative in symlinks:
        result.error(
            check_id,
            "FAIL_SYMLINK",
            "final design tree may not contain symlinks",
            relative,
        )
    return {"symlinks": len(symlinks)}


def check_i01_host_boundaries(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    host_map_relative = "evidence/I01-UPSTREAM-HOST-INTEGRATION-MAP.md"
    host_map = read_text(result.design_root / host_map_relative)
    match = re.search(r"(?m)^- HEAD: `([0-9a-f]{40})`$", host_map)
    expected_base = "abe0bc83956ec966d895daa393baf82848fb6cce"
    if match is None or match.group(1) != expected_base:
        result.error(
            check_id,
            "FAIL_I01_HOST_BASE_IDENTITY",
            "I01 host evidence must retain the exact upstream base commit",
            host_map_relative,
        )
        return {"base": match.group(1) if match else None, "paths": 0}
    fixed_paths = {
        "packages/bridge/src/parser.ts",
        "packages/bridge/src/websocket.ts",
        "packages/bridge/src/index.ts",
        "packages/bridge/src/sdk-process.ts",
        "packages/bridge/src/session.ts",
        "packages/bridge/src/sessions-index.ts",
        "apps/mobile/lib/models/messages.dart",
        "apps/mobile/lib/services/bridge_service.dart",
        "apps/mobile/lib/services/chat_message_handler.dart",
        "apps/mobile/lib/services/replay_bridge_service.dart",
    }
    try:
        listed = subprocess.run(
            [
                "git", "-C", str(result.root), "ls-tree", "-r", "--name-only",
                expected_base,
            ],
            check=True,
            capture_output=True,
            timeout=15,
        ).stdout.decode("utf-8", "strict").splitlines()
    except (FileNotFoundError, UnicodeError, subprocess.SubprocessError) as exc:
        result.error(
            check_id,
            "FAIL_I01_HOST_BASE_IDENTITY",
            f"cannot enumerate upstream host base: {exc}",
            host_map_relative,
        )
        return {"base": expected_base, "paths": 0}
    fixed_paths.update(
        path for path in listed
        if path.startswith("apps/mobile/lib/features/file_upload/")
        or (
            path.startswith("packages/bridge/src/")
            and ("claude" in path.lower() or "upload" in path.lower())
        )
    )
    drift: list[str] = []
    for relative in sorted(fixed_paths):
        candidate = result.root / relative
        try:
            base_bytes = subprocess.run(
                ["git", "-C", str(result.root), "show", f"{expected_base}:{relative}"],
                check=True,
                capture_output=True,
                timeout=10,
            ).stdout
        except (FileNotFoundError, subprocess.SubprocessError):
            base_bytes = None
        current_bytes = candidate.read_bytes() if candidate.is_file() else None
        if base_bytes is None or current_bytes != base_bytes:
            drift.append(relative)
    current_file_upload = {
        path.relative_to(result.root).as_posix()
        for path in (result.root / "apps/mobile/lib/features/file_upload").rglob("*")
        if path.is_file() and not path.is_symlink()
    } if (result.root / "apps/mobile/lib/features/file_upload").is_dir() else set()
    expected_file_upload = {
        path for path in fixed_paths
        if path.startswith("apps/mobile/lib/features/file_upload/")
    }
    if current_file_upload != expected_file_upload:
        drift.extend(sorted(current_file_upload ^ expected_file_upload))
    if drift:
        result.error(
            check_id,
            "FAIL_I01_ZERO_HANDLER_BOUNDARY",
            "R60 legacy handler/import/reachability boundary differs from the exact upstream base: "
            + ", ".join(sorted(set(drift))[:20]),
            host_map_relative,
        )
    return {"base": expected_base, "paths": len(fixed_paths)}


def check_git_design_clean(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    scope_paths = [
        "docs/design/codex-kernel-v4",
        *(value.rstrip("/") for value in FIXED_GENERATED_TARGET_ROOTS),
    ]
    try:
        completed = subprocess.run(
            [
                "git", "-C", str(result.root), "status", "--porcelain=v1",
                "--untracked-files=all", "--", *scope_paths,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.SubprocessError) as exc:
        result.error(
            check_id,
            "FAIL_GIT_IDENTITY_REQUIRED",
            f"final design identity requires Git: {exc}",
        )
        return {"dirty_paths": 0}
    dirty: list[str] = []
    for line in completed.stdout.splitlines():
        dirty.append(line)
    if dirty:
        result.error(
            check_id,
            "FAIL_DIRTY_DESIGN_TREE",
            "final design artifacts are not represented by the reported HEAD/tree: "
            + "; ".join(dirty),
            "docs/design/codex-kernel-v4",
        )
    return {"dirty_paths": len(dirty)}


def collect_artifact_hashes(design_root: Path) -> dict[str, dict[str, Any]]:
    hashes: dict[str, dict[str, Any]] = {}
    for path in sorted(design_root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(design_root).as_posix()
        hashes[relative] = {"sha256": sha256_file(path), "size": path.stat().st_size}
    manifest_path = design_root / "contracts/CONTRACT-MANIFEST.json"
    try:
        manifest = parse_json_file(manifest_path)
    except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError):
        manifest = {}
    repo_root = design_root.parents[2]
    if isinstance(manifest, dict):
        for target in manifest.get("generatedTargets", ()):
            if not isinstance(target, dict):
                continue
            for entry in target.get("files", ()):
                if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                    continue
                raw_path = entry["path"]
                if (
                    Path(raw_path).is_absolute()
                    or "\\" in raw_path
                    or raw_path != "/".join(Path(raw_path).parts)
                    or any(part in {"", ".", ".."} for part in raw_path.split("/"))
                ):
                    continue
                lexical_candidate = repo_root / raw_path
                candidate = lexical_candidate.resolve(strict=False)
                if (
                    is_within(candidate, repo_root)
                    and not path_has_symlink_component(lexical_candidate, repo_root)
                    and candidate.is_file()
                    and not candidate.is_symlink()
                ):
                    hashes[entry["path"]] = {
                        "sha256": sha256_file(candidate),
                        "size": candidate.stat().st_size,
                    }
    return hashes


def check_git_hash_closure(
    result: ValidationResult,
    check_id: str,
    artifact_hashes: Mapping[str, Mapping[str, Any]],
) -> Mapping[str, Any]:
    scope_paths = [
        "docs/design/codex-kernel-v4",
        *(value.rstrip("/") for value in FIXED_GENERATED_TARGET_ROOTS),
    ]

    def current_identity() -> tuple[str, str]:
        head = subprocess.run(
            ["git", "-C", str(result.root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        tree = subprocess.run(
            ["git", "-C", str(result.root), "rev-parse", "HEAD^{tree}"],
            check=True, capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        return head, tree

    def dirty_lines() -> list[str]:
        return subprocess.run(
            [
                "git", "-C", str(result.root), "status", "--porcelain=v1",
                "--untracked-files=all", "--", *scope_paths,
            ],
            check=True, capture_output=True, text=True, timeout=15,
        ).stdout.splitlines()

    try:
        head, tree = current_identity()
        before_dirty = dirty_lines()
        if head != result.head or tree != result.tree:
            result.error(
                check_id, "FAIL_GIT_IDENTITY_DRIFT",
                "HEAD/tree changed after validation checks",
                "docs/design/codex-kernel-v4",
            )
        if before_dirty:
            result.error(
                check_id, "FAIL_DIRTY_DESIGN_TREE",
                "design/generated paths changed before hash closure: "
                + "; ".join(before_dirty),
                "docs/design/codex-kernel-v4",
            )
        compared = 0
        for key, expected in sorted(artifact_hashes.items()):
            repo_relative = (
                key
                if key.startswith(("packages/", "apps/"))
                else f"docs/design/codex-kernel-v4/{key}"
            )
            tracked = subprocess.run(
                [
                    "git", "-C", str(result.root), "ls-files",
                    "--error-unmatch", "--", repo_relative,
                ],
                capture_output=True, timeout=10,
            )
            if tracked.returncode != 0:
                result.error(
                    check_id, "FAIL_GIT_BLOB_CLOSURE",
                    f"artifact is not tracked at reported HEAD: {repo_relative}",
                    repo_relative,
                )
                continue
            blob = subprocess.run(
                ["git", "-C", str(result.root), "show", f"HEAD:{repo_relative}"],
                check=True, capture_output=True, timeout=20,
            ).stdout
            if (
                len(blob) != expected.get("size")
                or hashlib.sha256(blob).hexdigest() != expected.get("sha256")
            ):
                result.error(
                    check_id, "FAIL_GIT_BLOB_CLOSURE",
                    f"artifact bytes differ from reported HEAD: {repo_relative}",
                    repo_relative,
                )
            compared += 1
        second_hashes = collect_artifact_hashes(result.design_root)
        after_head, after_tree = current_identity()
        after_dirty = dirty_lines()
        if second_hashes != dict(artifact_hashes):
            result.error(
                check_id, "FAIL_ARTIFACT_HASH_DRIFT",
                "artifact inventory/bytes changed during validation",
                "docs/design/codex-kernel-v4",
            )
        if (
            after_head != result.head
            or after_tree != result.tree
            or after_dirty
        ):
            result.error(
                check_id, "FAIL_GIT_IDENTITY_DRIFT",
                "HEAD/tree/design status changed during hash closure"
                + (f": {'; '.join(after_dirty)}" if after_dirty else ""),
                "docs/design/codex-kernel-v4",
            )
    except (FileNotFoundError, UnicodeError, subprocess.SubprocessError) as exc:
        result.error(
            check_id, "FAIL_GIT_BLOB_CLOSURE",
            f"cannot bind artifact hashes to HEAD blobs: {exc}",
            "docs/design/codex-kernel-v4",
        )
        return {"files": 0}
    return {"files": compared}


def write_report(path: Path, document: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError("report target became a symlink or non-file")
    encoded = json.dumps(
        document, ensure_ascii=False, indent=2, sort_keys=True
    ) + "\n"
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".tmp", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        if path.is_symlink():
            raise ValueError("report target became a symlink")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def validate(mode: str, root: Path, report_path: Path) -> tuple[int, dict[str, Any]]:
    root = root.expanduser().resolve()
    normalized_report = normalize_report_path(root, report_path)
    design_root = root / "docs/design/codex-kernel-v4"
    result = ValidationResult(root, design_root, mode, normalized_report)

    try:
        details = git_identity(result, "git_identity")
    except RuntimeError as exc:
        if mode == "final":
            result.error(
                "git_identity",
                "FAIL_GIT_IDENTITY_REQUIRED",
                f"final validation requires Git identity: {exc}",
            )
            result.checks.append(
                {"details": {}, "id": "git_identity", "status": FAIL}
            )
        else:
            result.not_run("git_identity", f"Git identity unavailable: {exc}")
    else:
        result.checks.append({"details": details, "id": "git_identity", "status": PASS})

    inventory_box: dict[str, Any] = {}

    def inventory_callback(check_id: str) -> Mapping[str, Any]:
        inventory, details = load_inventory(result, check_id)
        inventory_box["value"] = inventory
        return details

    inventory_ok = result.run("inventory", inventory_callback)
    inventory = inventory_box.get("value")
    if not inventory_ok or not isinstance(inventory, dict):
        for check_id in (
            "preflight_artifacts",
            "csv_contracts",
            "source_references",
            "markdown_references",
            "identity_contracts",
            "actor_writer_aliases",
            "phase2_candidate_binding",
            "reachable_legacy_markers",
            "control_budgets",
            "file_transfer_naming",
            "r14_operation_preflight",
        ):
            result.not_run(check_id, "inventory unavailable")
        if mode == "final":
            for check_id in (
                "final_artifact_inventory",
                "full_design",
                "contract_manifest",
                "i01_generated_targets",
                "contract_registry",
                "json_schema_structure",
                "contract_vectors",
                "sqlite_fresh_load",
                "sqlite_negative_vectors",
                "final_matrices",
                "i01_host_boundaries",
                "final_symlinks",
                "git_design_tree",
                "r14_machine_contracts",
            ):
                result.not_run(check_id, "inventory unavailable")
    else:
        result.run(
            "preflight_artifacts",
            lambda check_id: check_required_files(
                result, check_id, inventory["preflight_required_files"]
            ),
        )
        result.run(
            "csv_contracts",
            lambda check_id: check_csv_tables(
                result, check_id, inventory["csv_tables"]
            ),
        )
        result.run(
            "source_references",
            lambda check_id: check_source_references(
                result, check_id, inventory["source_reference_columns"]
            ),
        )
        result.run("markdown_references", lambda check_id: check_markdown_references(result, check_id))
        result.run("identity_contracts", lambda check_id: check_identity_contracts(result, check_id))
        result.run("actor_writer_aliases", lambda check_id: check_aliases(result, check_id))
        result.run(
            "phase2_candidate_binding",
            lambda check_id: check_phase2_candidate_binding(
                result, check_id, inventory["phase2_files"]
            ),
        )
        result.run(
            "reachable_legacy_markers",
            lambda check_id: check_legacy_markers(result, check_id),
        )
        result.run(
            "control_budgets",
            lambda check_id: check_budgets(
                result, check_id, inventory["control_budgets_bytes"]
            ),
        )
        result.run("file_transfer_naming", lambda check_id: check_ft_naming(result, check_id))
        result.run(
            "r14_operation_preflight",
            lambda check_id: check_r14_operation_preflight(result, check_id),
        )

        if mode == "final":
            final_config = inventory["final"]
            final_ok = result.run(
                "final_artifact_inventory",
                lambda check_id: check_final_inventory(result, check_id, final_config),
            )
            if final_ok:
                result.run(
                    "full_design",
                    lambda check_id: check_full_design(result, check_id),
                )
                result.run(
                    "contract_manifest",
                    lambda check_id: check_contract_manifest(result, check_id, final_config),
                )
                try:
                    manifest_document = parse_json_file(
                        result.design_root / "contracts/CONTRACT-MANIFEST.json"
                    )
                except (OSError, UnicodeError, json.JSONDecodeError, StrictJsonError):
                    result.not_run(
                        "i01_generated_targets",
                        "contract manifest is unavailable or invalid",
                    )
                else:
                    if (
                        isinstance(manifest_document, dict)
                        and manifest_document.get("implementationReady") is False
                        and manifest_document.get("generatedTargets") == []
                    ):
                        result.not_run(
                            "i01_generated_targets",
                            "DESIGN_SOURCE_READY: implementationReady=false and "
                            "generatedTargets=[]",
                        )
                    else:
                        result.run(
                            "i01_generated_targets",
                            lambda check_id: check_generated_targets(
                                result, check_id
                            ),
                        )
                result.run(
                    "contract_registry",
                    lambda check_id: check_contract_registry(
                        result, check_id, final_config
                    ),
                )
                result.run(
                    "json_schema_structure",
                    lambda check_id: check_json_schemas(result, check_id),
                )
                result.run(
                    "contract_vectors",
                    lambda check_id: check_contract_vectors(result, check_id, final_config),
                )
                result.run(
                    "sqlite_fresh_load",
                    lambda check_id: check_sqlite_ddl(result, check_id, final_config),
                )
                result.run(
                    "sqlite_negative_vectors",
                    lambda check_id: check_sql_negative_vectors(
                        result, check_id, final_config
                    ),
                )
                result.run(
                    "final_matrices",
                    lambda check_id: check_final_matrices(
                        result, check_id, inventory["csv_tables"]
                    ),
                )
                result.run(
                    "i01_host_boundaries",
                    lambda check_id: check_i01_host_boundaries(result, check_id),
                )
                result.run(
                    "final_symlinks", lambda check_id: check_no_symlinks(result, check_id)
                )
                result.run(
                    "git_design_tree", lambda check_id: check_git_design_clean(result, check_id)
                )
                result.run(
                    "r14_machine_contracts",
                    lambda check_id: check_r14_machine_contracts(result, check_id),
                )
            else:
                reason = "required final artifacts are missing or invalid"
                for check_id in (
                    "full_design",
                    "contract_manifest",
                    "i01_generated_targets",
                    "contract_registry",
                    "json_schema_structure",
                    "contract_vectors",
                    "sqlite_fresh_load",
                    "sqlite_negative_vectors",
                    "final_matrices",
                    "i01_host_boundaries",
                    "final_symlinks",
                    "git_design_tree",
                    "r14_machine_contracts",
                ):
                    result.not_run(check_id, reason)
        else:
            for check_id in (
                "final_artifact_inventory",
                "full_design",
                "contract_manifest",
                "i01_generated_targets",
                "contract_registry",
                "json_schema_structure",
                "contract_vectors",
                "sqlite_fresh_load",
                "sqlite_negative_vectors",
                "final_matrices",
                "i01_host_boundaries",
                "final_symlinks",
                "git_design_tree",
                "r14_machine_contracts",
            ):
                result.not_run(check_id, "final-only check is not applicable in preflight mode")

    artifact_hashes = (
        collect_artifact_hashes(design_root)
        if design_root.is_dir()
        else {}
    )
    if mode == "final":
        result.run(
            "git_hash_closure",
            lambda check_id: check_git_hash_closure(
                result, check_id, artifact_hashes
            ),
        )
    else:
        result.not_run(
            "git_hash_closure", "final-only check is not applicable in preflight mode"
        )
    document = result.document(artifact_hashes)
    return (0 if document["overall_status"] == PASS else 1), document


def run_self_test() -> int:
    cases: list[dict[str, Any]] = []

    def record(case_id: str, expected: str, observed: Iterable[str]) -> None:
        codes = sorted(set(observed))
        cases.append(
            {
                "expected_error": expected,
                "id": case_id,
                "observed_errors": codes,
                "status": PASS if expected in codes else FAIL,
            }
        )

    def record_clean(case_id: str, observed: Iterable[str]) -> None:
        codes = sorted(set(observed))
        cases.append(
            {
                "expected_error": None,
                "id": case_id,
                "observed_errors": codes,
                "status": PASS if not codes else FAIL,
            }
        )

    with tempfile.TemporaryDirectory(prefix="codex-kernel-v4-validator-") as raw:
        temp = Path(raw)
        base_config = {
            "id_column": "id",
            "row_count": 2,
            "min_columns": 2,
            "required_columns": ["id", "value"],
            "id_sequence": [
                {"prefix": "T-", "start": 1, "end": 2, "width": 3}
            ],
        }

        clean = temp / "clean.csv"
        clean.write_text("id,value\nT-001,one\nT-002,two\n", encoding="utf-8")
        record_clean(
            "clean_csv_contract",
            (item["code"] for item in validate_csv_table(clean, base_config)),
        )

        duplicate = temp / "duplicate.csv"
        duplicate.write_text("id,value\nT-001,one\nT-001,two\n", encoding="utf-8")
        record(
            "duplicate_id",
            "FAIL_CSV_DUPLICATE_ID",
            (item["code"] for item in validate_csv_table(duplicate, base_config)),
        )

        blank = temp / "blank.csv"
        blank.write_text("id,value\nT-001,one\nT-002,\n", encoding="utf-8")
        record(
            "blank_cell",
            "FAIL_CSV_BLANK_CELL",
            (item["code"] for item in validate_csv_table(blank, base_config)),
        )

        record(
            "bad_source_partition",
            "FAIL_SOURCE_PARTITION",
            (
                item["code"]
                for item in identity_errors(
                    "SourcePartition=(bridgeInstanceId,codexSourceId)"
                )
            ),
        )

        record(
            "oversize_control_budget",
            "FAIL_CONTROL_BUDGET_OVERSIZE",
            (
                item["code"]
                for item in budget_errors("control envelope <= 65,537 bytes")
            ),
        )

        missing_config = {
            "required_files": ["drafts/FULL-DESIGN-SYNTHESIS.md"],
            "required_globs": [],
        }
        missing = final_missing_artifacts(temp, missing_config)
        record(
            "missing_final_artifact",
            MISSING,
            [MISSING] if "drafts/FULL-DESIGN-SYNTHESIS.md" in missing else [],
        )

        audited_root = temp / "audited-root"
        audited_root.mkdir()
        try:
            normalize_report_path(audited_root, audited_root / "report.json")
        except ValueError:
            report_boundary_errors = ["FAIL_REPORT_PATH_BOUNDARY"]
        else:
            report_boundary_errors = []
        record(
            "report_inside_audited_root",
            "FAIL_REPORT_PATH_BOUNDARY",
            report_boundary_errors,
        )
        record_clean(
            "report_outside_audited_root",
            []
            if normalize_report_path(audited_root, temp / "external-report.json")
            == (temp / "external-report.json").resolve()
            else ["FAIL_REPORT_PATH_BOUNDARY"],
        )

        lifecycle_root = (temp / "manifest-lifecycle-root").resolve()
        lifecycle_design = lifecycle_root / "docs/design/codex-kernel-v4"
        lifecycle_contracts = lifecycle_design / "contracts"
        lifecycle_contracts.mkdir(parents=True)
        lifecycle_registry = lifecycle_contracts / "contract-registry.json"
        lifecycle_registry.write_text("{}\n", encoding="utf-8")
        (lifecycle_contracts / "README.md").write_text(
            "NON_NORMATIVE_REVIEW_VIEW; cannot override machine sources.\n",
            encoding="utf-8",
        )
        lifecycle_member = {
            "path": "contract-registry.json",
            "bytes": lifecycle_registry.stat().st_size,
            "sha256": sha256_file(lifecycle_registry),
        }
        lifecycle_base = {
            "contractSet": "ccpocket.codex.kernel/1/revision-1",
            "algorithm": "sha256",
            "members": [lifecycle_member],
            "contractSetDigest": hashlib.sha256(
                stable_json({"members": [lifecycle_member]}).encode("utf-8")
            ).hexdigest(),
        }
        lifecycle_path = lifecycle_contracts / "CONTRACT-MANIFEST.json"
        lifecycle_config = {
            "machine_source": "contracts/contract-registry.json"
        }

        lifecycle_path.write_text(
            json.dumps({
                **lifecycle_base,
                "implementationReady": False,
                "generatedTargets": [],
            }),
            encoding="utf-8",
        )
        source_stage_result = ValidationResult(
            lifecycle_root, lifecycle_design, "final", temp / "unused.json"
        )
        source_stage_details = check_contract_manifest(
            source_stage_result, "manifest", lifecycle_config
        )
        record_clean(
            "manifest_design_source_ready_false_empty",
            [error["code"] for error in source_stage_result.errors]
            + ([] if source_stage_details.get("readiness") == "DESIGN_SOURCE_READY"
               else ["FAIL_CONTRACT_MANIFEST_LIFECYCLE"]),
        )

        lifecycle_path.write_text(
            json.dumps(lifecycle_base), encoding="utf-8"
        )
        missing_lifecycle_result = ValidationResult(
            lifecycle_root, lifecycle_design, "final", temp / "unused.json"
        )
        check_contract_manifest(
            missing_lifecycle_result, "manifest", lifecycle_config
        )
        record(
            "manifest_missing_lifecycle_fields",
            "FAIL_CONTRACT_MANIFEST_STRUCTURE",
            (error["code"] for error in missing_lifecycle_result.errors),
        )

        lifecycle_path.write_text(
            json.dumps({
                **lifecycle_base,
                "implementationReady": True,
                "generatedTargets": [],
            }),
            encoding="utf-8",
        )
        empty_i01_result = ValidationResult(
            lifecycle_root, lifecycle_design, "final", temp / "unused.json"
        )
        check_contract_manifest(empty_i01_result, "manifest", lifecycle_config)
        record(
            "manifest_i01_true_empty_rejected",
            "FAIL_CONTRACT_MANIFEST_LIFECYCLE",
            (error["code"] for error in empty_i01_result.errors),
        )

        generated_root = (temp / "generated-root").resolve()
        generated_design = generated_root / "docs/design/codex-kernel-v4"
        (generated_design / "contracts").mkdir(parents=True)
        source_digest = "a" * 64
        generated_targets: list[dict[str, Any]] = []
        for language, target_root, filename in (
            (
                "TYPESCRIPT", FIXED_GENERATED_TARGET_ROOTS[0],
                "contract.generated.ts",
            ),
            (
                "DART", FIXED_GENERATED_TARGET_ROOTS[1],
                "contract_generated.dart",
            ),
        ):
            path = generated_root / target_root / filename
            path.parent.mkdir(parents=True)
            content = (
                f"// DO NOT EDIT; sourceDigest={source_digest}\n"
            ).encode("utf-8")
            path.write_bytes(content)
            generated_targets.append(
                {
                    "language": language,
                    "targetRoot": target_root,
                    "sourceDigest": source_digest,
                    "files": [{
                        "path": (Path(target_root) / filename).as_posix(),
                        "bytes": len(content),
                        "sha256": hashlib.sha256(content).hexdigest(),
                    }],
                }
            )
        (generated_design / "contracts/CONTRACT-MANIFEST.json").write_text(
            json.dumps({
                "contractSetDigest": source_digest,
                "implementationReady": True,
                "generatedTargets": generated_targets,
            }),
            encoding="utf-8",
        )
        generated_result = ValidationResult(
            generated_root, generated_design, "final", temp / "unused.json"
        )
        check_generated_targets(generated_result, "generated_targets")
        record(
            "generated_hashes_without_reproduction",
            "FAIL_GENERATED_TARGET_REPRODUCTION",
            (error["code"] for error in generated_result.errors),
        )

        def reproduce_generated_targets(replay_root: Path) -> None:
            for target in generated_targets:
                for entry in target["files"]:
                    destination = replay_root / entry["path"]
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(
                        f"// DO NOT EDIT; sourceDigest={source_digest}\n".encode(
                            "utf-8"
                        )
                    )

        replay_result = ValidationResult(
            generated_root, generated_design, "final", temp / "unused.json"
        )
        replay_details = check_generated_targets(
            replay_result, "generated_targets", reproduce_generated_targets
        )
        record_clean(
            "generated_exact_two_temp_replay",
            [error["code"] for error in replay_result.errors]
            + ([] if replay_details.get("readiness") == "I01_GENERATED_READY"
               else ["FAIL_GENERATED_TARGET_REPRODUCTION"]),
        )

        archive_design = temp / "archive-design"
        (archive_design / "drafts").mkdir(parents=True)
        (archive_design / "drafts/FULL-DESIGN-SYNTHESIS.md").write_text(
            "IMPLEMENTATION_READY / SOURCE_IMPLEMENTATION_AUTHORIZED / DELIVERY_NOT_AUTHORIZED\n"
            "SourcePartition OperationKey CanonicalTimelineWriter "
            "ReplicaApplyCoordinator OUTCOME_UNKNOWN FT/2 FT/3\n"
            "An audit package is required for completion.\n"
            + ("implementation-ready design body\n" * 180),
            encoding="utf-8",
        )
        archive_result = ValidationResult(
            temp, archive_design, "final", temp / "unused.json"
        )
        check_full_design(archive_result, "full_design")
        record(
            "forbidden_archive_gate",
            "FAIL_FORBIDDEN_ARCHIVE_GATE",
            (error["code"] for error in archive_result.errors),
        )

        semantic_path = temp / "P1-SEMANTIC-DICTIONARY.csv"
        semantic_path.write_text(
            "semantic_id,term,scope_and_fence\n"
            "SEM-005,FeatureCapabilitySnapshot,closed\n"
            "SEM-025,CanonicalFingerprint,final operation adds actor\n"
            "SEM-032,CapabilitySupport,closed\n"
            "SEM-052,CapabilityAvailability,closed\n"
            "SEM-053,CodexAdapterCertification,closed\n",
            encoding="utf-8",
        )
        record(
            "fingerprint_excluded_fields",
            "FAIL_FINGERPRINT_EXCLUDED_FIELDS",
            (
                item["code"]
                for item in validate_csv_table(
                    semantic_path,
                    {
                        "path": "drafts/P1-SEMANTIC-DICTIONARY.csv",
                        "id_column": "semantic_id",
                        "row_count": 5,
                        "min_columns": 3,
                        "required_columns": [
                            "semantic_id", "term", "scope_and_fence"
                        ],
                    },
                )
            ),
        )

        machine_root = (temp / "machine-root").resolve()
        machine_design = machine_root / "docs/design/codex-kernel-v4"
        (machine_design / "contracts").mkdir(parents=True)
        bad_operation = {
            "id": "OP-TEST",
            "queueLaneSelector": "global",
            "executionConflictSelectors": ["route"],
            "replayPolicy": "SAME_ID_RESEND_DISPATCH",
            "fallback": "legacy upload mutation fallback",
        }
        (machine_design / "contracts/contract-registry.json").write_text(
            json.dumps({"operations": [bad_operation]}), encoding="utf-8"
        )
        machine_result = ValidationResult(
            machine_root,
            machine_design,
            "final",
            machine_root / "report.json",
        )
        check_r14_machine_contracts(machine_result, "r14")
        machine_codes = [error["code"] for error in machine_result.errors]
        record(
            "r14_forbidden_lane",
            "FAIL_R14_FORBIDDEN_LANE_SCOPE",
            machine_codes,
        )
        record(
            "r14_same_id_redispatch",
            "FAIL_R14_SAME_ID_REDISPATCH",
            machine_codes,
        )
        record(
            "r14_legacy_upload_fallback",
            "FAIL_R14_LEGACY_UPLOAD_FALLBACK",
            machine_codes,
        )

        focused_result = ValidationResult(temp, temp, "final", temp / "unused.json")
        check_operation_schema_consistency(
            focused_result,
            "operation_schema",
            [
                {"id": "OP-001", "name": "DRIFTED_NAME", "exposure": "PUBLIC", "operationSchemaRef": "schema"},
                {"id": "OP-007", "name": "RETRY_OPERATION_TOMBSTONE", "exposure": "PUBLIC", "operationSchemaRef": None},
            ],
            {
                "$defs": {
                    "Operation_OP_001": {"properties": {"operationKind": {"const": "START_TURN"}}},
                    "PublicOperation": {"oneOf": [
                        {"$ref": "#/$defs/Operation_OP_001"},
                        {"$ref": "#/$defs/Operation_OP_007"},
                    ]},
                }
            },
            "operation.schema.json",
        )
        focused_codes = [error["code"] for error in focused_result.errors]
        record("operation_id_name_drift", "FAIL_OPERATION_ID_NAME_DRIFT", focused_codes)
        record("reserved_operation_in_public_union", "FAIL_PUBLIC_OPERATION_UNION", focused_codes)

        focused_px_result = ValidationResult(
            temp, temp, "final", temp / "unused.json"
        )
        check_operation_schema_consistency(
            focused_px_result,
            "product_operation_schema",
            [{
                "id": "PX-001",
                "name": "DRIFTED_PRODUCT_NAME",
                "exposure": "PUBLIC",
                "operationSchemaRef": (
                    "schema/operation-union.schema.json#/$defs/Operation_PX_001"
                ),
            }],
            {
                "$defs": {
                    "Operation_PX_001": {
                        "properties": {
                            "operationKind": {"const": "EXPECTED_PRODUCT_NAME"}
                        }
                    },
                    "PublicOperation": {
                        "oneOf": [{"$ref": "#/$defs/Operation_PX_001"}]
                    },
                }
            },
            "operation.schema.json",
        )
        record(
            "product_operation_id_name_drift",
            "FAIL_OPERATION_ID_NAME_DRIFT",
            (error["code"] for error in focused_px_result.errors),
        )

        content_result = ValidationResult(temp, temp, "final", temp / "unused.json")
        mixed_offer = {
            "type": "object",
            "properties": {
                "targetKind": {"const": "OFFER_TARGET"},
                "offerId": {"type": "string"},
                "contentRefId": {"type": "string"},
            },
            "required": ["targetKind", "offerId", "contentRefId"],
            "additionalProperties": False,
        }
        ref_branch = {
            "type": "object",
            "properties": {
                "targetKind": {"const": "REF_TARGET"},
                "contentRefId": {"type": "string"},
            },
            "required": ["targetKind", "contentRefId"],
            "additionalProperties": False,
        }
        check_content_ticket_unions(
            content_result,
            "content_union",
            {
                "ContentRef": {"type": "object"},
                "ContentAccessTicket": {"oneOf": [mixed_offer, ref_branch]},
                "ContentTicketIssueRequest": {"oneOf": [mixed_offer, ref_branch]},
            },
            "domain.schema.json",
        )
        record(
            "offer_ref_ticket_field_mix",
            "FAIL_CONTENT_TICKET_UNION",
            (error["code"] for error in content_result.errors),
        )

        boundary_documents: dict[Path, Any] = {}
        block_129_errors = evaluate_schema_instance(
            129,
            {"type": "integer", "minimum": 0, "maximum": 128},
            temp / "inline.schema.json",
            temp,
            boundary_documents,
        )
        record(
            "materialization_block_129",
            "FAIL_MATERIALIZATION_BLOCK_LIMIT",
            ["FAIL_MATERIALIZATION_BLOCK_LIMIT"] if block_129_errors else [],
        )
        zero_based_errors = evaluate_schema_instance(
            0,
            {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
            temp / "inline.schema.json",
            temp,
            boundary_documents,
        )
        one_based_zero_errors = evaluate_schema_instance(
            0,
            {"type": "integer", "minimum": 1, "maximum": 9007199254740991},
            temp / "inline.schema.json",
            temp,
            boundary_documents,
        )
        one_based_one_errors = evaluate_schema_instance(
            1,
            {"type": "integer", "minimum": 1, "maximum": 9007199254740991},
            temp / "inline.schema.json",
            temp,
            boundary_documents,
        )
        record_clean(
            "numeric_zero_minimum_partition",
            []
            if not zero_based_errors
            and one_based_zero_errors
            and not one_based_one_errors
            else ["FAIL_NUMERIC_ZERO_ONE_BOUNDARY"],
        )
        goal_test_schema = {
            "oneOf": [
                {
                    "type": "object",
                    "properties": {"state": {"const": state}},
                    "required": ["state"],
                    "additionalProperties": False,
                }
                for state in (
                    "ABSENT_PROVEN", "ACTIVE", "PAUSED", "BUDGET_LIMITED",
                    "COMPLETED", "CLEARED_PROVEN",
                )
            ]
        }
        invalid_goal_errors = evaluate_schema_instance(
            {"state": "UNKNOWN"}, goal_test_schema,
            temp / "inline.schema.json", temp, boundary_documents,
        )
        record(
            "goal_unknown_union_member",
            "FAIL_GOAL_SEALED_UNION",
            ["FAIL_GOAL_SEALED_UNION"] if invalid_goal_errors else [],
        )
        event_key = {
            "sourcePartition": "S", "ownerKind": "O",
            "aggregateRef": "A", "eventId": "E",
        }
        message_key_one = {
            "sourcePartition": "S", "subscriptionId": "U",
            "streamId": "R", "messageId": "M1",
        }
        message_key_two = {**message_key_one, "messageId": "M2"}
        record_clean(
            "event_key_multi_message_key",
            []
            if event_key == dict(event_key)
            and message_key_one != message_key_two
            else ["FAIL_EVENT_MESSAGE_KEY_PROJECTION"],
        )
        settings_payload_names = {
            "OP-024": {
                "modelId", "effortIntent",
                "codexSettingsCapabilitySnapshotId",
                "codexSettingsCapabilitySnapshotDigest",
            },
            "OP-025": {
                "serviceTierIntent", "codexCertificationId",
                "codexCertificationDigest",
            },
            "OP-026": {
                "approvalPolicy", "approvalsReviewer", "sandboxPolicy",
                "codexCertificationId", "codexCertificationDigest",
            },
            "OP-027": {
                "collaborationMode", "codexCertificationId",
                "codexCertificationDigest",
            },
            "OP-028": {
                "approvalPolicy", "approvalsReviewer", "sandboxPolicy",
                "codexCertificationId", "codexCertificationDigest",
            },
        }
        record_clean(
            "settings_r62_owner_and_evidence_inventory",
            settings_operation_inventory_errors(settings_payload_names),
        )
        bad_settings_payload_names = {
            key: set(value) for key, value in settings_payload_names.items()
        }
        bad_settings_payload_names["OP-028"].add("effortIntent")
        record(
            "settings_second_effort_mutator",
            "FAIL_THREAD_STATE_PROVIDER_CONTRACT",
            ["FAIL_THREAD_STATE_PROVIDER_CONTRACT"]
            if settings_operation_inventory_errors(bad_settings_payload_names)
            else [],
        )
        required_observation_schema = {
            "oneOf": [
                {
                    "type": "object",
                    "properties": {"state": {"const": "UNKNOWN"}},
                    "required": ["state"],
                    "additionalProperties": False,
                },
                {
                    "type": "object",
                    "properties": {
                        "state": {"const": "VALUE"},
                        "value": {"type": "string"},
                    },
                    "required": ["state", "value"],
                    "additionalProperties": False,
                },
            ]
        }
        required_null_errors = evaluate_schema_instance(
            {"state": "EXPLICIT_NULL"}, required_observation_schema,
            temp / "inline.schema.json", temp, boundary_documents,
        )
        record(
            "settings_required_field_explicit_null",
            "FAIL_THREAD_STATE_PROVIDER_CONTRACT",
            ["FAIL_THREAD_STATE_PROVIDER_CONTRACT"]
            if required_null_errors else [],
        )
        settings_coexistence_instance = {
            "activePermissionProfile": {"state": "VALUE"},
            "sandboxPolicy": {"state": "VALUE"},
        }
        record_clean(
            "settings_profile_sandbox_readback_coexists",
            evaluate_executable_rule(
                "SETTINGS_READBACK_COEXISTENCE",
                settings_coexistence_instance, {}, {},
            ),
        )
        record(
            "settings_snapshot_outbound_xor_rejected",
            "SETTINGS_SNAPSHOT_XOR_FORBIDDEN",
            evaluate_executable_rule(
                "SETTINGS_READBACK_COEXISTENCE",
                settings_coexistence_instance,
                {"applyOutboundXorToSnapshot": True}, {},
            ),
        )
        rule_registry = {
            "errorRegistry": {
                "problems": [{
                    "code": "OUTCOME_UNKNOWN",
                    "errorClass": "AMBIGUITY",
                    "retryDirective": "READ_RECONCILE_ONLY",
                    "detailSchemaRef": "schema/domain.schema.json#/$defs/ProblemSafeDetailV1",
                }]
            },
            "messages": [{
                "kind": "operation.state",
                "streamName": "operation.receipt",
                "allowedProjectionRoutes": [
                    "ORIGIN_RECEIPT/ORIGIN_CONNECTION"
                ],
            }],
        }
        canonical_problem = {
            "problemCode": "OUTCOME_UNKNOWN",
            "errorClass": "AMBIGUITY",
            "retryDirective": "READ_RECONCILE_ONLY",
        }
        record(
            "problem_code_alias_rejected",
            "PROBLEM_REGISTRY_MISMATCH",
            evaluate_executable_rule(
                "PROBLEM_REGISTRY_MATCH",
                {**canonical_problem, "problemCode": "UNKNOWN_OUTCOME"},
                {}, rule_registry,
            ),
        )
        record(
            "problem_class_mismatch_rejected",
            "PROBLEM_REGISTRY_MISMATCH",
            evaluate_executable_rule(
                "PROBLEM_REGISTRY_MATCH",
                {**canonical_problem, "errorClass": "INTERNAL"},
                {}, rule_registry,
            ),
        )
        unknown_directive_errors = evaluate_schema_instance(
            "RETRY_BLINDLY", {"enum": list(FIXED_RETRY_DIRECTIVES)},
            temp / "inline.schema.json", temp, boundary_documents,
        )
        record(
            "unknown_retry_directive_rejected",
            "FAIL_UNKNOWN_RETRY_DIRECTIVE",
            ["FAIL_UNKNOWN_RETRY_DIRECTIVE"]
            if unknown_directive_errors else [],
        )
        safe_detail_schema = {
            "type": "object",
            "properties": {
                "safeReason": {"type": "string", "maxLength": 512}
            },
            "additionalProperties": False,
        }
        for case_id, detail in (
            ("unknown_problem_detail_rejected", {"unknown": "x"}),
            ("raw_problem_detail_rejected", {"rawException": "secret"}),
        ):
            detail_errors = evaluate_schema_instance(
                detail, safe_detail_schema, temp / "inline.schema.json", temp,
                boundary_documents,
            )
            record(
                case_id,
                "FAIL_PROBLEM_DETAIL_SCHEMA",
                ["FAIL_PROBLEM_DETAIL_SCHEMA"] if detail_errors else [],
            )
        route_instance = {
            "kind": "operation.state",
            "streamName": "operation.projection",
            "projection": {
                "projectionKind": "SOURCE_BROADCAST",
                "audience": "ORIGIN_CONNECTION",
            },
        }
        record(
            "projection_cartesian_product_rejected",
            "PROJECTION_ROUTE_FORBIDDEN",
            evaluate_executable_rule(
                "DURABLE_ROUTE_STREAM", route_instance, {}, rule_registry
            ),
        )
        source_a = {
            "bridgeIdentityId": "b", "bridgeInstanceId": "i",
            "codexSourceId": "a",
        }
        source_b = {**source_a, "codexSourceId": "b"}
        record(
            "projection_cross_source_rejected",
            "SOURCE_MISMATCH",
            evaluate_executable_rule(
                "DURABLE_SOURCE_EQUALITY",
                {
                    "eventKey": {"sourcePartition": source_a},
                    "messageKey": {"sourcePartition": source_b},
                    "payload": {"sourcePartition": source_a},
                },
                {}, rule_registry,
            ),
        )
        closed_preimage_schema = {
            "type": "object",
            "properties": {
                "kind": {"type": "string"},
                "payloadDigest": {"type": "string"},
            },
            "required": ["kind", "payloadDigest"],
            "additionalProperties": False,
        }
        for case_id, instance in (
            ("preimage_missing_required_field", {"kind": "k"}),
            (
                "preimage_unknown_field",
                {"kind": "k", "payloadDigest": "d", "unknown": True},
            ),
        ):
            preimage_errors = evaluate_schema_instance(
                instance, closed_preimage_schema,
                temp / "inline.schema.json", temp, boundary_documents,
            )
            record(
                case_id,
                "FAIL_DURABLE_EVENT_ENVELOPE",
                ["FAIL_DURABLE_EVENT_ENVELOPE"] if preimage_errors else [],
            )
        implicit_open_preimage = {
            key: value for key, value in closed_preimage_schema.items()
            if key != "additionalProperties"
        }
        record(
            "preimage_implicit_additional_properties",
            "FAIL_DURABLE_EVENT_ENVELOPE",
            ["FAIL_DURABLE_EVENT_ENVELOPE"]
            if implicit_open_preimage.get("additionalProperties") is not False
            else [],
        )
        record(
            "durable_kind_payload_free_product",
            "MESSAGE_KIND_PAYLOAD_MISMATCH",
            evaluate_executable_rule(
                "DURABLE_KIND_PAYLOAD",
                {
                    "kind": "materialization.begin",
                    "payload": {"payloadKind": "materialization.page"},
                },
                {}, rule_registry,
            ),
        )
        record(
            "durable_zero_payload_digest",
            "PAYLOAD_DIGEST_MISMATCH",
            evaluate_executable_rule(
                "DURABLE_PAYLOAD_DIGEST",
                {"payload": {"value": 1}, "payloadDigest": "0" * 64},
                {}, rule_registry,
            ),
        )
        message_digest_instance = {
            "kind": "k", "payload": {}, "payloadDigest": "0" * 64,
            "messageDigest": "f" * 64,
        }
        record(
            "durable_tampered_message_digest",
            "MESSAGE_DIGEST_MISMATCH",
            evaluate_executable_rule(
                "DURABLE_MESSAGE_DIGEST", message_digest_instance,
                {}, rule_registry,
            ),
        )
        receipt = {"receiptId": "r", "manifestDigest": "m", "receiptDigest": "d"}
        record(
            "receipt_preimage_self_reference_rejected",
            "RECEIPT_PREIMAGE_MISMATCH",
            evaluate_executable_rule(
                "MATERIALIZATION_RECEIPT_PREIMAGE",
                dict(receipt), {"receipt": receipt}, rule_registry,
            ),
        )
        record(
            "receipt_preimage_arbitrary_exclusion_rejected",
            "RECEIPT_PREIMAGE_MISMATCH",
            evaluate_executable_rule(
                "MATERIALIZATION_RECEIPT_PREIMAGE",
                {"receiptId": "r"}, {"receipt": receipt}, rule_registry,
            ),
        )
        record(
            "receipt_preimage_stored_trust_rejected",
            "RULE_CONTEXT_MISSING",
            evaluate_executable_rule(
                "MATERIALIZATION_RECEIPT_PREIMAGE",
                {"receiptId": "r", "manifestDigest": "m"}, {},
                rule_registry,
            ),
        )
        record(
            "unknown_executable_rule_rejected",
            "UNKNOWN_EXECUTABLE_RULE",
            evaluate_executable_rule(
                "UNREGISTERED_RULE", {}, {}, rule_registry
            ),
        )

        inventory_root = (temp / "inventory-root").resolve()
        inventory_design = inventory_root / "docs/design/codex-kernel-v4"
        (inventory_design / "contracts/schema").mkdir(parents=True)
        (inventory_design / "contracts/sql").mkdir(parents=True)
        (inventory_design / "contracts/vectors").mkdir(parents=True)
        canonical_machines = [
            "SM-SOURCE", "SM-READ-ATTEMPT", "SM-MATERIALIZATION", "SM-CATALOG-HEAD", "SM-TIMELINE-HEAD",
            "SM-GAP-REPAIR", "SM-LIVE", "SM-OPERATION", "SM-DISPATCH-ATTEMPT",
            "SM-EFFECT-OBSERVATION", "SM-RECONCILE", "SM-LOCAL-INTENT",
            "SM-QUEUE-ENTRY", "SM-INTERACTION", "SM-CLAIM", "SM-SETTINGS-SNAPSHOT",
            "SM-GOAL", "SM-RELATION", "SM-EPHEMERAL-CHILD", "SM-DURABLE-DELIVERY",
            "SM-REPLICA-APPLY", "SM-CONTENT-OFFER", "SM-TRANSFER", "SM-NATIVE-CALL",
        ]
        (inventory_design / "06-STATE-MACHINES-AND-SEMANTIC-AXES.md").write_text(
            "\n".join(f"`{identifier}`" for identifier in canonical_machines),
            encoding="utf-8",
        )
        machine_descriptors = [
            {
                "id": identifier,
                "owner": "Owner",
                "initial": "A",
                "terminal": ["B"],
                "states": ["A", "B"],
                "transitions": [["A", "B"]],
                "wireProjection": "message registry typed projection" if identifier == "SM-EPHEMERAL-CHILD" else "typed",
                "storage": "MEMORY_ONLY" if identifier == "SM-EPHEMERAL-CHILD" else "registered",
                "negativeVector": "NEG-" + identifier.removeprefix("SM-"),
            }
            for identifier in canonical_machines[:-1]
        ]
        expected_product_ids = [
            *[f"K-{index:03d}" for index in range(1, 27)],
            *[f"P-{index:03d}" for index in range(1, 27)],
        ]
        lane_descriptors = [
            {"id": identifier, "scope": "SOURCE", "canonicalKeyFields": ["id"]}
            for identifier in FIXED_LANE_INVENTORY if identifier != "INTERACTION"
        ]
        registry_fixture = {
            "contract": {"protocolId": "ccpocket.codex.kernel", "protocolMajor": 1, "designGeneration": "v4", "legacyImport": "NO_IMPORT"},
            "owners": [
                {"id": "Owner", "soleWriter": True},
                {"id": "AutoApprovalPolicyStore", "soleWriter": True},
            ],
            "semantics": [{"id": "SEM", "owner": "Owner"}],
            "capabilities": [{"id": "cap", "owner": "Owner", "supportAxis": ["SUPPORTED", "UNSUPPORTED", "REQUIRES_BASE_APP_UPDATE", "UNKNOWN"], "availabilityAxis": ["AVAILABLE", "TEMPORARILY_UNAVAILABLE", "POLICY_DISABLED", "RESOURCE_EXHAUSTED", "UNKNOWN"]}],
            "stateMachines": machine_descriptors,
            "errors": [{"code": "GOOD"}],
            "limits": [
                {"id": "CONTROL_ENVELOPE_BYTES", "value": 65536},
                {"id": "CONTROL_PAYLOAD_BYTES", "value": 57344},
                {"id": "INTERACTION_ANSWER_BYTES", "value": 49152},
            ],
            "messages": [{"kind": "ephemeral.child.state", "capability": "cap", "errors": ["UNRESOLVED_ERROR"]}],
            "operations": [{"id": "OP-001", "name": "START_TURN", "owner": "CanonicalProjectionWriter", "domainOwner": "Owner", "errors": ["UNRESOLVED_ERROR"], "stateMachines": [], "queueLaneSelector": None, "executionConflictSelectors": [], "replayPolicy": "lookup", "exposure": "PUBLIC", "operationSchemaRef": None}],
            "ports": [{"id": "Port", "owner": "Owner"}],
            "contentResponsibilities": [{"responsibility": "x", "owner": "Owner"}],
            "contentLineages": [],
            "featureContributionContract": {"schemaRef": "schema/domain.schema.json#/$defs/FeatureContributionDescriptorV1"},
            "productCapabilityBindings": [
                {
                    "id": identifier,
                    "ownerRefs": ["Owner"],
                    "requiredRoles": ["AUTHORITY", "ADAPTER"] if index == 0 else ["AUTHORITY"],
                    "plannedContributions": [{
                        "contributionId": "module",
                        "hostKind": "BRIDGE",
                        "executionOwnerRef": "Owner",
                        "role": "AUTHORITY",
                        "supportResolverRef": "support-resolver",
                        "availabilityResolverRef": "availability-resolver",
                        "evidencePolicyRef": "evidence-policy",
                    }],
                    "ports": ["Port"],
                    "operationIds": [],
                    "messageKinds": [],
                    "protocolCapabilities": ["cap"],
                }
                for index, identifier in enumerate(expected_product_ids[:-1])
            ],
            "featureContributions": [{
                "featureId": "feature",
                "contributionId": "runtime",
                "version": 1,
                "hostKind": "BRIDGE",
                "executionOwnerRef": "Owner",
                "coveredCapabilityRoles": [{"capabilityId": "K-001", "role": "AUTHORITY"}],
                "dependencies": [],
                "ownerRefs": ["Owner"],
                "soleWriterRefs": [],
                "ports": ["Port"],
                "capabilityStatePolicy": {
                    "supportResolverRef": "support-resolver",
                    "availabilityResolverRef": "availability-resolver",
                    "evidenceKinds": ["RUNTIME"],
                    "fallbackSupport": "UNKNOWN",
                    "fallbackAvailability": "UNKNOWN",
                    "snapshotPublisherPortRef": "Port",
                    "support": "SUPPORTED",
                    "availability": "AVAILABLE",
                },
                "lifecycle": {
                    "start": "NOOP", "stop": "NOOP", "disconnect": "NOOP",
                    "sourceSwitch": "NOOP", "hostEpochChange": "NOOP",
                    "appBackground": "NOOP", "memoryPressure": "NOOP",
                },
            }],
            "laneFamilies": lane_descriptors,
            "storageArtifacts": [
                {"path": "sql/bridge-v1.sql", "authorityWriters": ["Owner"], "physicalTransactionCoordinator": "BridgeStorageWorker"},
                {"path": "sql/mobile-v1.sql", "authorityWriters": ["Owner"], "physicalTransactionCoordinator": "MobileStorageWorker"},
            ],
            "sourceRefs": [],
        }
        (inventory_design / "contracts/contract-registry.json").write_text(
            json.dumps(registry_fixture), encoding="utf-8"
        )
        (inventory_design / "drafts").mkdir(parents=True)
        (inventory_design / "drafts/K-CAPABILITY-COMPLETION.csv").write_text(
            "capability_id,unique_existing_root_owner\n"
            "K-001,AutoApprovalPolicyStore\n",
            encoding="utf-8",
        )
        (inventory_design / "contracts/sql/bridge-v1.sql").write_text(
            "CREATE TABLE ephemeral_child(id TEXT PRIMARY KEY);", encoding="utf-8"
        )
        (inventory_design / "contracts/sql/mobile-v1.sql").write_text(
            "CREATE TABLE safe(id TEXT PRIMARY KEY);", encoding="utf-8"
        )
        state_vectors = [
            {"id": "NEG-" + identifier.removeprefix("SM-")}
            for identifier in canonical_machines[:-1]
        ]
        (inventory_design / "contracts/vectors/contract-vectors.json").write_text(
            json.dumps({
                "schemaVectors": [], "fingerprintVectors": [], "serializationVectors": [],
                "admissionVectors": [], "stateMachineVectors": state_vectors,
                "sqlVectors": [], "injectedFailureInventory": [],
            }),
            encoding="utf-8",
        )
        domain_fixture = {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "domain.schema.json",
            "$defs": {
                "FeatureContributionDescriptorV1": {"type": "object"},
                "SourcePartition": {"type": "object", "properties": {key: {"type": "string"} for key in CANONICAL_SOURCE_PARTITION}, "required": list(CANONICAL_SOURCE_PARTITION)},
                "OperationKey": {"type": "object", "required": ["sourcePartition", "operationId"]},
            },
        }
        (inventory_design / "contracts/schema/domain.schema.json").write_text(
            json.dumps(domain_fixture), encoding="utf-8"
        )
        inventory_result = ValidationResult(
            inventory_root, inventory_design, "final", inventory_root / "unused.json"
        )
        inventory_config = {
            "machine_source": "contracts/contract-registry.json",
            "vector_source": "contracts/vectors/contract-vectors.json",
            "ddl_files": ["contracts/sql/bridge-v1.sql", "contracts/sql/mobile-v1.sql"],
            "operation_slots": [
                {"prefix": "OP-", "start": 1, "end": 39, "width": 3},
                {"prefix": "PX-", "start": 1, "end": 30, "width": 3},
            ],
            "state_machine_count": 24,
            "feature_contribution_count": 52,
            "lane_inventory": list(FIXED_LANE_INVENTORY),
        }
        check_contract_registry(inventory_result, "registry", inventory_config)
        inventory_codes = [error["code"] for error in inventory_result.errors]
        record("missing_one_of_24_state_machines", "FAIL_STATE_MACHINE_INVENTORY", inventory_codes)
        record("missing_one_of_12_lanes", "FAIL_LANE_INVENTORY", inventory_codes)
        record("missing_one_of_52_capability_bindings", "FAIL_FEATURE_CONTRIBUTION_INVENTORY", inventory_codes)
        record("unresolved_error_foreign_key", "FAIL_CONTRACT_REGISTRY_REFERENCE", inventory_codes)
        record("unresolved_owner_alias", "FAIL_CONTRACT_REGISTRY_WRITER_ALIAS", inventory_codes)
        record("ephemeral_durable_table", "FAIL_EPHEMERAL_DURABLE_TABLE", inventory_codes)
        record("ephemeral_durable_message", "FAIL_EPHEMERAL_DURABLE_MESSAGE", inventory_codes)
        record("feature_owner_coverage_missing", "FAIL_FEATURE_BINDING_OWNER_MISMATCH", inventory_codes)
        record("missing_required_feature_role", "FAIL_FEATURE_CAPABILITY_ROLE_COVERAGE", inventory_codes)
        record("static_supported_available", "FAIL_FEATURE_STATIC_CAPABILITY_STATE", inventory_codes)
        record(
            "simultaneous_capability_operation_ref_deletion",
            "FAIL_EXPECTED_OPERATION_REFS",
            inventory_codes,
        )
        record(
            "wrong_feature_host",
            "FAIL_FEATURE_HOST_OWNER_BINDING",
            inventory_codes,
        )
        record(
            "numeric_zero_one_domain_drift",
            "FAIL_NUMERIC_DOMAIN_MAPPING",
            inventory_codes,
        )
        record(
            "goal_union_missing",
            "FAIL_GOAL_SEALED_UNION",
            inventory_codes,
        )
        record(
            "event_key_message_key_contract_missing",
            "FAIL_DURABLE_EVENT_CONTRACT",
            inventory_codes,
        )
        record(
            "aggregate_event_half_transaction_inventory_missing",
            "FAIL_AGGREGATE_EVENT_INVENTORY",
            inventory_codes,
        )
        record(
            "error_registry_alias_shape",
            "FAIL_ERROR_REGISTRY",
            inventory_codes,
        )
        record(
            "problem_registry_binding_missing",
            "FAIL_PROBLEM_V1_REGISTRY_BINDING",
            inventory_codes,
        )
        record(
            "unregistered_cross_field_handler",
            "FAIL_EXECUTABLE_RULE_INVENTORY",
            inventory_codes,
        )

        manifest_members = []
        for member_path in (
            "contract-registry.json", "schema/domain.schema.json"
        ):
            member_bytes = (inventory_design / "contracts" / member_path).read_bytes()
            manifest_members.append(
                {
                    "path": member_path,
                    "bytes": len(member_bytes),
                    "sha256": "f" * 64 if member_path == "contract-registry.json" else hashlib.sha256(member_bytes).hexdigest(),
                }
            )
        manifest = {
            "contractSet": "ccpocket.codex.kernel/1/revision-1",
            "algorithm": "sha256",
            "members": manifest_members,
            "contractSetDigest": hashlib.sha256(
                stable_json({"members": manifest_members}).encode("utf-8")
            ).hexdigest(),
            "implementationReady": False,
            "generatedTargets": [],
        }
        (inventory_design / "contracts/CONTRACT-MANIFEST.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        manifest_result = ValidationResult(
            inventory_root, inventory_design, "final", inventory_root / "unused.json"
        )
        check_contract_manifest(manifest_result, "manifest", inventory_config)
        record(
            "manifest_digest_drift",
            "FAIL_CONTRACT_MANIFEST_DIGEST",
            (error["code"] for error in manifest_result.errors),
        )

        pragma_connection = sqlite3.connect(":memory:")
        try:
            pragma_connection.set_authorizer(sql_authorizer())
            quick_rows = sqlite_introspection(
                pragma_connection, "quick_check"
            )
            try:
                pragma_connection.execute("PRAGMA user_version").fetchall()
            except sqlite3.DatabaseError:
                contract_pragma_denied = True
            else:
                contract_pragma_denied = False
        finally:
            pragma_connection.close()
        record_clean(
            "validator_owned_sqlite_introspection",
            [] if quick_rows == [("ok",)] else ["FAIL_SQLITE_QUICK_CHECK"],
        )
        record(
            "contract_sql_pragma_forbidden",
            "FAIL_SQL_FILE_IO",
            ["FAIL_SQL_FILE_IO"]
            if contract_pragma_denied
            and ensure_safe_sql("PRAGMA foreign_keys=OFF")
            else [],
        )

        state_ddl = temp / "state-machine.sql"
        state_ddl.write_text(
            "CREATE TABLE sm(id TEXT PRIMARY KEY,state TEXT NOT NULL "
            "CHECK(state IN ('A','B','C')));"
            "CREATE TRIGGER sm_edge BEFORE UPDATE OF state ON sm "
            "WHEN NOT (OLD.state='A' AND NEW.state='B') "
            "BEGIN SELECT RAISE(ABORT,'INVALID_SM_EDGE'); END;",
            encoding="utf-8",
        )
        state_common = {
            "stateMachine": "SM-TEST", "database": "bridge",
            "table": "sm", "stateColumn": "state",
            "phase": "TRANSITION", "from": "A",
            "setupSteps": ["INSERT INTO sm VALUES ('id','A')"],
            "rowKey": {"id": "id"},
        }
        state_binding = {
            "transitionTriggers": ["sm_edge"],
            "allowedChangedTables": ["sm"],
            "mutationColumns": {
                "INITIAL": ["id", "state"],
                "TRANSITION": ["state"],
            },
        }
        allowed_state_code, _ = execute_state_machine_sql_vector(
            state_ddl,
            {
                **state_common, "id": "STATE-SQL-ALLOWED", "to": "B",
                "targetMutation": {"setValues": {"state": "B"}},
                "valid": True,
                "postconditions": [{
                    "query": "SELECT state FROM sm WHERE id='id'",
                    "rows": [["B"]],
                }],
            },
            state_binding,
        )
        record_clean(
            "state_sql_allowed_edge_execution",
            [allowed_state_code] if allowed_state_code else [],
        )
        bypass_state_code, _ = execute_state_machine_sql_vector(
            state_ddl,
            {
                **state_common, "id": "STATE-SQL-REINSERT-BYPASS", "to": "B",
                "beforeSteps": ["DELETE FROM sm WHERE id='id'"],
                "targetMutation": {"setValues": {"state": "B"}},
                "valid": True,
                "postconditions": [{"query": "SELECT 1", "rows": [[1]]}],
            },
            state_binding,
        )
        record(
            "state_sql_delete_reinsert_bypass",
            "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
            [bypass_state_code] if bypass_state_code else [],
        )
        self_report_state_code, _ = execute_state_machine_sql_vector(
            state_ddl,
            {
                **state_common, "id": "STATE-SQL-SELF-REPORTED", "to": "B",
                "targetMutation": {"setValues": {"state": "B"}},
                "valid": True,
                "expectedChangedTables": ["sm"],
                "expectedSqlErrorName": "SQLITE_CONSTRAINT_TRIGGER",
                "postconditions": [{
                    "query": "SELECT state FROM sm WHERE id='id'",
                    "rows": [["B"]],
                }],
            },
            state_binding,
        )
        record(
            "state_sql_self_reported_oracle",
            "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
            [self_report_state_code] if self_report_state_code else [],
        )
        forbidden_state_code, _ = execute_state_machine_sql_vector(
            state_ddl,
            {
                **state_common, "id": "STATE-SQL-FORBIDDEN", "to": "C",
                "targetMutation": {"setValues": {"state": "C"}},
                "valid": False,
                "postconditions": [{
                    "query": "SELECT state FROM sm WHERE id='id'",
                    "rows": [["A"]],
                }],
            },
            state_binding,
        )
        record_clean(
            "state_sql_forbidden_edge_execution",
            [forbidden_state_code] if forbidden_state_code else [],
        )

        wrong_guard_ddl = temp / "state-machine-wrong-guard.sql"
        wrong_guard_ddl.write_text(
            "CREATE TABLE sm(id TEXT PRIMARY KEY,state TEXT NOT NULL,aux TEXT NOT NULL);"
            "CREATE TRIGGER sm_edge BEFORE UPDATE OF state ON sm "
            "WHEN NOT (OLD.state='A' AND NEW.state IN ('B','C')) "
            "BEGIN SELECT RAISE(ABORT,'INVALID_SM_EDGE'); END;"
            "CREATE TRIGGER sm_aux BEFORE UPDATE OF aux ON sm "
            "WHEN NEW.aux='BAD' "
            "BEGIN SELECT RAISE(ABORT,'AUX_GUARD'); END;",
            encoding="utf-8",
        )
        wrong_guard_code, _ = execute_state_machine_sql_vector(
            wrong_guard_ddl,
            {
                "id": "STATE-SQL-WRONG-GUARD",
                "stateMachine": "SM-TEST", "database": "bridge",
                "table": "sm", "stateColumn": "state",
                "phase": "TRANSITION", "from": "A", "to": "C",
                "setupSteps": ["INSERT INTO sm VALUES ('id','A','OK')"],
                "targetMutation": {
                    "setValues": {"aux": "BAD", "state": "C"}
                },
                "valid": False, "rowKey": {"id": "id"},
                "postconditions": [{
                    "query": "SELECT state FROM sm WHERE id='id'",
                    "rows": [["A"]],
                }],
            },
            {
                "transitionTriggers": ["sm_edge", "sm_aux"],
                "allowedChangedTables": ["sm"],
                "mutationColumns": {
                    "INITIAL": ["aux", "id", "state"],
                    "TRANSITION": ["aux", "state"],
                },
            },
        )
        record(
            "state_sql_unrelated_registered_guard",
            "FAIL_STATE_MACHINE_SQL_VECTOR_STRUCTURE",
            [wrong_guard_code] if wrong_guard_code else [],
        )

        sql_cases = {
            "utf8_byte_overflow": (
                "CREATE TABLE t(v TEXT CHECK(length(CAST(v AS BLOB))<=4));",
                "",
                "INSERT INTO t VALUES ('你你');",
                "CHECK constraint failed",
            ),
            "policy_revision_skip": (
                "CREATE TABLE p(id TEXT PRIMARY KEY, revision INTEGER); CREATE TRIGGER p_rev BEFORE UPDATE ON p WHEN NEW.revision<>OLD.revision+1 BEGIN SELECT RAISE(ABORT,'RESOURCE_POLICY_REVISION_GAP'); END;",
                "INSERT INTO p VALUES ('p',1);",
                "UPDATE p SET revision=3 WHERE id='p';",
                "RESOURCE_POLICY_REVISION_GAP",
            ),
            "duplicate_active_interaction_claim": (
                "CREATE TABLE c(interaction_id TEXT, claim_id TEXT, state TEXT); CREATE UNIQUE INDEX one_active ON c(interaction_id) WHERE state='ACTIVE';",
                "INSERT INTO c VALUES ('i','c1','ACTIVE');",
                "INSERT INTO c VALUES ('i','c2','ACTIVE');",
                "UNIQUE constraint failed",
            ),
            "checkpoint_before_readback": (
                "CREATE TABLE inbox(event_id TEXT PRIMARY KEY, state TEXT); CREATE TABLE checkpoint(event_id TEXT); CREATE TRIGGER checkpoint_guard BEFORE INSERT ON checkpoint WHEN NOT EXISTS(SELECT 1 FROM inbox WHERE event_id=NEW.event_id AND state='READBACK') BEGIN SELECT RAISE(ABORT,'CHECKPOINT_BEFORE_READBACK'); END;",
                "INSERT INTO inbox VALUES ('e','APPLIED');",
                "INSERT INTO checkpoint VALUES ('e');",
                "CHECKPOINT_BEFORE_READBACK",
            ),
            "aggregate_head_without_same_revision_event": (
                "CREATE TABLE h(id TEXT PRIMARY KEY, revision INTEGER); CREATE TABLE e(id TEXT, revision INTEGER, PRIMARY KEY(id,revision)); CREATE TRIGGER h_event_guard BEFORE UPDATE ON h WHEN NOT EXISTS(SELECT 1 FROM e WHERE id=NEW.id AND revision=NEW.revision) BEGIN SELECT RAISE(ABORT,'HEAD_EVENT_ATOMICITY'); END;",
                "INSERT INTO h VALUES ('a',1); INSERT INTO e VALUES ('a',1);",
                "UPDATE h SET revision=2 WHERE id='a';",
                "HEAD_EVENT_ATOMICITY",
            ),
            "outcome_unknown_same_operation_redispatch": (
                "CREATE TABLE o(id TEXT PRIMARY KEY, state TEXT); CREATE TABLE a(id TEXT, attempt INTEGER); CREATE TRIGGER no_unknown_redispatch BEFORE INSERT ON a WHEN (SELECT state FROM o WHERE id=NEW.id)='OUTCOME_UNKNOWN' BEGIN SELECT RAISE(ABORT,'OUTCOME_UNKNOWN_READ_RECONCILE_ONLY'); END;",
                "INSERT INTO o VALUES ('op','OUTCOME_UNKNOWN');",
                "INSERT INTO a VALUES ('op',2);",
                "OUTCOME_UNKNOWN_READ_RECONCILE_ONLY",
            ),
        }
        for case_id, (ddl, setup, statement, expected_error) in sql_cases.items():
            ddl_path = temp / f"{case_id}.sql"
            ddl_path.write_text(ddl, encoding="utf-8")
            error_code, _ = execute_sql_negative_vector(
                ddl_path, setup, statement, expected_error
            )
            record_clean(case_id, [error_code] if error_code else [])

    document = {
        "cases": cases,
        "self_test": PASS if all(case["status"] == PASS for case in cases) else FAIL,
    }
    sys.stdout.write(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return 0 if document["self_test"] == PASS else 1


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("preflight", "final"))
    parser.add_argument("--root", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        if args.mode is not None or args.root is not None or args.report is not None:
            parser.error("--self-test cannot be combined with --mode/--root/--report")
    elif args.mode is None or args.root is None or args.report is None:
        parser.error("--mode, --root, and --report are required unless --self-test is used")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.self_test:
        return run_self_test()
    assert args.mode is not None and args.root is not None and args.report is not None
    try:
        exit_code, document = validate(args.mode, args.root, args.report)
        write_report(args.report.expanduser().resolve(), document)
    except (OSError, UnicodeError, ValueError) as exc:
        sys.stderr.write(f"validator configuration/report error: {exc}\n")
        return 2
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
