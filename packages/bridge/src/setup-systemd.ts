import { execSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
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

const SERVICE_NAME = "ccpocket-bridge";

function getServiceDir(): string {
  const dir = join(homedir(), ".config", "systemd", "user");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return dir;
}

function getServicePath(): string {
  return join(getServiceDir(), `${SERVICE_NAME}.service`);
}

export function uninstallSystemd(): void {
  const servicePath = getServicePath();
  console.log("==> Uninstalling Bridge Server service...");

  try {
    execSync(`systemctl --user stop "${SERVICE_NAME}"`, { stdio: "ignore" });
  } catch {
    /* ok */
  }
  try {
    execSync(`systemctl --user disable "${SERVICE_NAME}"`, { stdio: "ignore" });
  } catch {
    /* ok */
  }

  if (existsSync(servicePath)) {
    unlinkSync(servicePath);
  }

  try {
    execSync("systemctl --user daemon-reload", { stdio: "ignore" });
  } catch {
    /* ok */
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

function uniquePathEntries(entries: string[]): string[] {
  const seen = new Set<string>();
  return entries.filter((entry) => {
    if (!entry || seen.has(entry)) return false;
    seen.add(entry);
    return true;
  });
}

function buildServicePath(nodeBinDir: string): string {
  const home = homedir();
  const systemBins = ["/usr/local/bin", "/usr/bin", "/bin"];
  const nodeFallback = systemBins.includes(nodeBinDir) ? [] : [nodeBinDir];
  return uniquePathEntries([
    join(home, ".local", "bin"),
    join(home, "bin"),
    join(home, ".nvm", "versions", "node", "current", "bin"),
    join(home, ".volta", "bin"),
    join(home, ".mise", "shims"),
    join(home, ".asdf", "shims"),
    join(home, ".bun", "bin"),
    join(home, ".npm-global", "bin"),
    ...nodeFallback,
    ...systemBins,
  ]).join(":");
}

const START_BRIDGE_COMMAND =
  'if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; nvm use --silent default >/dev/null 2>&1 || nvm use --silent node >/dev/null 2>&1 || true; fi; export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; exec node "$BRIDGE_CLI_ENTRY"';

function escapeSystemdEnvironment(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

export function setupSystemd(opts: SetupOptions): void {
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
  const servicePath = getServicePath();
  const bridgeCliEntry = fileURLToPath(new URL("./cli.js", import.meta.url));
  console.log(`==> Bridge CLI: ${bridgeCliEntry}`);

  // Keep the current Node directory as a fallback while preferring stable
  // user-level shims when the service starts.
  const nodeBinDir = dirname(process.execPath);

  // Build environment lines
  let envLines = `Environment=PATH=${buildServicePath(nodeBinDir)}
Environment=BRIDGE_PORT=${port}
Environment=BRIDGE_HOST=${host}
Environment=BRIDGE_REQUIRE_API_KEY=${connectionAuthentication.required ? "1" : "0"}
Environment=BRIDGE_AUTH_MODE=${connectionAuthentication.mode}
Environment="BRIDGE_CLI_ENTRY=${escapeSystemdEnvironment(bridgeCliEntry)}"`;

  if (apiKey) {
    envLines += `\nEnvironment=BRIDGE_API_KEY=${apiKey}`;
  }
  if (allowUnauthenticatedRemote) {
    envLines += "\nEnvironment=BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE=1";
  }
  if (allowUnauthenticatedDiagnostics) {
    envLines += "\nEnvironment=BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS=1";
  }
  if (allowedDirs) {
    envLines += `\nEnvironment=BRIDGE_ALLOWED_DIRS=${allowedDirs}`;
  }
  if (publicWsUrl) {
    envLines += `\nEnvironment=BRIDGE_PUBLIC_WS_URL=${publicWsUrl}`;
  }
  if (artifactBaseUrl) {
    envLines += `\nEnvironment=BRIDGE_ARTIFACT_BASE_URL=${artifactBaseUrl}`;
  }
  if (autoArtifacts) {
    envLines += `\nEnvironment="BRIDGE_AUTO_ARTIFACTS=${escapeSystemdEnvironment(autoArtifacts)}"`;
  }
  if (artifactRegistryFile) {
    envLines += `\nEnvironment="BRIDGE_ARTIFACT_REGISTRY_FILE=${escapeSystemdEnvironment(artifactRegistryFile)}"`;
  }
  if (fileTransferDownloadDir) {
    envLines += `\nEnvironment="BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR=${escapeSystemdEnvironment(fileTransferDownloadDir)}"`;
  }
  if (fileTransferPartialDir) {
    envLines += `\nEnvironment="BRIDGE_FILE_TRANSFER_PARTIAL_DIR=${escapeSystemdEnvironment(fileTransferPartialDir)}"`;
  }
  if (fileTransferStateFile) {
    envLines += `\nEnvironment="BRIDGE_FILE_TRANSFER_STATE_FILE=${escapeSystemdEnvironment(fileTransferStateFile)}"`;
  }
  if (disableMdns) {
    envLines += "\nEnvironment=BRIDGE_DISABLE_MDNS=1";
  }
  if (codexAssistModel) {
    envLines += `\nEnvironment=BRIDGE_CODEX_ASSIST_MODEL=${codexAssistModel}`;
  }
  if (codexAssistReasoningEffort) {
    envLines += `\nEnvironment=BRIDGE_CODEX_ASSIST_REASONING_EFFORT=${codexAssistReasoningEffort}`;
  }
  if (codexHome) {
    envLines += `\nEnvironment="CODEX_HOME=${escapeSystemdEnvironment(codexHome)}"`;
  }
  if (codexSourceId) {
    envLines += `\nEnvironment=BRIDGE_CODEX_SOURCE_ID=${codexSourceId}`;
  }
  if (codexAppServerMode) {
    envLines += `\nEnvironment=BRIDGE_CODEX_APP_SERVER_MODE=${codexAppServerMode}`;
  }
  if (codexAppServerMode && codexAppServerUrl) {
    envLines += `\nEnvironment=BRIDGE_CODEX_SHARED_APP_SERVER_URL=${codexAppServerUrl}`;
  }

  // Generate systemd user service unit
  // Run through bash so Node and provider CLIs follow stable shims/current
  // symlinks instead of pinning one version-managed runtime forever.
  const unit = `[Unit]
Description=CC Pocket Bridge Server
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -lc '${START_BRIDGE_COMMAND}'
${envLines}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
`;

  console.log(`==> Writing ${servicePath}`);
  writeFileSync(servicePath, unit);

  // Reload and enable
  console.log("==> Registering service...");
  execSync("systemctl --user daemon-reload");
  execSync(`systemctl --user enable "${SERVICE_NAME}"`);

  // Start the service
  try {
    execSync(`systemctl --user restart "${SERVICE_NAME}"`);
    console.log(`==> Bridge Server started on port ${port}`);
    if (codexAppServerMode && codexAppServerUrl) {
      console.log(
        `    Codex remote: codex resume --all --remote ${codexAppServerUrl}`,
      );
    }
  } catch {
    console.log(
      "==> Service registered (start may have failed — check logs with: journalctl --user -u ccpocket-bridge)",
    );
  }

  // Enable lingering so the user service persists after logout.
  // Without this, systemd user services stop when the last session ends
  // (e.g. SSH disconnect), which defeats the purpose of a background service.
  try {
    const lingerStatus = execSync(
      "loginctl show-user $USER --property=Linger",
      {
        encoding: "utf-8",
      },
    ).trim();
    if (lingerStatus !== "Linger=yes") {
      console.log(
        "==> Enabling linger to keep service running after logout...",
      );
      execSync("loginctl enable-linger $USER");
      console.log("    Linger enabled.");
    }
  } catch {
    console.log(
      "    Note: Could not enable linger. Run `loginctl enable-linger $USER` manually to keep the service running after logout.",
    );
  }

  console.log("    Done.");
}
