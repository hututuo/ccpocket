import { createServer } from "node:http";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { setupProxy } from "./proxy.js";
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
import { PromptHistoryBackupStore } from "./prompt-history-backup.js";
import {
  promptHistoryStoreFileForPort,
  PromptHistoryStore,
} from "./prompt-history-store.js";
import { parseAllowedDirectories } from "./path-utils.js";
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

function startupErrorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export async function startServer() {
  const PORT = parseBridgePort();
  const HOST = process.env.BRIDGE_HOST ?? "0.0.0.0";
  const API_KEY = process.env.BRIDGE_API_KEY;
  const bridgeAuthenticator = new BridgeApiKeyAuthenticator(API_KEY);
  const FULL_DISK_READ_REQUESTED =
    process.env.BRIDGE_ALLOWED_DIRS?.trim() === "*";
  const OWNER_FULL_DISK_READ =
    FULL_DISK_READ_REQUESTED && Boolean(API_KEY?.trim());
  const MDNS_ENABLED = shouldAdvertiseMdns(
    process.platform,
    !!process.env.BRIDGE_DISABLE_MDNS,
  );

  // Unrestricted access requires the exact value "*".
  const ALLOWED_DIRS = parseAllowedDirectories(
    process.env.BRIDGE_ALLOWED_DIRS,
    process.platform,
    [homedir()],
  );

  console.log("[bridge] Starting ccpocket bridge server...");

  if (API_KEY) {
    console.log("[bridge] API key authentication enabled");
  }
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
  const artifactHttp = new ArtifactHttpHandler(artifactStore);
  if (artifactBaseUrl) {
    console.log(
      `[bridge] Artifact previews: ${artifactBaseUrl}/artifacts/<token>`,
    );
  } else {
    console.warn(
      "[bridge] Artifact preview URL unavailable; share with --base-url",
    );
  }

  // Initialize Firebase Anonymous Auth for push notifications
  let firebaseAuth: FirebaseAuthClient | undefined;
  try {
    firebaseAuth = new FirebaseAuthClient();
    await firebaseAuth.initialize();
    console.log("[bridge] Push relay enabled (Firebase Anonymous Auth)");
  } catch (err) {
    console.warn("[bridge] Push relay disabled: Firebase auth failed:", err);
    firebaseAuth = undefined;
  }

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

  await promptHistoryStore
    .init()
    .then(() => {
      console.log("[bridge] Prompt history store initialized");
    })
    .catch((err) => {
      console.error("[bridge] Failed to initialize prompt history store:", err);
    });

  let fileMutationAuthorizer: FileMutationAuthorizer | undefined;
  if (API_KEY?.trim()) {
    const candidate = new FileMutationAuthorizer({
      bridgeInstanceId: promptHistoryStore.bridgeInstanceId,
      store: new FileMutationAuthStore(),
    });
    try {
      await candidate.init();
      const state = await candidate.status();
      if (OWNER_FULL_DISK_READ || state.passwordConfigured) {
        fileMutationAuthorizer = candidate;
        console.log(
          state.passwordConfigured
            ? "[bridge] File mutation step-up authorization enabled"
            : "[bridge] File mutation uploads locked until a Bridge password is configured",
        );
      }
    } catch (error) {
      console.error(
        `[bridge] File mutation authorization unavailable: ${startupErrorMessage(error)}`,
      );
    }
  }

  let fileTransferRuntime =
    OWNER_FULL_DISK_READ && !fileMutationAuthorizer
      ? undefined
      : await initializeFileTransferRuntime({
          port: PORT,
          bridgeInstanceId: promptHistoryStore.bridgeInstanceId,
          allowedDirs: ALLOWED_DIRS,
          baseUrl: artifactBaseUrl,
          stateFilePath: process.env.BRIDGE_FILE_TRANSFER_STATE_FILE?.trim(),
          downloadDirectory:
            process.env.BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR?.trim(),
          partialDirectory:
            process.env.BRIDGE_FILE_TRANSFER_PARTIAL_DIR?.trim(),
          fileMutationAuthorizer,
          warn: (message) => console.warn(`[bridge] ${message}`),
        });
  let fileTransfer = fileTransferRuntime?.manager;
  let fileTransferHttp = fileTransferRuntime?.http;

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

    if (
      requiresPrivateHttpAuthorization(req.method, req.url) &&
      !bridgeAuthenticator.acceptsPrivateHttpRequest(req)
    ) {
      bridgeAuthenticator.rejectPrivateHttpRequest(req, res);
      return;
    }

    // Health check endpoint
    if (req.url === "/health" && req.method === "GET") {
      const body = JSON.stringify({
        status: "ok",
        uptime: Math.floor((Date.now() - startedAt) / 1000),
        sessions: wsServer?.sessionCount ?? 0,
        clients: wsServer?.clientCount ?? 0,
      });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
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
    });
  } catch (error) {
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
    mdns?.stop();
    artifactStore.close();
    await fileTransferHttp?.close();
    await wsServer?.close();
    await new Promise<void>((resolve) => httpServer.close(() => resolve()));
    process.exit(0);
  }

  try {
    await listenForStartup(httpServer, PORT, HOST);
  } catch (err) {
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
  printStartupInfo(PORT, HOST, API_KEY);

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
