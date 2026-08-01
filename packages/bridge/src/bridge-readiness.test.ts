import { describe, expect, it } from "vitest";
import { bridgeReadinessSnapshot } from "./bridge-readiness.js";

describe("bridgeReadinessSnapshot", () => {
  it("keeps private legacy readiness while reporting degraded optional stores", () => {
    expect(
      bridgeReadinessSnapshot({
        codexRuntimeMode: "private",
        terminalResults: { ready: false, degraded: true },
        inputDelivery: { ready: false, degraded: true },
      }),
    ).toEqual({
      ready: true,
      reasons: [],
      degradedFeatures: ["terminalResults", "inputDelivery"],
    });
  });

  it.each(["managed", "external"] as const)(
    "keeps %s compatibility mode on the legacy readiness contract",
    (codexRuntimeMode) => {
      expect(
        bridgeReadinessSnapshot({
          codexRuntimeMode,
          terminalResults: { ready: false, degraded: true },
          inputDelivery: { ready: false, degraded: true },
        }),
      ).toEqual({
        ready: true,
        reasons: [],
        degradedFeatures: ["terminalResults", "inputDelivery"],
      });
    },
  );

  it("requires every shared-daemon writer and persistence gate", () => {
    expect(
      bridgeReadinessSnapshot({
        codexRuntimeMode: "daemon",
        sharedRuntimeControlReady: false,
        actionBroker: { ready: false, degraded: true },
        terminalResults: { ready: false, degraded: true },
        inputDelivery: { ready: false, degraded: true },
      }),
    ).toEqual({
      ready: false,
      reasons: [
        "shared_runtime_control_unavailable",
        "action_broker_writer_unavailable",
        "terminal_result_persistence_unavailable",
        "input_delivery_persistence_unavailable",
      ],
      degradedFeatures: ["terminalResults", "inputDelivery"],
    });
  });

  it("reports a healthy shared daemon ready", () => {
    expect(
      bridgeReadinessSnapshot({
        codexRuntimeMode: "daemon",
        sharedRuntimeControlReady: true,
        actionBroker: { ready: true, degraded: false },
        terminalResults: { ready: true, degraded: false },
        inputDelivery: { ready: true, degraded: false },
      }),
    ).toEqual({ ready: true, reasons: [], degradedFeatures: [] });
  });
});
