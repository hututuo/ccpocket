#!/usr/bin/env node
import { setupProxy } from "./proxy.js";
import { platform } from "node:os";
import { startServer } from "./index.js";
import { getPackageVersion } from "./version.js";
import { hasFlag, parseCliArgs, parseFlag } from "./cli-args.js";
import { parseBridgePort } from "./bridge-port.js";

function startupErrorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

const args = process.argv.slice(2);
const parsed = parseCliArgs(args);

function printHelp(): void {
  console.log(`ccpocket-bridge

Usage:
  ccpocket-bridge [options]
  ccpocket-bridge <command> [options]

Commands:
  help                  Show this help
  version               Show the installed Bridge version
  doctor [--json]       Check the local Bridge environment
  setup [options]       Register Bridge as a macOS launchd or Linux systemd service
  share <path>          Create a temporary mobile preview link for a local file
  send <path>           Offer a local file to the one connected compatible phone
  file-transfer status  Diagnose the persistent transfer process lock
  file-transfer unlock  Remove only a lock whose recorded owner PID is dead

Options:
  -h, --help            Show this help
  -v, --version         Show the installed Bridge version
      --port <port>     WebSocket port (default: 8765)
      --host <host>     Bind address (default: 0.0.0.0)
      --api-key <key>   Enable API key authentication
      --public-ws-url <url>
                         Public ws:// or wss:// URL used in QR codes
      --artifact-base-url <url>
                         Mobile-reachable HTTP(S) origin for artifact links
      --no-mdns         Disable mDNS auto-discovery advertisement
      --codex-app-server-mode <mode>
                         Codex app-server mode: private, managed, or external
      --codex-shared-app-server-url <url>
                         Shared Codex app-server ws:// URL

Share options:
      --ttl <seconds>    Link lifetime from 60 to 86400 seconds (default: 3600)
      --base-url <url>   Mobile-reachable HTTP(S) Bridge URL
      --json             Print structured artifact metadata

Send options:
      --ttl <seconds>    Download lease from 60 to 86400 seconds (default: 86400)
      --base-url <url>   Mobile-reachable HTTP(S) Bridge URL
      --json             Print structured metadata with status "offered"

Setup options:
      --uninstall       Remove the registered service
      setup persists --port, --host, --api-key, --public-ws-url,
      --artifact-base-url, --no-mdns, Codex app-server options,
      BRIDGE_ALLOWED_DIRS, BRIDGE_AUTO_ARTIFACTS, and
      BRIDGE_ARTIFACT_REGISTRY_FILE, plus BRIDGE_FILE_TRANSFER_* paths

Configuration can also be provided with BRIDGE_PORT, BRIDGE_HOST,
BRIDGE_API_KEY, BRIDGE_ALLOWED_DIRS, BRIDGE_PUBLIC_WS_URL, and
BRIDGE_ARTIFACT_BASE_URL, BRIDGE_AUTO_ARTIFACTS,
BRIDGE_ARTIFACT_REGISTRY_FILE, and BRIDGE_DISABLE_MDNS.
Phone transfer storage can be configured with
BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR, BRIDGE_FILE_TRANSFER_PARTIAL_DIR,
and BRIDGE_FILE_TRANSFER_STATE_FILE.
Codex app-server configuration can be provided with
BRIDGE_CODEX_APP_SERVER_MODE and BRIDGE_CODEX_SHARED_APP_SERVER_URL.`);
}

