import { posix, win32 } from "node:path";

function getPathApi(platform: NodeJS.Platform) {
  return platform === "win32" ? win32 : posix;
}

export function stripWindowsExtendedPathPrefix(input: string): string {
  if (!input.startsWith("\\\\?\\")) return input;

  if (input.startsWith("\\\\?\\UNC\\")) {
    return `\\\\${input.slice("\\\\?\\UNC\\".length)}`;
  }

  const trimmed = input.slice("\\\\?\\".length);
  return /^[A-Za-z]:[\\/]/.test(trimmed) ? trimmed : input;
}

export function normalizePlatformPath(
  input: string,
  platform: NodeJS.Platform = process.platform,
): string {
  const pathApi = getPathApi(platform);
  const value =
    platform === "win32" ? stripWindowsExtendedPathPrefix(input) : input;
  return pathApi.normalize(value);
}

export function resolvePlatformPath(
  input: string,
  platform: NodeJS.Platform = process.platform,
): string {
  const pathApi = getPathApi(platform);
  return pathApi.resolve(normalizePlatformPath(input, platform));
}

export function resolvePlatformPathFrom(
  basePath: string,
  input: string,
  platform: NodeJS.Platform = process.platform,
): string {
  const pathApi = getPathApi(platform);
  const normalizedInput = normalizePlatformPath(input, platform);
  if (pathApi.isAbsolute(normalizedInput)) {
    return pathApi.resolve(normalizedInput);
  }
  return pathApi.resolve(
    resolvePlatformPath(basePath, platform),
    normalizedInput,
  );
}

export function parseAllowedDirectories(
  input: string | undefined,
  platform: NodeJS.Platform = process.platform,
  defaultDirs: string[] = [],
): string[] {
  const raw = input?.trim();
  if (!raw) {
    return defaultDirs.map((dir) => resolvePlatformPath(dir, platform));
  }
  if (raw === "*") return [];

  const entries = raw.split(",").map((dir) => dir.trim()).filter(Boolean);
  if (entries.length === 0) {
    throw new Error("BRIDGE_ALLOWED_DIRS must contain at least one path");
  }
  if (entries.includes("*")) {
    throw new Error(
      "BRIDGE_ALLOWED_DIRS must be either '*' or a comma-separated path list",
    );
  }
  return entries.map((dir) => resolvePlatformPath(dir, platform));
}

export interface OwnerFileAccessPolicy {
  fullDiskReadRequested: boolean;
  ownerFullDiskRead: boolean;
  allowedDirs: string[];
}

/**
 * Resolve the one authoritative file-access policy shared by every Bridge
 * surface.
 *
 * An exact `*` requests owner full-disk access, but it becomes effective only
 * when the Bridge also requires an API key. Without that authentication
 * boundary we deliberately fall back to the supplied safe roots instead of
 * leaking the empty-list sentinel ("unrestricted") into older consumers.
 */
export function resolveOwnerFileAccessPolicy(
  input: string | undefined,
  apiKey: string | undefined,
  platform: NodeJS.Platform = process.platform,
  defaultDirs: string[] = [],
  deviceAuthenticationAvailable = false,
): OwnerFileAccessPolicy {
  const fullDiskReadRequested = input?.trim() === "*";
  const ownerFullDiskRead =
    fullDiskReadRequested &&
    (Boolean(apiKey?.trim()) || deviceAuthenticationAvailable);
  const effectiveInput =
    fullDiskReadRequested && !ownerFullDiskRead ? undefined : input;
  return {
    fullDiskReadRequested,
    ownerFullDiskRead,
    allowedDirs: parseAllowedDirectories(
      effectiveInput,
      platform,
      defaultDirs,
    ),
  };
}

export function isPathWithinAllowedDirectory(
  targetPath: string,
  allowedDir: string,
  platform: NodeJS.Platform = process.platform,
): boolean {
  const pathApi = getPathApi(platform);
  const resolvedTarget = resolvePlatformPath(targetPath, platform);
  const resolvedAllowedDir = resolvePlatformPath(allowedDir, platform);

  if (resolvedTarget === resolvedAllowedDir) return true;

  const relativePath = pathApi.relative(resolvedAllowedDir, resolvedTarget);
  return (
    relativePath !== "" &&
    !relativePath.startsWith("..") &&
    !pathApi.isAbsolute(relativePath)
  );
}
