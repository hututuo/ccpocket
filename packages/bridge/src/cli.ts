#!/usr/bin/env node
import { setupProxy } from "./proxy.js";
import { platform } from "node:os";
import { startServer } from "./index.js";
import { getPackageVersion } from "./version.js";
import { hasFlag, parseCliArgs, parseFlag } from "./cli-args.js";
import { parseBridgePort } from "./bridge-port.js";
import { validatePublicWsUrl } from "./startup-info.js";
import { BridgeIdentityStore } from "./bridge-identity.js";
import { BridgeDevicePairing } from "./bridge-device-pairing.js";
import {
  promptHistoryStoreFileForPort,
  PromptHistoryStore,
} from "./prompt-history-store.js";
import {
  readCodexAppServerMode,
  readCodexDaemonConfig,
} from "./codex-app-server-config.js";

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
  file-access status    Show whether mutation step-up is configured
  file-access set-password
                        Configure the Bridge-side mutation password
  pair list             List trusted devices and pending requests
  pair approve <code>   Approve a pending Mac-local pairing request
  pair reject <code>    Reject a pending Mac-local pairing request
  pair revoke <deviceId>
                        Revoke a trusted device
  pair qr               Create a one-time pairing QR/deep link

Options:
  -h, --help            Show this help
  -v, --version         Show the installed Bridge version
      --port <port>     WebSocket port (default: 8765)
      --host <host>     Bind address (default: 0.0.0.0)
      --api-key <key>   Set the saved Bridge connection key
      --auth-mode <mode> Authentication mode: key, paired_or_key, or open
      --require-api-key Require the configured Bridge connection key
      --no-require-api-key
                         Disable connection-key authentication while retaining the key
      --public-ws-url <url>
                         Public ws:// or wss:// URL used in QR codes
      --artifact-base-url <url>
                         Mobile-reachable HTTP(S) origin for artifact links
      --no-mdns         Disable mDNS auto-discovery advertisement
      --codex-app-server-mode <mode>
                         Codex app-server mode: private, managed, external, or daemon
      --codex-shared-app-server-url <url>
                         Shared Codex app-server ws:// URL
      --codex-source-id <id>
                         Shared Codex authority ID from Cockpit

Daemon pilot options (not persisted by setup):
      --codex-home <path>
                         Explicit CODEX_HOME used by the daemon
      --codex-daemon-cli <path>
                         Absolute Codex CLI path used only for daemon verification
      --codex-daemon-socket <path>
                         Unix socket path (defaults inside CODEX_HOME)
      --codex-daemon-expected-version <version>
                         Exact Codex CLI version

Share options:
      --ttl <seconds>    Link lifetime from 60 to 86400 seconds (default: 3600)
      --base-url <url>   Mobile-reachable HTTP(S) Bridge URL
      --json             Print structured artifact metadata

Send options:
      --ttl <seconds>    Download lease from 60 to 86400 seconds (default: 86400)
      --base-url <url>   Mobile-reachable HTTP(S) Bridge URL
      --json             Print structured metadata with status "offered"

File access options:
      --password-stdin  Read the new password from redirected stdin

Setup options:
      --uninstall       Remove the registered service
      setup persists --port, --host, --api-key, --require-api-key,
      --no-require-api-key, --auth-mode, --public-ws-url,
      --artifact-base-url, --no-mdns, Codex app-server options,
      --codex-source-id,
      BRIDGE_ALLOWED_DIRS, BRIDGE_AUTO_ARTIFACTS, and
      BRIDGE_ARTIFACT_REGISTRY_FILE, BRIDGE_FILE_TRANSFER_* paths, and
      BRIDGE_CODEX_ASSIST_MODEL / BRIDGE_CODEX_ASSIST_REASONING_EFFORT

