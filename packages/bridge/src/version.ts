import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { CLIENT_BRIDGE_COMPATIBILITY_REVISION } from "./client-bridge-compatibility.js";

// Read package.json version at module load time
const __dirname = dirname(fileURLToPath(import.meta.url));
const packagePath = join(__dirname, "..", "package.json");
const packageJson = JSON.parse(readFileSync(packagePath, "utf-8"));

// Capture git info at startup (optional, may fail in non-git environments)
function getGitInfo(): { commit?: string; branch?: string } {
  try {
    const commit = execSync("git rev-parse --short HEAD", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    const branch = execSync("git rev-parse --abbrev-ref HEAD", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    return { commit, branch };
  } catch {
    return {};
  }
}

const gitInfo = getGitInfo();

export interface VersionInfo {
  version: string;
  clientBridgeCompatibilityRevision: number;
  nodeVersion: string;
  platform: NodeJS.Platform;
  arch: NodeJS.Architecture;
  startedAt: string;
  uptime: number;
  gitCommit?: string;
  gitBranch?: string;
}

/** Returns the package version string (e.g. "1.17.1"). */
export function getPackageVersion(): string {
  return packageJson.version;
}

export function getVersionInfo(serverStartedAt: number): VersionInfo {
  return {
    version: packageJson.version,
    clientBridgeCompatibilityRevision:
      CLIENT_BRIDGE_COMPATIBILITY_REVISION,
    nodeVersion: process.version,
    platform: process.platform,
    arch: process.arch,
    startedAt: new Date(serverStartedAt).toISOString(),
    uptime: Math.floor((Date.now() - serverStartedAt) / 1000),
    ...(gitInfo.commit && { gitCommit: gitInfo.commit }),
    ...(gitInfo.branch && { gitBranch: gitInfo.branch }),
  };
}
