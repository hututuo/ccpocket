import { execSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  defaultCodexSharedAppServerUrl,
  readCodexSharedAppServerUrl,
} from "./codex-app-server-config.js";
import { normalizeCodexSourceId, resolveCodexHome } from "./codex-home.js";
import { parseBridgePort } from "./bridge-port.js";
import { validateArtifactBaseUrl } from "./artifact-url.js";
import {
  assertSecureBridgeBinding,
  DEFAULT_BRIDGE_HOST,
} from "./bridge-bind-security.js";
import { resolveBridgeConnectionAuthentication } from "./bridge-connection-auth.js";

const PLIST_LABEL = "com.ccpocket.bridge";

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function getPlistPath(): string {
  const dir = join(homedir(), "Library", "LaunchAgents");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return join(dir, `${PLIST_LABEL}.plist`);
}

export function uninstallLaunchd(): void {
  const plistPath = getPlistPath();
  console.log("==> Uninstalling Bridge Server service...");

  try {
    execSync(`launchctl stop "${PLIST_LABEL}"`, { stdio: "ignore" });
  } catch {
    /* ok */
  }
  try {
    execSync(`launchctl unload "${plistPath}"`, { stdio: "ignore" });
  } catch {
    /* ok */
  }

  if (existsSync(plistPath)) {
    unlinkSync(plistPath);
  }
  console.log("    Service removed.");
}

interface SetupOptions {
  port?: string;
  host?: string;
  apiKey?: string;
  authMode?: string;
  requireApiKey?: boolean;
  publicWsUrl?: string;
  artifactBaseUrl?: string;
  disableMdns?: boolean;
  codexAppServerMode?: string;
  codexSharedAppServerUrl?: string;
  codexHome?: string;
  codexSourceId?: string;
  /** @deprecated Use codexSharedAppServerUrl. */
  codexAppServerPort?: string;
  /** @deprecated Use codexSharedAppServerUrl. */
  codexAppServerUrl?: string;
}