Configuration can also be provided with BRIDGE_PORT, BRIDGE_HOST,
BRIDGE_API_KEY, BRIDGE_REQUIRE_API_KEY, BRIDGE_AUTH_MODE, BRIDGE_ALLOWED_DIRS,
BRIDGE_PUBLIC_WS_URL, BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS, and
BRIDGE_ARTIFACT_BASE_URL, BRIDGE_AUTO_ARTIFACTS,
BRIDGE_ARTIFACT_REGISTRY_FILE, and BRIDGE_DISABLE_MDNS.
Phone transfer storage can be configured with
BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR, BRIDGE_FILE_TRANSFER_PARTIAL_DIR,
and BRIDGE_FILE_TRANSFER_STATE_FILE.
Codex app-server configuration can be provided with
BRIDGE_CODEX_APP_SERVER_MODE and BRIDGE_CODEX_SHARED_APP_SERVER_URL.
Daemon mode additionally requires explicit CODEX_HOME,
BRIDGE_CODEX_DAEMON_CLI, and BRIDGE_CODEX_DAEMON_EXPECTED_VERSION;
official mixed-label packages may additionally set
BRIDGE_CODEX_DAEMON_EXPECTED_APP_SERVER_VERSION.
BRIDGE_CODEX_DAEMON_SOCKET defaults inside CODEX_HOME.
Shared Codex authority identity can be provided with
BRIDGE_CODEX_SOURCE_ID.
Codex assist calls can be configured with BRIDGE_CODEX_ASSIST_MODEL and
BRIDGE_CODEX_ASSIST_REASONING_EFFORT.`);
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
  // The reversible pilot deliberately does not persist daemon ownership into
  // the production Bridge service. Accepting only the mode here would write a
  // LaunchAgent/systemd unit without its required CODEX_HOME, CLI, socket and
  // exact-version contract, leaving a service that can never start safely.
  const requestedSetupMode = parseFlag(parsed, "codex-app-server-mode");
  let effectiveSetupMode: ReturnType<typeof readCodexAppServerMode>;
  try {
    effectiveSetupMode = readCodexAppServerMode(
      requestedSetupMode === undefined
        ? process.env
        : {
            ...process.env,
            BRIDGE_CODEX_APP_SERVER_MODE: requestedSetupMode,
          },
    );
  } catch (error) {
    console.error(`Setup failed: ${startupErrorMessage(error)}`);
    process.exit(1);
  }
  if (effectiveSetupMode === "daemon") {
    console.error(
      "Setup failed: daemon mode is pilot-only and cannot be persisted by setup",
    );
    process.exit(1);
  }
  const requireApiKeyFlag = hasFlag(parsed, "require-api-key");
  const noRequireApiKeyFlag = hasFlag(parsed, "no-require-api-key");
  if (requireApiKeyFlag && noRequireApiKeyFlag) {
    console.error(
      "Setup failed: --require-api-key and --no-require-api-key cannot be used together",
    );
    process.exit(1);
  }

  // Service setup subcommand (platform-specific)
  const opts = {
    port: parseFlag(parsed, "port"),
    host: parseFlag(parsed, "host"),
    apiKey: parseFlag(parsed, "api-key"),
    authMode: parseFlag(parsed, "auth-mode"),
    requireApiKey: requireApiKeyFlag
      ? true
      : noRequireApiKeyFlag
        ? false
        : undefined,
    publicWsUrl: parseFlag(parsed, "public-ws-url"),
    artifactBaseUrl: parseFlag(parsed, "artifact-base-url"),
    disableMdns: hasFlag(parsed, "no-mdns"),
    codexAppServerMode: requestedSetupMode,
    codexSharedAppServerUrl: parseFlag(parsed, "codex-shared-app-server-url"),
    codexSourceId: parseFlag(parsed, "codex-source-id"),
    codexAppServerPort: parseFlag(parsed, "codex-app-server-port"),
    codexAppServerUrl: parseFlag(parsed, "codex-app-server-url"),
  };

  if (platform() === "darwin") {
    import("./setup-launchd.js")
      .then(({ setupLaunchd, uninstallLaunchd }) => {
        hasFlag(parsed, "uninstall") ? uninstallLaunchd() : setupLaunchd(opts);
      })
      .catch((err) => {
        console.error("Setup failed:", err);
        process.exit(1);
      });
  } else if (platform() === "linux") {
    import("./setup-systemd.js")
      .then(({ setupSystemd, uninstallSystemd }) => {
        hasFlag(parsed, "uninstall") ? uninstallSystemd() : setupSystemd(opts);
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
      .then(
        async ({
          formatFileTransferLockInspection,
          inspectFileTransferForCli,
          unlockFileTransferForCli,
        }) => {
          const inspection =
            action === "unlock"
              ? await unlockFileTransferForCli(parseFlag(parsed, "port"))
              : await inspectFileTransferForCli(parseFlag(parsed, "port"));
          console.log(
            hasFlag(parsed, "json")
              ? JSON.stringify(inspection)
              : formatFileTransferLockInspection(inspection),
          );
        },
      )
      .catch((err) => {
        console.error(
          `File transfer ${action} failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        process.exitCode = 1;
      });
  }
} else if (parsed.command === "pair") {
  const action = parsed.positionals[1];
  const port = parseBridgePort(parseFlag(parsed, "port"));
  const runPairingCommand = async (): Promise<void> => {
    const identity = await BridgeIdentityStore.load();
    const history = new PromptHistoryStore(
      promptHistoryStoreFileForPort(
        port,
        process.env.BRIDGE_PROMPT_HISTORY_FILE,
      ),
    );
    await history.init();
    const pairing = new BridgeDevicePairing({
      bridgeIdentity: identity,
      bridgeInstanceId: history.bridgeInstanceId,
    });
    await pairing.init();
    if (action === "list") {
      const snapshot = await pairing.snapshot();
      console.log(
        hasFlag(parsed, "json")
          ? JSON.stringify(snapshot)
          : JSON.stringify(snapshot, null, 2),
      );
      return;
    }
    if (action === "approve" || action === "reject") {
      const code = parsed.positionals[2];
      if (!code)
        throw new Error(
          `pair ${action} requires a six-digit confirmation code`,
        );
      if (action === "approve") {
        const device = await pairing.approve(code);
        console.log(
          hasFlag(parsed, "json")
            ? JSON.stringify(device)
            : `Paired ${device.deviceId}`,
        );
      } else {
        const changed = await pairing.reject(code);
        if (!changed)
          throw new Error("Pairing confirmation code is invalid or expired");
        console.log(
          hasFlag(parsed, "json")
            ? JSON.stringify({ rejected: true })
            : "Pairing request rejected",
        );
      }
      return;
    }
    if (action === "revoke") {
      const deviceId = parsed.positionals[2];
      if (!deviceId) throw new Error("pair revoke requires a deviceId");
      const changed = await pairing.revoke(deviceId);
      if (!changed) throw new Error("Trusted device not found");
      console.log(
        hasFlag(parsed, "json")
          ? JSON.stringify({ revoked: true, deviceId })
          : `Revoked ${deviceId}`,
      );
      return;
    }
    if (action === "qr") {
      const rawBridgeUrl =
        parseFlag(parsed, "public-ws-url") ??
        process.env.BRIDGE_PUBLIC_WS_URL ??
        `ws://127.0.0.1:${port}`;
      const bridgeUrl = validatePublicWsUrl(rawBridgeUrl);
      if (!bridgeUrl) {
        throw new Error("pair qr requires a valid ws:// or wss:// public URL");
      }
      const qr = await pairing.createPairingToken({ bridgeUrl });
      if (hasFlag(parsed, "json")) {
        console.log(JSON.stringify(qr));
      } else {
        console.log(`Pairing link (expires ${qr.expiresAt}): ${qr.deepLink}`);
        try {
          const { default: QRCode } = await import("qrcode");
          console.log(
            await QRCode.toString(qr.deepLink, {
              type: "terminal",
              small: true,
            }),
          );
        } catch {
          console.log("(QR rendering unavailable; use the deep link above)");
        }
      }
      return;
    }
    throw new Error(
      "pair command requires list, approve, reject, revoke, or qr",
    );
  };
  runPairingCommand().catch((error) => {
    console.error(`Pair command failed: ${startupErrorMessage(error)}`);
    process.exitCode = 1;
  });
} else if (parsed.command === "file-access") {
  const action = parsed.positionals[1];
  if (action !== "status" && action !== "set-password") {
    console.error("File access command requires status or set-password");
    process.exitCode = 1;
  } else {
    import("./file-access-command.js")
      .then(
        async ({
          readFileAccessStatus,
          readPasswordFromStdin,
          setFileAccessPassword,
        }) => {
          if (action === "status") {
            const status = await readFileAccessStatus();
            if (hasFlag(parsed, "json")) {
              console.log(JSON.stringify(status));
            } else {
              console.log(
                status.passwordConfigured
                  ? `File mutation password configured; ${status.biometricDeviceCount} biometric device(s) enrolled.`
                  : "File mutation password is not configured.",
              );
            }
            return;
          }
          const password = hasFlag(parsed, "password-stdin")
            ? await readPasswordFromStdin()
            : undefined;
          await setFileAccessPassword({ password });
          console.log(
            "File mutation password configured. Existing biometric enrollments were revoked.",
          );
        },
      )
      .catch((err) => {
        console.error(
          `File access ${action} failed: ${err instanceof Error ? err.message : String(err)}`,
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
  const authMode = parseFlag(parsed, "auth-mode");
  const requireApiKeyFlag = hasFlag(parsed, "require-api-key");
  const noRequireApiKeyFlag = hasFlag(parsed, "no-require-api-key");
  const publicWsUrl = parseFlag(parsed, "public-ws-url");
  const artifactBaseUrl = parseFlag(parsed, "artifact-base-url");
  const codexAppServerMode = parseFlag(parsed, "codex-app-server-mode");
  const codexSharedAppServerUrl = parseFlag(
    parsed,
    "codex-shared-app-server-url",
  );
  const codexSourceId = parseFlag(parsed, "codex-source-id");
  const codexAppServerPort = parseFlag(parsed, "codex-app-server-port");
  const codexAppServerUrl = parseFlag(parsed, "codex-app-server-url");
  const codexDaemonCli = parseFlag(parsed, "codex-daemon-cli");
  const codexDaemonSocket = parseFlag(parsed, "codex-daemon-socket");
  const codexDaemonExpectedVersion = parseFlag(
    parsed,
    "codex-daemon-expected-version",
  );
  const codexHome = parseFlag(parsed, "codex-home");

  if (port !== undefined) process.env.BRIDGE_PORT = port;
  if (host) process.env.BRIDGE_HOST = host;
  if (apiKey) process.env.BRIDGE_API_KEY = apiKey;
  if (authMode) process.env.BRIDGE_AUTH_MODE = authMode;
  if (requireApiKeyFlag && noRequireApiKeyFlag) {
    console.error(
      "[bridge] Failed to start: --require-api-key and --no-require-api-key cannot be used together",
    );
    process.exit(1);
  }
  if (requireApiKeyFlag) process.env.BRIDGE_REQUIRE_API_KEY = "1";
  if (noRequireApiKeyFlag) process.env.BRIDGE_REQUIRE_API_KEY = "0";
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
  if (codexSourceId !== undefined) {
    process.env.BRIDGE_CODEX_SOURCE_ID = codexSourceId;
  }
  if (codexDaemonCli !== undefined) {
    process.env.BRIDGE_CODEX_DAEMON_CLI = codexDaemonCli;
  }
  if (codexDaemonSocket !== undefined) {
    process.env.BRIDGE_CODEX_DAEMON_SOCKET = codexDaemonSocket;
  }
  if (codexDaemonExpectedVersion !== undefined) {
    process.env.BRIDGE_CODEX_DAEMON_EXPECTED_VERSION =
      codexDaemonExpectedVersion;
  }
  if (codexHome !== undefined) {
    process.env.CODEX_HOME = codexHome;
  }
  if (hasFlag(parsed, "no-mdns")) process.env.BRIDGE_DISABLE_MDNS = "1";

  try {
    const mode = readCodexAppServerMode();
    if (mode === "daemon") {
      readCodexDaemonConfig();
    }
  } catch (error) {
    console.error(`[bridge] Failed to start: ${startupErrorMessage(error)}`);
    process.exit(1);
  }

  startServer().catch((err) => {
    console.error(`[bridge] Failed to start: ${startupErrorMessage(err)}`);
    process.exit(1);
  });
}
