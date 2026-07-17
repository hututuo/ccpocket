import { describe, expect, it } from "vitest";
import { parseCodexAccountRateLimits } from "./account-usage.js";

describe("parseCodexAccountRateLimits", () => {
  it("keeps legacy windows while exposing named cards and reset credits", () => {
    const result = parseCodexAccountRateLimits({
      rateLimits: {
        limitId: "codex",
        limitName: "Codex",
        planType: "pro",
        primary: {
          usedPercent: 25,
          windowDurationMins: 300,
          resetsAt: 1_800_000_000,
        },
        secondary: {
          usedPercent: 70,
          windowDurationMins: 10_080,
          resetsAt: 1_800_500_000,
        },
      },
      rateLimitsByLimitId: {
        codex: {
          limitId: "codex",
          limitName: "Codex",
          planType: "pro",
          primary: {
            usedPercent: 25,
            windowDurationMins: 300,
            resetsAt: 1_800_000_000,
          },
          secondary: {
            usedPercent: 70,
            windowDurationMins: 10_080,
            resetsAt: 1_800_500_000,
          },
          rateLimitReachedType: "none",
          spendControlReached: false,
          individualLimit: {
            limit: "100",
            used: "12",
            remainingPercent: 88,
            resetsAt: 1_800_600_000,
          },
        },
      },
      rateLimitResetCredits: {
        availableCount: 2,
        credits: [
          {
            id: "credit-1",
            resetType: "codexRateLimits",
            status: "available",
            grantedAt: 1_800_000_000,
            expiresAt: 1_800_100_000,
            title: "Reset",
            description: null,
          },
        ],
      },
    });

    expect(result).toMatchObject({
      provider: "codex",
      source: "app_server",
      fiveHour: { utilization: 25 },
      sevenDay: { utilization: 70 },
      limitCards: [
        {
          id: "codex",
          name: "Codex",
          planType: "pro",
          spendControlReached: false,
          individualLimit: { remainingPercent: 88 },
        },
      ],
      resetCredits: {
        availableCount: 2,
        credits: [{ id: "credit-1", status: "available" }],
      },
    });
  });

  it("uses trimmed outer map keys and does not collapse cards with the same inner id", () => {
    const result = parseCodexAccountRateLimits({
      rateLimitsByLimitId: {
        "  gpt-5.3-codex-spark  ": {
          limitId: "codex",
          primary: { usedPercent: 41 },
          secondary: { usedPercent: 52 },
        },
        review: {
          limitId: "codex",
          primary: { usedPercent: 63 },
        },
      },
    });

    expect(result.limitCards?.map((card) => card.id)).toEqual([
      "gpt-5.3-codex-spark",
      "review",
    ]);
    expect(result.limitCards?.[0]).toMatchObject({
      id: "gpt-5.3-codex-spark",
      fiveHour: { utilization: 41 },
      sevenDay: { utilization: 52 },
    });
    expect(result.limitCards?.[1]).toMatchObject({
      id: "review",
      fiveHour: { utilization: 63 },
    });
    expect(result.fiveHour?.utilization).toBe(41);
  });

  it("fails closed for blank authoritative and explicit fallback ids", () => {
    expect(
      parseCodexAccountRateLimits({
        rateLimitsByLimitId: {
          "   ": {
            limitId: "codex",
            primary: { usedPercent: 91 },
          },
        },
      }).limitCards,
    ).toEqual([]);
    expect(
      parseCodexAccountRateLimits({
        rateLimits: {
          limitId: "   ",
          primary: { usedPercent: 92 },
        },
      }).limitCards,
    ).toEqual([]);
  });

  it("classifies weekly-only sparse cards and degrades invalid timestamps per field", () => {
    const result = parseCodexAccountRateLimits({
      rateLimitsByLimitId: {
        Codex: {
          limitId: "ignored-inner-id",
          primary: {
            usedPercent: 48,
            windowDurationMins: 10_079,
            resetsAt: 1_800_500_000_000,
          },
          individualLimit: {
            limit: "100",
            used: "5",
            remainingPercent: 95,
            resetsAt: Number.MAX_VALUE,
          },
        },
      },
      rateLimitResetCredits: {
        availableCount: 1,
        credits: [
          {
            id: "credit-invalid-time",
            resetType: "codexRateLimits",
            status: "available",
            grantedAt: Number.MAX_VALUE,
            expiresAt: Number.MAX_VALUE,
          },
        ],
      },
    });

    expect(result.fiveHour).toBeNull();
    expect(result.sevenDay).toEqual({
      utilization: 48,
      resetsAt: new Date(1_800_500_000 * 1000).toISOString(),
      windowDurationMins: 10_079,
    });
    expect(result.limitCards?.[0]).toMatchObject({
      id: "codex",
      fiveHour: null,
      individualLimit: { remainingPercent: 95 },
    });
    expect(result.limitCards?.[0]?.individualLimit).not.toHaveProperty(
      "resetsAt",
    );
    expect(result.resetCredits).toMatchObject({
      availableCount: 1,
      credits: [
        expect.objectContaining({
          id: "credit-invalid-time",
        }),
      ],
    });
    expect(result.resetCredits?.credits?.[0]).not.toHaveProperty("grantedAt");
    expect(result.resetCredits?.credits?.[0]).not.toHaveProperty("expiresAt");
  });

  it("preserves explicit durations so clients can label short windows accurately", () => {
    const result = parseCodexAccountRateLimits({
      rateLimitsByLimitId: {
        codex: {
          limitName: "Codex",
          primary: {
            usedPercent: 34,
            windowDurationMins: 15,
            resetsAt: 1_800_000_000,
          },
          secondary: {
            usedPercent: 71,
            windowDurationMins: 10_080,
            resetsAt: 1_800_500_000,
          },
        },
      },
    });

    expect(result.fiveHour).toEqual({
      utilization: 34,
      resetsAt: new Date(1_800_000_000 * 1000).toISOString(),
      windowDurationMins: 15,
    });
    expect(result.sevenDay).toEqual({
      utilization: 71,
      resetsAt: new Date(1_800_500_000 * 1000).toISOString(),
      windowDurationMins: 10_080,
    });
    expect(result.limitCards?.[0]?.fiveHour?.windowDurationMins).toBe(15);
  });
});
