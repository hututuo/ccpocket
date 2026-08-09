import { createServer } from "node:http";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { setupProxy } from "./proxy.js";
import { installProcessGuards } from "./process-guards.js";
import { BridgeWebSocketServer } from "./websocket.js";
import { ImageStore } from "./image-store.js";
import { GalleryStore } from "./gallery-store.js";
import { printStartupInfo } from "./startup-info.js";
import { MdnsAdvertiser, shouldAdvertiseMdns } from "./mdns.js";
import { ProjectHistory } from "./project-history.js";
import { getVersionInfo } from "./version.js";
import { fetchAllUsage } from "./usage.js";
import { runDoctor } from "./doctor.js";
import { DebugTraceStore } from "./debug-trace-store.js";
import { RecordingStore } from "./recording-store.js";
import { FirebaseAuthClient } from "./firebase-auth.js";
import { initializePushRuntime } from "./push-runtime.js";
import { PromptHistoryBackupStore } from "./prompt-history-backup.js";
import {
  promptHistoryStoreFileForPort,
  PromptHistoryStore,
} from "./prompt-history-store.js";
import { resolveOwnerFileAccessPolicy } from "./path-utils.js";
import { parseBridgePort } from "./bridge-port.js";
import { listenForStartup } from "./server-listen.js";
import { ArtifactStore } from "./artifact-store.js";
import { ArtifactHttpHandler } from "./artifact-http.js";
import { resolveArtifactBaseUrl } from "./artifact-url.js";
import { ArtifactRegistry } from "./artifact-registry.js";
import { ArtifactManager } from "./artifact-manager.js";
import { GeneratedArtifactStore } from "./generated-artifact-store.js";
import { initializeFileTransferRuntime } from "./file-transfer-runtime.js";
import { FileBrowserManager } from "./file-browser-manager.js";
import {
  FileMutationAuthorizer,
  FileMutationAuthStore,
} from "./file-mutation-auth.js";
import {
  BridgeApiKeyAuthenticator,
  requiresPrivateHttpAuthorization,
} from "./bridge-http-auth.js";
import { readCodexAppServerMode } from "./codex-app-server-config.js";
import { codexSourceIdentity } from "./codex-home.js";
import {
  actionBrokerFileForSource,
  CodexActionBroker,
} from "./codex-action-broker.js";
import { CodexActionBrokerRuntime } from "./codex-action-broker-runtime.js";
import { CodexActionBrokerWriterLease } from "./codex-action-broker-writer-lease.js";
import { CodexSharedRuntimeControl } from "./codex-shared-runtime-control.js";
import { sharedRuntimePilotAttachmentCount } from "./codex-shared-runtime-pilot.js";
import {
  TerminalResultLedger,
  terminalResultLedgerFileForPort,
} from "./local-features/terminal-result-ledger.js";
import {
  InputDeliveryLedger,
  inputDeliveryLedgerFileForPort,
} from "./input-delivery-ledger.js";
import { bridgeReadinessSnapshot } from "./bridge-readiness.js";
import {
  assertSecureBridgeBinding,
  DEFAULT_BRIDGE_HOST,
} from "./bridge-bind-security.js";
import { resolveBridgeConnectionAuthentication } from "./bridge-connection-auth.js";
import { BridgeIdentityStore, isValidIdentityNonce } from "./bridge-identity.js";
import { BridgeDevicePairing } from "./bridge-device-pairing.js";

function startupErrorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export async function startServer() {
  installProcessGuards();
  const PORT = parseBridgePort();
  const HOST = process.env.BRIDGE_HOST ?? DEFAULT_BRIDGE_HOST;
  const connectionAuthentication = resolveBridgeConnectionAuthentication({
    apiKey: process.env.BRIDGE_API_KEY,
    requireApiKey: process.env.BRIDGE_REQUIRE_API_KEY,
    authMode: process.env.BRIDGE_AUTH_MODE,
  });
  const API_KEY = connectionAuthentication.effectiveApiKey;
  const bridgeIdentity = await BridgeIdentityStore.load();
  assertSecureBridgeBinding({
    host: HOST,
    apiKey: API_KEY,
    authMode: connectionAuthentication.mode,
    allowUnauthenticatedRemote:
      process.env.BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE === "1" ||
      (connectionAuthentication.explicitlyConfigured &&
        !connectionAuthentication.required),
  });
  const bridgeAuthenticator = new BridgeApiKeyAuthenticator(API_KEY);
  const {
    fullDiskReadRequested: FULL_DISK_READ_REQUESTED,
    ownerFullDiskRead: OWNER_FULL_DISK_READ,
    allowedDirs: ALLOWED_DIRS,
  } = resolveOwnerFileAccessPolicy(
    process.env.BRIDGE_ALLOWED_DIRS,
    API_KEY,
    process.platform,
    [homedir()],
    connectionAuthentication.mode === "paired_or_key",
  );
  const MDNS_ENABLED = shouldAdvertiseMdns(
    process.platform,
    !!process.env.BRIDGE_DISABLE_MDNS,
  );

  console.log("[bridge] Starting ccpocket bridge server...");

  const codexAppServerMode = readCodexAppServerMode();
  let sharedRuntimeControl: CodexSharedRuntimeControl | undefined;
  let codexActionBrokerRuntime: CodexActionBrokerRuntime | undefined;
  if (codexAppServerMode === "daemon") {
    const codexSourceId = codexSourceIdentity();
    sharedRuntimeControl = new CodexSharedRuntimeControl({
      projectPath: ALLOWED_DIRS[0] ?? homedir(),
    });
    const actionBroker = new CodexActionBroker({
      filePath: actionBrokerFileForSource(
        codexSourceId,
        process.env.CCPOCKET_CODEX_ACTION_BROKER_STATE_FILE,
      ),
    });
    const actionBrokerWriterLease = new CodexActionBrokerWriterLease(
      codexSourceId,
    );
    codexActionBrokerRuntime = new CodexActionBrokerRuntime(
      actionBroker,
      sharedRuntimeControl,
      codexSourceId,
      actionBrokerWriterLease,
    );
    await codexActionBrokerRuntime.start();
    sharedRuntimeControl.on("diagnostic", (diagnostic) => {
      console.warn(`[bridge] Shared Codex runtime: ${diagnostic}`);
    });
    sharedRuntimeControl.start();
    try {
      await sharedRuntimeControl.waitUntilReady(20_000);
    } catch (error) {
      sharedRuntimeControl.stop();
      await codexActionBrokerRuntime.close();
      throw new Error(
        `Shared Codex runtime is not ready: ${startupErrorMessage(error)}`,
      );
    }
    await codexActionBrokerRuntime.flush();
    console.log("[bridge] Shared Codex runtime control observer ready");
  }

  console.log(
    `[bridge] Connection authentication mode: ${connectionAuthentication.mode}`,
  );
  if (FULL_DISK_READ_REQUESTED && !OWNER_FULL_DISK_READ) {
    console.warn(
      "[bridge] Full-disk phone browsing and out-of-project artifact previews " +
        "require BRIDGE_API_KEY; keeping those owner surfaces scoped to Home/session roots",
    );
  }

  if (!MDNS_ENABLED) {
    console.log(
      process.platform === "darwin"
        ? "[bridge] mDNS advertisement disabled on macOS"
        : "[bridge] mDNS advertisement disabled",
    );
  }

  console.log(
    `[bridge] Allowed dirs: ${
      ALLOWED_DIRS.length > 0 ? ALLOWED_DIRS.join(", ") : "(unrestricted)"
    }`,
  );

  const autoArtifactsEnabled = !["0", "false", "off"].includes(
    (process.env.BRIDGE_AUTO_ARTIFACTS ?? "").trim().toLowerCase(),
  );
  const generatedArtifactStore = autoArtifactsEnabled
    ? new GeneratedArtifactStore()
    : undefined;
  const artifactAllowedDirs =
    ALLOWED_DIRS.length === 0
      ? []
      : [
          ...new Set([
            ...ALLOWED_DIRS,
            ...(generatedArtifactStore
              ? [generatedArtifactStore.directory]
              : []),
          ]),
        ];
  const artifactBaseUrl = resolveArtifactBaseUrl({
    port: PORT,
    host: HOST,
    explicitBaseUrl: process.env.BRIDGE_ARTIFACT_BASE_URL,
    publicWsUrl: process.env.BRIDGE_PUBLIC_WS_URL,
  });
  const artifactStore = new ArtifactStore({
    baseUrl: artifactBaseUrl,
    allowedDirs: artifactAllowedDirs,
  });
  let artifactManager: ArtifactManager | undefined;
  if (autoArtifactsEnabled) {
    try {
      const artifactRegistry = new ArtifactRegistry({
        port: PORT,
        ...(process.env.BRIDGE_ARTIFACT_REGISTRY_FILE?.trim()
          ? { filePath: process.env.BRIDGE_ARTIFACT_REGISTRY_FILE.trim() }
          : {}),
      });
      // Finish disk recovery before any session can register a candidate.
      await artifactRegistry.init();
      artifactManager = new ArtifactManager({
        store: artifactStore,
        registry: artifactRegistry,
        generatedArtifactStore,
        allowUnscopedRead: OWNER_FULL_DISK_READ,
      });
      console.log("[bridge] Automatic artifact links enabled");
    } catch (error) {
      console.warn(
        `[bridge] Automatic artifact links disabled: ${startupErrorMessage(error)}`,
      );
    }
  } else {
    console.log("[bridge] Automatic artifact links disabled by configuration");
  }
  const artifactHttp = new ArtifactHttpHandler(
    artifactStore,
    (req) => bridgeAuthenticator.acceptsPrivateHttpRequest(req),
  );
  if (artifactBaseUrl) {
    console.log(
      `[bridge] Artifact previews: ${artifactBaseUrl}/artifacts/<token>`,
    );
  } else {
    console.warn(
      "[bridge] Artifact preview URL unavailable; share with --base-url",
    );
  }

  // Initialize Firebase Anonymous Auth for push notifications. The explicit
  // kill switch is evaluated before constructing the client so isolated
  // candidates cannot read Firebase credentials or contact Cloud services.
  const firebaseAuth = await initializePushRuntime({
    createClient: () => new FirebaseAuthClient(),
  });

  const imageStore = new ImageStore();
  const galleryStore = new GalleryStore();
  const projectHistory = new ProjectHistory();
  const debugTraceStore = new DebugTraceStore();
  const RECORDING_ENABLED = !!process.env.BRIDGE_RECORDING;
  const recordingStore = RECORDING_ENABLED ? new RecordingStore() : undefined;
  const promptHistoryBackup = new PromptHistoryBackupStore();
  const promptHistoryStore = new PromptHistoryStore(
    promptHistoryStoreFileForPort(PORT, process.env.BRIDGE_PROMPT_HISTORY_FILE),
  );
  let terminalResultLedger: TerminalResultLedger | undefined;
  let terminalResultLedgerStartupFailure:
    { lastFailureAt: string; lastError: string } | undefined;
  try {
    const candidate = new TerminalResultLedger(
      terminalResultLedgerFileForPort(
        PORT,
        process.env.BRIDGE_TERMINAL_RESULT_LEDGER_FILE,
      ),
    );
    await candidate.init();
    terminalResultLedger = candidate;
  } catch (error) {
    terminalResultLedgerStartupFailure = {
      lastFailureAt: new Date().toISOString(),
      lastError: error instanceof Error ? error.name : "UnknownError",
    };
    console.warn(
      `[bridge] Terminal result persistence disabled: ${startupErrorMessage(error)}`,
    );
  }
  const terminalResultPersistenceHealth = () =>
    terminalResultLedger?.health ?? {
      initialized: false,
      ready: false,
      degraded: true,
      ...(terminalResultLedgerStartupFailure ?? {
        lastError: "Unavailable",
      }),
    };
  const mdns = MDNS_ENABLED ? new MdnsAdvertiser() : undefined;

  // Gallery history repair depends on the persisted index being loaded before
  // WebSocket clients can request canonical history.
  await galleryStore
    .init()
    .then(() => {
      console.log("[bridge] Gallery store initialized");
    })
    .catch((err) => {
      console.error("[bridge] Failed to initialize gallery store:", err);
    });

  projectHistory
    .init()
    .then(() => {
      console.log("[bridge] Project history initialized");
    })
    .catch((err) => {
      console.error("[bridge] Failed to initialize project history:", err);
    });

  debugTraceStore
    .init()
    .then(() => {
      console.log("[bridge] Debug trace store initialized");
    })
    .catch((err) => {
      console.error("[bridge] Failed to initialize debug trace store:", err);
    });

  if (recordingStore) {
    recordingStore
      .init()
      .then(() => {
        console.log("[bridge] Recording enabled");
      })
      .catch((err) => {
        console.error("[bridge] Failed to initialize recording store:", err);
      });
  }

  promptHistoryBackup
    .init()
    .then(() => {
      console.log("[bridge] Prompt history backup store initialized");
    })
    .catch((err) => {
      console.error(
        "[bridge] Failed to initialize prompt history backup store:",
        err,
      );
    });

  let promptHistoryStoreReady = false;
  await promptHistoryStore
    .init()
    .then(() => {
      promptHistoryStoreReady = true;
      console.log("[bridge] Prompt history store initialized");
    })
    .catch((err) => {
      console.error("[bridge] Failed to initialize prompt history store:", err);
    });

  let devicePairing: BridgeDevicePairing | undefined;
  if (promptHistoryStoreReady && connectionAuthentication.mode === "paired_or_key") {
    try {
      devicePairing = new BridgeDevicePairing({
        bridgeIdentity,
        bridgeInstanceId: promptHistoryStore.bridgeInstanceId,
      });
      await devicePairing.init();
      console.log("[bridge] Ed25519 device pairing enabled");
    } catch (error) {
      console.warn(
        `[bridge] Device pairing unavailable: ${startupErrorMessage(error)}`,
      );
    }
  }

  const inputDeliveryLedger = new InputDeliveryLedger({
    filePath: inputDeliveryLedgerFileForPort(
      PORT,
      process.env.BRIDGE_INPUT_DELIVERY_LEDGER_FILE,
    ),
  });
  let inputDeliveryIdentityFailure:
    { lastFailureAt: string; lastError: string } | undefined;
  if (promptHistoryStoreReady) {
    try {
      await inputDeliveryLedger.init();
      console.log("[bridge] Durable Codex input delivery initialized");
    } catch (error) {
      console.warn(
        `[bridge] Durable Codex input delivery unavailable: ${startupErrorMessage(error)}`,
      );
    }
  } else {
    inputDeliveryIdentityFailure = {
      lastFailureAt: new Date().toISOString(),
      lastError: "BridgeIdentityUnavailable",
    };
    console.warn(
      "[bridge] Durable Codex input delivery unavailable because the stable Bridge identity could not be loaded",
    );
  }
  const inputDeliveryPersistenceHealth = () =>
    inputDeliveryIdentityFailure
      ? {
          ...inputDeliveryLedger.health,
          initialized: false,
          ready: false,
          degraded: true,
          ...inputDeliveryIdentityFailure,
        }
      : inputDeliveryLedger.health;
  const currentReadiness = () =>
    bridgeReadinessSnapshot({
      codexRuntimeMode: codexAppServerMode,
      sharedRuntimeControlReady: sharedRuntimeControl?.ready,
      actionBroker: codexActionBrokerRuntime?.health,
      terminalResults: terminalResultPersistenceHealth(),
      inputDelivery: inputDeliveryPersistenceHealth(),
    });

  let fileMutationAuthorizer: FileMutationAuthorizer | undefined;
  const candidate = new FileMutationAuthorizer({
    bridgeInstanceId: promptHistoryStore.bridgeInstanceId,
    store: new FileMutationAuthStore(),
  });
  try {
    await candidate.init();
    const state = await candidate.status();
    fileMutationAuthorizer = candidate;
    console.log(
      state.passwordConfigured
        ? "[bridge] File mutation step-up authorization enabled"
        : "[bridge] File mutation uploads locked until a Bridge password is configured",
    );
  } catch (error) {
    console.error(
      `[bridge] File mutation authorization unavailable: ${startupErrorMessage(error)}`,
    );
  }

  let fileTransferRuntime = await initializeFileTransferRuntime({
    port: PORT,
    bridgeInstanceId: promptHistoryStore.bridgeInstanceId,
    allowedDirs: ALLOWED_DIRS,
    baseUrl: artifactBaseUrl,
    stateFilePath: process.env.BRIDGE_FILE_TRANSFER_STATE_FILE?.trim(),
    downloadDirectory: process.env.BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR?.trim(),
    partialDirectory: process.env.BRIDGE_FILE_TRANSFER_PARTIAL_DIR?.trim(),
    fileMutationAuthorizer,
    warn: (message) => console.warn(`[bridge] ${message}`),
  });
  let fileTransfer = fileTransferRuntime?.manager;
  let fileTransferHttp = fileTransferRuntime?.http;

  if (!fileMutationAuthorizer && fileTransferRuntime) {
    console.warn(
      "[bridge] Phone uploads are locked because mutation authorization " +
        "could not start; read-only file transfer remains available",
    );
  }

  let fileBrowser: FileBrowserManager | undefined;
  try {
    fileBrowser = new FileBrowserManager({
      bridgeInstanceId: promptHistoryStore.bridgeInstanceId,
      allowedDirs: ALLOWED_DIRS,
      allowFilesystemRoot: OWNER_FULL_DISK_READ,
      artifactStore,
      fileTransferManager: fileTransfer,
      fileMutationAuthorizer,
    });
    await fileBrowser.init();
    console.log("[bridge] Root-scoped phone file browser enabled");
  } catch (error) {
    await fileBrowser?.close();
    fileBrowser = undefined;
    if (fileMutationAuthorizer && fileTransferRuntime) {
      await fileTransferHttp?.close();
      await fileTransfer?.close();
      fileTransferRuntime = undefined;
      fileTransfer = undefined;
      fileTransferHttp = undefined;
      fileMutationAuthorizer = undefined;
      console.warn(
        "[bridge] Phone uploads disabled because their mutation authorization " +
          "surface could not start; read-only chat remains available",
      );
    }
    console.warn(
      `[bridge] Phone file browser disabled; chat remains available: ${startupErrorMessage(error)}`,
    );
  }
  if (fileTransferRuntime) {
    console.log("[bridge] Resumable phone file transfer enabled");
  }

  const startedAt = Date.now();
  let wsServer: BridgeWebSocketServer | null = null;

  const httpServer = createServer((req, res) => {
    // Transfer control and byte routes use their own strict origin/token gates.
    if (fileTransferHttp?.handleRequest(req, res)) return;
    // Artifact routes intentionally do not inherit the permissive CORS policy.
    if (artifactHttp.handleRequest(req, res)) return;

    // CORS headers for Flutter Web clients
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
    res.setHeader(
      "Access-Control-Allow-Headers",
      "Authorization, Content-Type",
    );

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    if (req.url?.split("?", 1)[0] === "/bridge/identity" && req.method === "GET") {
      let nonce: string | null = null;
      try {
        nonce = new URL(req.url, "http://bridge.invalid").searchParams.get("nonce");
      } catch {
        nonce = null;
      }
      if (!nonce || !isValidIdentityNonce(nonce) || !promptHistoryStoreReady) {
        res.writeHead(400, {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        });
        res.end(JSON.stringify({ error: "invalid_nonce" }));
        return;
      }
      const methods = [
        ...(API_KEY ? ["api_key"] : []),
        ...(devicePairing ? ["device_signature", "pairing_token"] : []),
        ...(connectionAuthentication.mode === "open" ? ["none"] : []),
      ];
      const proof = bridgeIdentity.response({
        nonce,
        bridgeInstanceId: promptHistoryStore.bridgeInstanceId,
        authMode: connectionAuthentication.mode,
        methods,
      });
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
        Pragma: "no-cache",
      });
      res.end(JSON.stringify({ ...proof, pairingAvailable: !!devicePairing }));
      return;
    }

    if (
      requiresPrivateHttpAuthorization(req.method, req.url, {
        // Open mode is an explicit trusted-LAN development choice. Mobile
        // still needs the read-only readiness contract before entering the
        // application, while every other private HTTP surface remains closed.
        allowOpenModeReadiness: connectionAuthentication.mode === "open",
      }) &&
      !bridgeAuthenticator.acceptsPrivateHttpRequest(req)
    ) {
      bridgeAuthenticator.rejectPrivateHttpRequest(req, res);
      return;
    }

    // Health check endpoint
    if (req.url === "/health" && req.method === "GET") {
      const readiness = currentReadiness();
      const body = JSON.stringify({
        status: "ok",
        bridgeAuthentication: {
          required: connectionAuthentication.required,
          scheme:
            connectionAuthentication.mode === "paired_or_key"
              ? "api_key_or_device_signature"
              : connectionAuthentication.required
                ? "api_key"
                : "none",
          mode: connectionAuthentication.mode,
          methods: [
            ...(API_KEY ? ["api_key"] : []),
            ...(devicePairing ? ["device_signature", "pairing_token"] : []),
            ...(connectionAuthentication.mode === "open" ? ["none"] : []),
          ],
          pairingAvailable: !!devicePairing,
        },
        applicationReady: readiness.ready,
        degradedReasons: readiness.reasons,
        degradedFeatures: readiness.degradedFeatures,
        uptime: Math.floor((Date.now() - startedAt) / 1000),
        sessions: wsServer?.sessionCount ?? 0,
        clients: wsServer?.clientCount ?? 0,
        ...(sharedRuntimeControl
          ? {
              codexRuntime: {
                mode: "daemon",
                ready: sharedRuntimeControl.ready,
                connectionGeneration: sharedRuntimeControl.connectionGeneration,
                actionBroker: codexActionBrokerRuntime?.health,
                terminalResults: terminalResultPersistenceHealth(),
                inputDelivery: inputDeliveryPersistenceHealth(),
              },
            }
          : {
              terminalResults: terminalResultPersistenceHealth(),
              inputDelivery: inputDeliveryPersistenceHealth(),
            }),
      });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
      return;
    }

    if (req.url === "/livez" && req.method === "GET") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "live" }));
      return;
    }

    if (req.url === "/readyz" && req.method === "GET") {
      const readiness = currentReadiness();
      const ready = readiness.ready;
      res.writeHead(ready ? 200 : 503, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      res.end(
        JSON.stringify({
          status: ready ? "ready" : "not_ready",
          reasons: readiness.reasons,
          degradedFeatures: readiness.degradedFeatures,
          codexRuntimeMode: codexAppServerMode,
          ...(codexActionBrokerRuntime
            ? { actionBroker: codexActionBrokerRuntime.health }
            : {}),
          terminalResults: terminalResultPersistenceHealth(),
          inputDelivery: inputDeliveryPersistenceHealth(),
        }),
      );
      return;
    }

    if (req.url === "/pilot/diagnostics" && req.method === "GET") {
      if (!sharedRuntimeControl) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({ error: "Shared runtime pilot is not active" }),
        );
        return;
      }
      const gates = sharedRuntimeControl.pilotGates;
      const readiness = currentReadiness();
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      res.end(
        JSON.stringify({
          ready: sharedRuntimeControl.ready,
          applicationReady: readiness.ready,
          readinessReasons: readiness.reasons,
          connectionGeneration: sharedRuntimeControl.connectionGeneration,
          daemon: sharedRuntimeControl.daemonIdentity,
          attachments: sharedRuntimePilotAttachmentCount(),
          gates: {
            allowThreadStart: gates.allowThreadStart,
            allowTurnStart: gates.allowTurnStart,
          },
          events: sharedRuntimeControl.events,
          actionBroker: codexActionBrokerRuntime?.health,
          terminalResults: terminalResultPersistenceHealth(),
          inputDelivery: inputDeliveryPersistenceHealth(),
        }),
      );
      return;
    }

    // Version info endpoint
    if (req.url === "/version" && req.method === "GET") {
      const body = JSON.stringify(getVersionInfo(startedAt));
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
      return;
    }

    // Usage endpoint
    if (req.url === "/usage" && req.method === "GET") {
      fetchAllUsage()
        .then((providers) => {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ providers }));
        })
        .catch((err) => {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: String(err) }));
        });
      return;
    }

    // Doctor endpoint
    if (req.url === "/doctor" && req.method === "GET") {
      runDoctor()
        .then((report) => {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify(report));
        })
        .catch((err) => {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: String(err) }));
        });
      return;
    }

    // Serve images via ImageStore (in-memory, session-scoped)
    if (imageStore.handleRequest(req, res)) return;

    // Serve gallery images via GalleryStore (disk-persistent)
    if (galleryStore.handleRequest(req, res)) return;

    // Upload images via POST /api/gallery/upload
    if (
      galleryStore.handleUploadRequest(req, res, (meta) => {
        if (wsServer) {
          const info = galleryStore.metaToInfo(meta);
          wsServer.broadcastGalleryNewImage(info);
        }
      })
    )
      return;

    // Default 404 for unknown HTTP requests
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not Found");
  });

  try {
    wsServer = new BridgeWebSocketServer({
      server: httpServer,
      apiKey: API_KEY,
      apiKeyAuthenticator: bridgeAuthenticator,
      authMode: connectionAuthentication.mode,
      bridgeIdentity,
      devicePairing,
      ownerFullDiskRead: OWNER_FULL_DISK_READ,
      allowedDirs: ALLOWED_DIRS,
      imageStore,
      galleryStore,
      projectHistory,
      debugTraceStore,
      recordingStore,
      firebaseAuth,
      promptHistoryBackup,
      promptHistoryStore,
      artifactManager,
      fileTransfer,
      fileBrowser,
      fileMutationAuthorizer,
      sharedRuntimeControl,
      codexActionBrokerRuntime,
      terminalResultLedger,
      inputDeliveryLedger,
    });
  } catch (error) {
    await codexActionBrokerRuntime?.close();
    sharedRuntimeControl?.stop();
    await fileBrowser?.close();
    artifactStore.close();
    await fileTransferHttp?.close();
    await fileTransfer?.close();
    httpServer.close();
    throw error;
  }

  let shutdownStarted = false;
  async function shutdown(): Promise<void> {
    if (shutdownStarted) return;
    shutdownStarted = true;
    console.log("\n[bridge] Shutting down gracefully...");
    // Reject new provider writes immediately, but retain the source-global
    // writer lease until WebSocket handlers and Codex processes have drained.
    // Releasing the lease first would let a warm standby overlap this Bridge.
    codexActionBrokerRuntime?.beginDraining();
    mdns?.stop();
    artifactStore.close();
    await fileTransferHttp?.close();
    await wsServer?.close();
    await codexActionBrokerRuntime?.close();
    sharedRuntimeControl?.stop();
    await new Promise<void>((resolve) => httpServer.close(() => resolve()));
    process.exit(0);
  }

  try {
    await listenForStartup(httpServer, PORT, HOST);
  } catch (err) {
    await codexActionBrokerRuntime?.close();
    sharedRuntimeControl?.stop();
    artifactStore.close();
    await fileTransferHttp?.close();
    if (wsServer) await wsServer.close();
    else await fileTransfer?.close();
    httpServer.close();
    throw err;
  }

  console.log(
    `[bridge] Ready. Listening on http://${HOST}:${PORT} (HTTP + WebSocket)`,
  );
  mdns?.start(PORT, API_KEY);
  printStartupInfo(PORT, HOST, API_KEY, {
    pairingAvailable: !!devicePairing,
  });

  process.on("SIGINT", () => {
    void shutdown();
  });
  process.on("SIGTERM", () => {
    void shutdown();
  });
}

// Auto-start when executed directly (node dist/index.js, tsx src/index.ts)
const isDirectExecution =
  process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];

if (isDirectExecution) {
  setupProxy();
  startServer().catch((err) => {
    console.error(`[bridge] Failed to start: ${startupErrorMessage(err)}`);
    process.exit(1);
  });
}