if (parsed.helpRequested) {
  printHelp();
} else if (parsed.versionRequested) {
  console.log(`ccpocket-bridge ${getPackageVersion()}`);
} else if (parsed.command === "doctor") {
  // Configure global fetch proxy before any network calls
  setupProxy();
  // Doctor subcommand: check environment health
  const jsonOutput = hasFlag(parsed, "json");
  import("./doctor.js")
    .then(({ runDoctor, printReport }) =>
      runDoctor().then((report) => {
        if (jsonOutput) {
          console.log(JSON.stringify(report));
        } else {
          printReport(report);
        }
        process.exit(report.allRequiredPassed ? 0 : 1);
      }),
    )
    .catch((err) => {
      console.error("Doctor failed:", err);
      process.exit(1);
    });
} else if (parsed.command === "setup") {
  // Service setup subcommand (platform-specific)
  const opts = {
    port: parseFlag(parsed, "port"),
    host: parseFlag(parsed, "host"),
    apiKey: parseFlag(parsed, "api-key"),
    publicWsUrl: parseFlag(parsed, "public-ws-url"),
    artifactBaseUrl: parseFlag(parsed, "artifact-base-url"),
    disableMdns: hasFlag(parsed, "no-mdns"),
    codexAppServerMode: parseFlag(parsed, "codex-app-server-mode"),
    codexSharedAppServerUrl: parseFlag(parsed, "codex-shared-app-server-url"),
    codexAppServerPort: parseFlag(parsed, "codex-app-server-port"),
    codexAppServerUrl: parseFlag(parsed, "codex-app-server-url"),
  };

  if (platform() === "darwin") {
    import("./setup-launchd.js")
      .then(({ setupLaunchd, uninstallLaunchd }) => {
        hasFlag(parsed, "uninstall")
          ? uninstallLaunchd()
          : setupLaunchd(opts);
      })
      .catch((err) => {
        console.error("Setup failed:", err);
        process.exit(1);
      });
  } else if (platform() === "linux") {
    import("./setup-systemd.js")
      .then(({ setupSystemd, uninstallSystemd }) => {
        hasFlag(parsed, "uninstall")
          ? uninstallSystemd()
          : setupSystemd(opts);
      })
      .catch((err) => {
        console.error("Setup failed:", err);
        process.exit(1);
      });
  } else {
    console.error(
      `ERROR: 'setup' is not supported on ${platform()}. Supported: macOS (launchd), Linux (systemd).`,
    );
    process.exit(1);
  }
} else if (parsed.command === "file-transfer") {
  const action = parsed.positionals[1];
  if (action !== "status" && action !== "unlock") {
    console.error("File transfer command requires status or unlock");
    process.exitCode = 1;
  } else {
    import("./file-transfer-lock-command.js")
      .then(async ({
        formatFileTransferLockInspection,
        inspectFileTransferForCli,
        unlockFileTransferForCli,
      }) => {
        const inspection = action === "unlock"
          ? await unlockFileTransferForCli(parseFlag(parsed, "port"))
          : await inspectFileTransferForCli(parseFlag(parsed, "port"));
        console.log(
          hasFlag(parsed, "json")
            ? JSON.stringify(inspection)
            : formatFileTransferLockInspection(inspection),
        );
      })
      .catch((err) => {
        console.error(
          `File transfer ${action} failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        process.exitCode = 1;
      });
  }
} else if (parsed.command === "send") {
  const filePath = parsed.positionals[1];
  if (!filePath) {
    console.error("Send failed: file path is required");
    process.exitCode = 1;
  } else {
    import("./file-transfer-send-command.js")
      .then(async ({ parseFileTransferTtl, sendFileViaBridge }) => {
        const offered = await sendFileViaBridge({
          filePath,
          projectPath: process.cwd(),
          port: parseBridgePort(parseFlag(parsed, "port")),
          ttlSeconds: parseFileTransferTtl(parseFlag(parsed, "ttl")),
          baseUrl: parseFlag(parsed, "base-url"),
        });
        if (hasFlag(parsed, "json")) {
          console.log(JSON.stringify(offered));
        } else {
          console.log(
            `Offered ${offered.filename} (${offered.sizeBytes} bytes) to ${offered.recipientCount} compatible phone.`,
          );
          console.log(
            `Transfer ${offered.transferId} expires ${offered.expiresAt}; phone save is not yet confirmed.`,
          );
        }
      })
      .catch((err) => {
        console.error(
          `Send failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        process.exitCode = 1;
      });
  }
} else if (parsed.command === "share") {
  const filePath = parsed.positionals[1];
  if (!filePath) {
    console.error("Share failed: file path is required");
    process.exitCode = 1;
  } else {
    import("./artifact-share-command.js")
      .then(async ({ parseShareTtl, publishArtifactViaBridge }) => {
        const artifact = await publishArtifactViaBridge({
          filePath,
          projectPath: process.cwd(),
          port: parseBridgePort(parseFlag(parsed, "port")),
          ttlSeconds: parseShareTtl(parseFlag(parsed, "ttl")),
          baseUrl: parseFlag(parsed, "base-url"),
        });
        if (hasFlag(parsed, "json")) {
          console.log(JSON.stringify(artifact));
        } else {
          console.log(artifact.markdown);
        }
      })
      .catch((err) => {
        console.error(
          `Share failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        process.exitCode = 1;
      });
  }
} else {
  // Configure global fetch proxy before any network calls
  setupProxy();
  // Server mode: set env vars from CLI flags, then start
  const port = parseFlag(parsed, "port");
  const host = parseFlag(parsed, "host");
  const apiKey = parseFlag(parsed, "api-key");
  const publicWsUrl = parseFlag(parsed, "public-ws-url");
  const artifactBaseUrl = parseFlag(parsed, "artifact-base-url");
  const codexAppServerMode = parseFlag(parsed, "codex-app-server-mode");
  const codexSharedAppServerUrl = parseFlag(
    parsed,
    "codex-shared-app-server-url",
  );
  const codexAppServerPort = parseFlag(parsed, "codex-app-server-port");
  const codexAppServerUrl = parseFlag(parsed, "codex-app-server-url");

  if (port !== undefined) process.env.BRIDGE_PORT = port;
  if (host) process.env.BRIDGE_HOST = host;
  if (apiKey) process.env.BRIDGE_API_KEY = apiKey;
  if (publicWsUrl) process.env.BRIDGE_PUBLIC_WS_URL = publicWsUrl;
  if (artifactBaseUrl) {
    process.env.BRIDGE_ARTIFACT_BASE_URL = artifactBaseUrl;
  }
  if (codexAppServerMode) {
    process.env.BRIDGE_CODEX_APP_SERVER_MODE = codexAppServerMode;
  }
  if (codexAppServerPort) {
    process.env.BRIDGE_CODEX_APP_SERVER_PORT = codexAppServerPort;
  }
  if (codexSharedAppServerUrl) {
    process.env.BRIDGE_CODEX_SHARED_APP_SERVER_URL = codexSharedAppServerUrl;
  } else if (codexAppServerUrl) {
    process.env.BRIDGE_CODEX_APP_SERVER_URL = codexAppServerUrl;
  }
  if (hasFlag(parsed, "no-mdns")) process.env.BRIDGE_DISABLE_MDNS = "1";

  startServer().catch((err) => {
    console.error(`[bridge] Failed to start: ${startupErrorMessage(err)}`);
    process.exit(1);
  });
}
