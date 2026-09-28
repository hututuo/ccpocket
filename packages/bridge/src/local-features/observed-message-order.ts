/**
 * Preserve canonical order while placing observer-only messages before their
 * next shared stable-ID anchor. Appending every missing observer item instead
 * puts earlier tools after later answers until the provider catches up, at
 * which point Mobile sees reversed anchors and rejects the partial window.
 *
 * Conflicting observer anchors cannot reorder canonical facts. Such a source
 * only appends its unknown identities; a complete provider read resolves it.
 */
export function mergeObservedOrder(
  canonical: readonly number[],
  observed: readonly number[],
): number[] {
  const positions = new Map(canonical.map((id, index) => [id, index]));
  const unique = [...new Set(observed)];
  let lastAnchor = -1;
  for (const id of unique) {
    const position = positions.get(id);
    if (position === undefined) continue;
    if (position <= lastAnchor) {
      return [...canonical, ...unique.filter((id) => !positions.has(id))];
    }
    lastAnchor = position;
  }
  const before = new Map<number, number[]>();
  let pending: number[] = [];
  for (const id of unique) {
    if (!positions.has(id)) {
      pending.push(id);
    } else if (pending.length > 0) {
      before.set(id, pending);
      pending = [];
    }
  }
  return [...canonical.flatMap((id) => [...(before.get(id) ?? []), id]), ...pending];
}
