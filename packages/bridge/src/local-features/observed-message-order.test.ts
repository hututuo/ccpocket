import { describe, expect, it } from "vitest";
import { mergeObservedOrder } from "./observed-message-order.js";

describe("observed message ordering", () => {
  it("keeps an earlier tool before the next shared assistant anchor", () => {
    const merged = mergeObservedOrder([0, 2, 3], [0, 1, 2, 3]);
    expect(merged).toEqual([0, 1, 2, 3]);
    expect(mergeObservedOrder([0, 1, 2, 3], [0, 1, 2, 3])).toEqual(merged);
  });
  it("preserves missing runs and the live tail in source order", () => {
    expect(mergeObservedOrder([0, 3, 6], [0, 1, 2, 3, 4, 5, 6, 7])).toEqual(
      [0, 1, 2, 3, 4, 5, 6, 7],
    );
  });
  it("retains canonical-only facts across subsequent projections", () => {
    const first = mergeObservedOrder([0, 1, 4], [0, 2, 4]);
    expect(mergeObservedOrder(first, [0, 2, 3, 4])).toEqual([0, 1, 2, 3, 4]);
  });
  it("never lets a reversed observer reorder canonical anchors", () => {
    expect(mergeObservedOrder([0, 1, 2], [2, 3, 0])).toEqual([0, 1, 2, 3]);
  });
  it("deduplicates aliases and accepts an empty baseline", () => {
    expect(mergeObservedOrder([], [0, 1, 1, 2])).toEqual([0, 1, 2]);
    expect(mergeObservedOrder([0, 2], [0, 1, 1, 2])).toEqual([0, 1, 2]);
  });
});