export function setupLaunchd(opts: SetupOptions): void {
  const port = parseBridgePort(opts.port ?? process.env.BRIDGE_PORT);
  const host = opts.host ?? process.env.BRIDGE_HOST ?? DEFAULT_BRIDGE_HOST;
  const rawAuthMode = opts.authMode ?? process.env.BRIDGE_AUTH_MODE;
  const unauthenticatedDiagnosticsRequested =
    process.env.BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS === "1";
  if (
    unauthenticatedDiagnosticsRequested &&
    rawAuthMode?.trim().toLowerCase() !== "open"
  ) {
    throw new Error(
      "BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS requires an explicit BRIDGE_AUTH_MODE=open",
    );
  }
  const connectionAuthentication = resolveBridgeConnectionAuthentication({
    apiKey: opts.apiKey ?? process.env.BRIDGE_API_KEY,
    requireApiKey:
      opts.requireApiKey ?? process.env.BRIDGE_REQUIRE_API_KEY,
    authMode: rawAuthMode,
  });
  const apiKey = connectionAuthentication.configuredApiKey ?? "";
  const allowUnauthenticatedRemote =
    process.env.BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE === "1" ||
    (connectionAuthentication.explicitlyConfigured &&
      !connectionAuthentication.required);
  const allowUnauthenticatedDiagnostics =
    unauthenticatedDiagnosticsRequested &&
    connectionAuthentication.mode === "open";
  assertSecureBridgeBinding({
    host,
    apiKey: connectionAuthentication.effectiveApiKey,
    allowUnauthenticatedRemote,
  });
  const allowedDirs = process.env.BRIDGE_ALLOWED_DIRS ?? "";
  const publicWsUrl =
    opts.publicWsUrl ?? process.env.BRIDGE_PUBLIC_WS_URL ?? "";
  const rawArtifactBaseUrl =
    opts.artifactBaseUrl ?? process.env.BRIDGE_ARTIFACT_BASE_URL ?? "";
  const artifactBaseUrl = validateArtifactBaseUrl(rawArtifactBaseUrl);
  const autoArtifacts = process.env.BRIDGE_AUTO_ARTIFACTS?.trim() ?? "";
  const artifactRegistryFile =
    process.env.BRIDGE_ARTIFACT_REGISTRY_FILE?.trim() ?? "";
  const fileTransferDownloadDir =
    process.env.BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR?.trim() ?? "";
  const fileTransferPartialDir =
    process.env.BRIDGE_FILE_TRANSFER_PARTIAL_DIR?.trim() ?? "";
  const fileTransferStateFile =
    process.env.BRIDGE_FILE_TRANSFER_STATE_FILE?.trim() ?? "";
  if (rawArtifactBaseUrl && !artifactBaseUrl) {
    throw new Error(
      "BRIDGE_ARTIFACT_BASE_URL must be a mobile-reachable HTTP(S) origin",
    );
  }
  const disableMdns = opts.disableMdns || process.env.BRIDGE_DISABLE_MDNS;
  const codexAssistModel = process.env.BRIDGE_CODEX_ASSIST_MODEL?.trim() ?? "";
  const codexAssistReasoningEffort =
    process.env.BRIDGE_CODEX_ASSIST_REASONING_EFFORT?.trim() ?? "";
  const rawCodexHome = opts.codexHome ?? process.env.CODEX_HOME ?? "";
  const codexHome = rawCodexHome.trim()
    ? resolveCodexHome({ env: { CODEX_HOME: rawCodexHome } })
    : "";
  const codexSourceId = normalizeCodexSourceId(
    opts.codexSourceId ?? process.env.BRIDGE_CODEX_SOURCE_ID,
  );
  const codexAppServerMode =
    opts.codexAppServerMode ?? process.env.BRIDGE_CODEX_APP_SERVER_MODE ?? "";
  const legacyCodexAppServerPort =
    opts.codexAppServerPort ?? process.env.BRIDGE_CODEX_APP_SERVER_PORT;
  const explicitCodexAppServerUrl =
    opts.codexSharedAppServerUrl ??
    opts.codexAppServerUrl ??
    readCodexSharedAppServerUrl();
  const codexAppServerUrl =
    explicitCodexAppServerUrl ??
    (codexAppServerMode === "managed"
      ? legacyCodexAppServerPort
        ? `ws://127.0.0.1:${legacyCodexAppServerPort}`
        : defaultCodexSharedAppServerUrl(String(port))
      : "");
  if (codexAppServerMode === "external" && !codexAppServerUrl) {
    throw new Error(
      "BRIDGE_CODEX_SHARED_APP_SERVER_URL is required when Codex app-server mode is external",
    );
  }
  const plistPath = getPlistPath();
  const bridgeCliEntry = fileURLToPath(new URL("./cli.js", import.meta.url));
  console.log(`==> Bridge CLI: ${bridgeCliEntry}`);

  // Build environment variables block
  let envBlock = `        <key>BRIDGE_PORT</key>
        <string>${port}</string>
        <key>BRIDGE_HOST</key>
        <string>${host}</string>
        <key>BRIDGE_REQUIRE_API_KEY</key>
        <string>${connectionAuthentication.required ? "1" : "0"}</string>
        <key>BRIDGE_AUTH_MODE</key>
        <string>${connectionAuthentication.mode}</string>
        <key>BRIDGE_CLI_ENTRY</key>
        <string>${escapeXml(bridgeCliEntry)}</string>`;

  if (apiKey) {
    envBlock += `
        <key>BRIDGE_API_KEY</key>
        <string>${apiKey}</string>`;
  }

  if (allowUnauthenticatedRemote) {
    envBlock += `
        <key>BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE</key>
        <string>1</string>`;
  }

  if (allowUnauthenticatedDiagnostics) {
    envBlock += `
        <key>BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS</key>
        <string>1</string>`;
  }

  if (allowedDirs) {
    envBlock += `
        <key>BRIDGE_ALLOWED_DIRS</key>
        <string>${allowedDirs}</string>`;
  }

  if (publicWsUrl) {
    envBlock += `
        <key>BRIDGE_PUBLIC_WS_URL</key>
        <string>${publicWsUrl}</string>`;
  }

  if (artifactBaseUrl) {
    envBlock += `
        <key>BRIDGE_ARTIFACT_BASE_URL</key>
        <string>${artifactBaseUrl}</string>`;
  }

  if (autoArtifacts) {
    envBlock += `
        <key>BRIDGE_AUTO_ARTIFACTS</key>
        <string>${escapeXml(autoArtifacts)}</string>`;
  }

  if (artifactRegistryFile) {
    envBlock += `
        <key>BRIDGE_ARTIFACT_REGISTRY_FILE</key>
        <string>${escapeXml(artifactRegistryFile)}</string>`;
  }

  if (fileTransferDownloadDir) {
    envBlock += `
        <key>BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR</key>
        <string>${escapeXml(fileTransferDownloadDir)}</string>`;
  }

  if (fileTransferPartialDir) {
    envBlock += `
        <key>BRIDGE_FILE_TRANSFER_PARTIAL_DIR</key>
        <string>${escapeXml(fileTransferPartialDir)}</string>`;
  }

  if (fileTransferStateFile) {
    envBlock += `
        <key>BRIDGE_FILE_TRANSFER_STATE_FILE</key>
        <string>${escapeXml(fileTransferStateFile)}</string>`;
  }

  if (disableMdns) {
    envBlock += `
        <key>BRIDGE_DISABLE_MDNS</key>
        <string>1</string>`;
  }

  if (codexAssistModel) {
    envBlock += `
        <key>BRIDGE_CODEX_ASSIST_MODEL</key>
        <string>${codexAssistModel}</string>`;
  }

  if (codexAssistReasoningEffort) {
    envBlock += `
        <key>BRIDGE_CODEX_ASSIST_REASONING_EFFORT</key>
        <string>${codexAssistReasoningEffort}</string>`;
  }

  if (codexHome) {
    envBlock += `
        <key>CODEX_HOME</key>
        <string>${escapeXml(codexHome)}</string>`;
  }

  if (codexSourceId) {
    envBlock += `
        <key>BRIDGE_CODEX_SOURCE_ID</key>
        <string>${codexSourceId}</string>`;
  }

  if (codexAppServerMode) {
    envBlock += `
        <key>BRIDGE_CODEX_APP_SERVER_MODE</key>
        <string>${codexAppServerMode}</string>`;
  }

  if (codexAppServerMode && codexAppServerUrl) {
    envBlock += `
        <key>BRIDGE_CODEX_SHARED_APP_SERVER_URL</key>
        <string>${codexAppServerUrl}</string>`;
  }

  // Generate plist
  // Use zsh -li -c to inherit the user's full shell environment
  // (mise, nvm, pyenv, Homebrew, etc.)
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-li</string>
        <string>-c</string>
        <string>exec node "$BRIDGE_CLI_ENTRY"</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
${envBlock}
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/ccpocket-bridge.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/ccpocket-bridge.err</string>
</dict>
</plist>
`;

  console.log(`==> Writing ${plistPath}`);
  writeFileSync(plistPath, plist);

  // Register with launchctl
  console.log("==> Registering service...");
  try {
    execSync(`launchctl unload "${plistPath}"`, { stdio: "ignore" });
  } catch {
    /* ok */
  }
  execSync(`launchctl load "${plistPath}"`);

  // Start the service
  try {
    execSync(`launchctl start "${PLIST_LABEL}"`);
    console.log(`==> Bridge Server started on port ${port}`);
    if (codexAppServerMode && codexAppServerUrl) {
      console.log(
        `    Codex remote: codex resume --all --remote ${codexAppServerUrl}`,
      );
    }
  } catch {
    console.log(
      "==> Service registered (start may have failed — check logs at /tmp/ccpocket-bridge.log)",
    );
  }

  console.log("    Done.");
}
