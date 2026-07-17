export interface LocalFeatureClientMessageShape {
  type: string;
}

export interface LocalFeatureServerMessageShape {
  type: string;
}

/**
 * Stable protocol seam for a removable local feature.
 *
 * The foundation imports a fixed set of neutral slots. A feature commit only
 * activates its own slot, so reverting that commit removes its wire contract
 * and parser without editing parser.ts or websocket.ts again.
 */
export interface LocalFeatureProtocolContribution<
  Client extends LocalFeatureClientMessageShape = LocalFeatureClientMessageShape,
  Server extends LocalFeatureServerMessageShape = LocalFeatureServerMessageShape,
> {
  readonly clientTypes: readonly Client["type"][];
  readonly serverTypes: readonly Server["type"][];
  parseClient(
    message: Record<string, unknown>,
  ): Client | null | undefined;
}

export function disabledLocalFeatureProtocolContribution(
  _featureId: string,
): LocalFeatureProtocolContribution {
  return {
    clientTypes: [],
    serverTypes: [],
    parseClient: () => undefined,
  };
}

export function validLocalFeatureId(
  value: unknown,
  maxLength: number,
): value is string {
  return (
    typeof value === "string" && value.length > 0 && value.length <= maxLength
  );
}

export function validLocalFeatureText(
  value: unknown,
  maxLength: number,
  allowEmpty: boolean,
): value is string {
  return (
    typeof value === "string" &&
    value.length <= maxLength &&
    (allowEmpty || value.trim().length > 0)
  );
}

export function hasOnlyLocalFeatureKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
): boolean {
  const allowedSet = new Set(allowed);
  return Object.keys(value).every((key) => allowedSet.has(key));
}
