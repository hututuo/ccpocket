export type BridgeReadinessReason =
  | "shared_runtime_control_unavailable"
  | "action_broker_writer_unavailable"
  | "terminal_result_persistence_unavailable"
  | "input_delivery_persistence_unavailable";

export interface BridgeFeatureHealth {
  ready?: boolean;
  degraded?: boolean;
}

export interface BridgeReadinessInput {
  codexRuntimeMode: "private" | "managed" | "external" | "daemon";
  sharedRuntimeControlReady?: boolean;
  actionBroker?: BridgeFeatureHealth;
  terminalResults: BridgeFeatureHealth;
  inputDelivery: BridgeFeatureHealth;
}

export interface BridgeReadinessSnapshot {
  ready: boolean;
  reasons: BridgeReadinessReason[];
  degradedFeatures: Array<"terminalResults" | "inputDelivery">;
}

/**
 * Product readiness is stricter than process liveness only in shared-daemon
 * mode. A daemon Bridge without its single writer or durable mutation ledgers
 * must remain available for diagnostics, but must not invite Mobile to enter a
 * writable shared runtime. Private/legacy mode keeps its historical readiness
 * contract while exposing degraded optional features separately.
 */
export function bridgeReadinessSnapshot(
  input: BridgeReadinessInput,
): BridgeReadinessSnapshot {
  const reasons: BridgeReadinessReason[] = [];
  const degradedFeatures: BridgeReadinessSnapshot["degradedFeatures"] = [];
  if (input.terminalResults.degraded || input.terminalResults.ready === false) {
    degradedFeatures.push("terminalResults");
  }
  if (input.inputDelivery.degraded || input.inputDelivery.ready === false) {
    degradedFeatures.push("inputDelivery");
  }

  if (input.codexRuntimeMode === "daemon") {
    if (input.sharedRuntimeControlReady !== true) {
      reasons.push("shared_runtime_control_unavailable");
    }
    if (input.actionBroker?.ready !== true) {
      reasons.push("action_broker_writer_unavailable");
    }
    if (input.terminalResults.ready !== true) {
      reasons.push("terminal_result_persistence_unavailable");
    }
    if (input.inputDelivery.ready !== true) {
      reasons.push("input_delivery_persistence_unavailable");
    }
  }

  return {
    ready: reasons.length === 0,
    reasons,
    degradedFeatures,
  };
}
