import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const mockExecSync = vi.fn();
vi.mock("node:child_process", () => ({
  execSync: (...args: unknown[]) => mockExecSync(...args),
}));

const mockExistsSync = vi.fn();
const mockMkdirSync = vi.fn();
const mockWriteFileSync = vi.fn();
const mockUnlinkSync = vi.fn();
vi.mock("node:fs", () => ({
  existsSync: (...args: unknown[]) => mockExistsSync(...args),
  mkdirSync: (...args: unknown[]) => mockMkdirSync(...args),
  writeFileSync: (...args: unknown[]) => mockWriteFileSync(...args),
  unlinkSync: (...args: unknown[]) => mockUnlinkSync(...args),
}));

vi.mock("node:os", () => ({
  homedir: () => "/Users/testuser",
}));

const { setupLaunchd, uninstallLaunchd } = await import("./setup-launchd.js");

const PLIST_PATH =
  "/Users/testuser/Library/LaunchAgents/com.ccpocket.bridge.plist";
const originalBridgeEnv = {
  port: process.env.BRIDGE_PORT,
  host: process.env.BRIDGE_HOST,
  apiKey: process.env.BRIDGE_API_KEY,
  authMode: process.env.BRIDGE_AUTH_MODE,
  requireApiKey: process.env.BRIDGE_REQUIRE_API_KEY,
  allowUnauthenticatedRemote: process.env.BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE,
  allowUnauthenticatedDiagnostics:
    process.env.BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS,
  allowedDirs: process.env.BRIDGE_ALLOWED_DIRS,
  publicWsUrl: process.env.BRIDGE_PUBLIC_WS_URL,
  artifactBaseUrl: process.env.BRIDGE_ARTIFACT_BASE_URL,
  autoArtifacts: process.env.BRIDGE_AUTO_ARTIFACTS,
  artifactRegistryFile: process.env.BRIDGE_ARTIFACT_REGISTRY_FILE,
  fileTransferDownloadDir: process.env.BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR,
  fileTransferPartialDir: process.env.BRIDGE_FILE_TRANSFER_PARTIAL_DIR,
  fileTransferStateFile: process.env.BRIDGE_FILE_TRANSFER_STATE_FILE,
  disableMdns: process.env.BRIDGE_DISABLE_MDNS,
  codexAssistModel: process.env.BRIDGE_CODEX_ASSIST_MODEL,
  codexAssistReasoningEffort: process.env.BRIDGE_CODEX_ASSIST_REASONING_EFFORT,
  codexHome: process.env.CODEX_HOME,
  codexSourceId: process.env.BRIDGE_CODEX_SOURCE_ID,
  codexAppServerMode: process.env.BRIDGE_CODEX_APP_SERVER_MODE,
  codexSharedAppServerUrl: process.env.BRIDGE_CODEX_SHARED_APP_SERVER_URL,
  codexAppServerPort: process.env.BRIDGE_CODEX_APP_SERVER_PORT,
  codexAppServerUrl: process.env.BRIDGE_CODEX_APP_SERVER_URL,
};

describe("setup-launchd", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    clearBridgeEnv();
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue("/usr/bin/npx\n");
  });

  afterEach(() => {
    restoreBridgeEnv();
  });

  describe("setupLaunchd", () => {
    it("writes correct plist with default options", () => {
      setupLaunchd({});

      expect(mockWriteFileSync).toHaveBeenCalledOnce();
      const [path, content] = mockWriteFileSync.mock.calls[0] as [
        string,
        string,
      ];
      expect(path).toBe(PLIST_PATH);
      expect(content).toContain("<key>BRIDGE_PORT</key>");
      expect(content).toContain("<string>8765</string>");
      expect(content).toContain("<key>BRIDGE_HOST</key>");
      expect(content).toContain("<string>127.0.0.1</string>");
      expect(content).toContain("<key>BRIDGE_REQUIRE_API_KEY</key>");
      expect(content).toContain("<string>0</string>");
      expect(content).toContain("<key>BRIDGE_AUTH_MODE</key>");
      expect(content).toContain("<string>open</string>");
      expect(content).toContain(
        '<string>exec node "$BRIDGE_CLI_ENTRY"</string>',
      );
      expect(content).toContain("<key>BRIDGE_CLI_ENTRY</key>");
      expect(content).toContain("/src/cli.js</string>");
      expect(content).not.toContain("BRIDGE_API_KEY");
      expect(content).not.toContain("BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE");
      expect(content).not.toContain(
        "BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS",
      );
      expect(content).not.toContain("BRIDGE_ALLOWED_DIRS");
      expect(content).not.toContain("BRIDGE_PUBLIC_WS_URL");
      expect(content).not.toContain("BRIDGE_ARTIFACT_BASE_URL");
      expect(content).not.toContain("BRIDGE_AUTO_ARTIFACTS");
      expect(content).not.toContain("BRIDGE_ARTIFACT_REGISTRY_FILE");
      expect(content).not.toContain("BRIDGE_FILE_TRANSFER_");
      expect(content).not.toContain("BRIDGE_DISABLE_MDNS");
      expect(content).not.toContain("BRIDGE_CODEX_ASSIST_MODEL");
      expect(content).not.toContain("BRIDGE_CODEX_ASSIST_REASONING_EFFORT");
      expect(content).not.toContain("<key>CODEX_HOME</key>");
      expect(content).not.toContain("BRIDGE_CODEX_SOURCE_ID");
      expect(content).not.toContain("BRIDGE_CODEX_APP_SERVER_MODE");
      expect(content).not.toContain("BRIDGE_CODEX_SHARED_APP_SERVER_URL");
    });

    it("persists an explicit enabled connection-key toggle", () => {
      setupLaunchd({ apiKey: "owner-key", requireApiKey: true });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_REQUIRE_API_KEY</key>");
      expect(content).toContain("<string>1</string>");
      expect(content).toContain("<key>BRIDGE_API_KEY</key>");
      expect(content).toContain("<string>owner-key</string>");
    });

    it("retains the key while explicitly disabling authentication", () => {
      setupLaunchd({ apiKey: "owner-key", requireApiKey: false });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_REQUIRE_API_KEY</key>");
      expect(content).toContain("<string>0</string>");
      expect(content).toContain("<string>owner-key</string>");
    });

    it("preserves an explicit open mode even when a saved key remains", () => {
      setupLaunchd({
        apiKey: "owner-key",
        requireApiKey: true,
        authMode: "open",
      });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_AUTH_MODE</key>");
      expect(content).toContain("<string>open</string>");
      expect(content).toContain("<key>BRIDGE_API_KEY</key>");
      expect(content).toContain("<string>owner-key</string>");
    });

    it("treats an explicit disabled toggle as the remote-bind opt-in", () => {
      setupLaunchd({ host: "0.0.0.0", requireApiKey: false });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<string>0.0.0.0</string>");
      expect(content).toContain("<key>BRIDGE_REQUIRE_API_KEY</key>");
      expect(content).toContain("<string>0</string>");
    });

    it("rejects an enabled toggle without a configured key", () => {
      expect(() => setupLaunchd({ requireApiKey: true })).toThrow(
        /BRIDGE_API_KEY is empty/,
      );
      expect(mockWriteFileSync).not.toHaveBeenCalled();
    });

    it("rejects an unauthenticated remote host before writing the service", () => {
      expect(() => setupLaunchd({ host: "0.0.0.0" })).toThrow(/BRIDGE_API_KEY/);
      expect(mockWriteFileSync).not.toHaveBeenCalled();
      expect(mockExecSync).not.toHaveBeenCalled();
    });

    it("persists an explicit legacy unauthenticated remote opt-in", () => {
      process.env.BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE = "1";

      setupLaunchd({ host: "0.0.0.0" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<string>0.0.0.0</string>");
      expect(content).toContain(
        "<key>BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE</key>",
      );
      expect(content).toContain("<string>1</string>");
    });

    it("persists the explicit unauthenticated development diagnostics switch", () => {
      process.env.BRIDGE_AUTH_MODE = "open";
      process.env.BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS = "1";

      setupLaunchd({});

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain(
        "<key>BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS</key>",
      );
      expect(content).toContain("<string>1</string>");
    });

    it("rejects the diagnostics switch without an explicit open mode", () => {
      process.env.BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS = "1";

      expect(() => setupLaunchd({})).toThrow(
        "requires an explicit BRIDGE_AUTH_MODE=open",
      );
      expect(mockWriteFileSync).not.toHaveBeenCalled();
    });

    it.each(["", "123abc"])(
      "rejects invalid port %j before writing or registering a service",
      (port) => {
        expect(() => setupLaunchd({ port })).toThrow(
          `Invalid BRIDGE_PORT "${port}"`,
        );

        expect(mockWriteFileSync).not.toHaveBeenCalled();
        expect(mockExecSync).not.toHaveBeenCalled();
      },
    );

    it("includes BRIDGE_ALLOWED_DIRS when provided", () => {
      process.env.BRIDGE_ALLOWED_DIRS = "/Users/testuser,/tmp/work";

      setupLaunchd({});

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_ALLOWED_DIRS</key>");
      expect(content).toContain("<string>/Users/testuser,/tmp/work</string>");
    });

    it("persists Codex assist environment overrides", () => {
      process.env.BRIDGE_CODEX_ASSIST_MODEL = "gpt-oss:20b-cloud";
      process.env.BRIDGE_CODEX_ASSIST_REASONING_EFFORT = "low";

      setupLaunchd({});

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_CODEX_ASSIST_MODEL</key>");
      expect(content).toContain("<string>gpt-oss:20b-cloud</string>");
      expect(content).toContain(
        "<key>BRIDGE_CODEX_ASSIST_REASONING_EFFORT</key>",
      );
      expect(content).toContain("<string>low</string>");
    });

    it("persists the explicit Codex home used by app-server and readers", () => {
      process.env.CODEX_HOME = "/Users/testuser/Codex & Cockpit";

      setupLaunchd({});

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>CODEX_HOME</key>");
      expect(content).toContain(
        "<string>/Users/testuser/Codex &amp; Cockpit</string>",
      );
    });

    it("persists one validated shared Codex authority identity", () => {
      setupLaunchd({
        codexSourceId: "codex-source-0123456789abcdef0123456789abcdef",
      });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_CODEX_SOURCE_ID</key>");
      expect(content).toContain(
        "<string>codex-source-0123456789abcdef0123456789abcdef</string>",
      );
    });

    it("rejects an invalid Codex authority before replacing the service", () => {
      expect(() => setupLaunchd({ codexSourceId: "shared-main" })).toThrow(
        "BRIDGE_CODEX_SOURCE_ID must be",
      );
      expect(mockWriteFileSync).not.toHaveBeenCalled();
      expect(mockExecSync).not.toHaveBeenCalled();
    });

    it("includes BRIDGE_DISABLE_MDNS when requested", () => {
      setupLaunchd({ disableMdns: true });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_DISABLE_MDNS</key>");
      expect(content).toContain("<string>1</string>");
    });

    it("includes BRIDGE_PUBLIC_WS_URL when publicWsUrl is provided", () => {
      setupLaunchd({ publicWsUrl: "wss://example.com/ws" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_PUBLIC_WS_URL</key>");
      expect(content).toContain("<string>wss://example.com/ws</string>");
    });

    it("includes a validated artifact base URL", () => {
      setupLaunchd({ artifactBaseUrl: "http://192.168.1.20:8765" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_ARTIFACT_BASE_URL</key>");
      expect(content).toContain("<string>http://192.168.1.20:8765</string>");
    });

    it("rejects an invalid artifact base URL", () => {
      expect(() =>
        setupLaunchd({ artifactBaseUrl: "http://127.0.0.1:8765" }),
      ).toThrow("BRIDGE_ARTIFACT_BASE_URL");
      expect(mockWriteFileSync).not.toHaveBeenCalled();
    });

    it("persists automatic artifact rollback and registry settings", () => {
      process.env.BRIDGE_AUTO_ARTIFACTS = "0";
      process.env.BRIDGE_ARTIFACT_REGISTRY_FILE =
        "/Users/testuser/Library/Application Support/CC Pocket/registry&v1.json";

      setupLaunchd({});

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_AUTO_ARTIFACTS</key>");
      expect(content).toContain("<string>0</string>");
      expect(content).toContain("<key>BRIDGE_ARTIFACT_REGISTRY_FILE</key>");
      expect(content).toContain(
        "<string>/Users/testuser/Library/Application Support/CC Pocket/registry&amp;v1.json</string>",
      );
    });

    it("persists file-transfer storage paths with XML escaping", () => {
      process.env.BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR =
        "/Users/testuser/Phone & Files";
      process.env.BRIDGE_FILE_TRANSFER_PARTIAL_DIR =
        "/Users/testuser/.ccpocket/parts";
      process.env.BRIDGE_FILE_TRANSFER_STATE_FILE =
        "/Users/testuser/.ccpocket/state.json";
      setupLaunchd({});
      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR</key>");
      expect(content).toContain(
        "<string>/Users/testuser/Phone &amp; Files</string>",
      );
      expect(content).toContain("<key>BRIDGE_FILE_TRANSFER_PARTIAL_DIR</key>");
      expect(content).toContain("<key>BRIDGE_FILE_TRANSFER_STATE_FILE</key>");
    });

    it("prefers explicit publicWsUrl over environment", () => {
      process.env.BRIDGE_PUBLIC_WS_URL = "wss://env.example.com";

      setupLaunchd({ publicWsUrl: "wss://flag.example.com" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<string>wss://flag.example.com</string>");
      expect(content).not.toContain("wss://env.example.com");
    });

    it("does not persist shared app-server URL without an explicit mode", () => {
      process.env.BRIDGE_CODEX_SHARED_APP_SERVER_URL = "ws://127.0.0.1:18766";

      setupLaunchd({});

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).not.toContain("BRIDGE_CODEX_APP_SERVER_MODE");
      expect(content).not.toContain("BRIDGE_CODEX_SHARED_APP_SERVER_URL");
    });

    it("includes explicit Codex app-server startup options", () => {
      setupLaunchd({
        codexAppServerMode: "external",
        codexSharedAppServerUrl: "ws://127.0.0.1:18766",
      });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_CODEX_APP_SERVER_MODE</key>");
      expect(content).toContain("<string>external</string>");
      expect(content).toContain(
        "<key>BRIDGE_CODEX_SHARED_APP_SERVER_URL</key>",
      );
      expect(content).toContain("<string>ws://127.0.0.1:18766</string>");
      expect(content).not.toContain("BRIDGE_CODEX_APP_SERVER_PORT");
      expect(content).not.toContain("BRIDGE_CODEX_APP_SERVER_URL");
    });

    it("requires a shared app-server URL for external mode", () => {
      expect(() => setupLaunchd({ codexAppServerMode: "external" })).toThrow(
        "BRIDGE_CODEX_SHARED_APP_SERVER_URL is required",
      );
    });

    it("uses the documented default shared URL when managed mode is enabled", () => {
      setupLaunchd({ port: "8765", codexAppServerMode: "managed" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_PORT</key>");
      expect(content).toContain("<string>8765</string>");
      expect(content).toContain("<key>BRIDGE_CODEX_APP_SERVER_MODE</key>");
      expect(content).toContain("<string>managed</string>");
      expect(content).toContain(
        "<key>BRIDGE_CODEX_SHARED_APP_SERVER_URL</key>",
      );
      expect(content).toContain("<string>ws://127.0.0.1:8767</string>");
    });

    it("moves the default shared app-server URL when Bridge uses 8767", () => {
      setupLaunchd({ port: "8767", codexAppServerMode: "managed" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_PORT</key>");
      expect(content).toContain("<string>8767</string>");
      expect(content).toContain(
        "<key>BRIDGE_CODEX_SHARED_APP_SERVER_URL</key>",
      );
      expect(content).toContain("<string>ws://127.0.0.1:8768</string>");
    });
  });

  describe("uninstallLaunchd", () => {
    it("deletes plist when it exists", () => {
      mockExistsSync.mockReturnValue(true);

      uninstallLaunchd();

      expect(mockUnlinkSync).toHaveBeenCalledWith(PLIST_PATH);
    });
  });
});

function clearBridgeEnv(): void {
  delete process.env.BRIDGE_PORT;
  delete process.env.BRIDGE_HOST;
  delete process.env.BRIDGE_API_KEY;
  delete process.env.BRIDGE_AUTH_MODE;
  delete process.env.BRIDGE_REQUIRE_API_KEY;
  delete process.env.BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE;
  delete process.env.BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS;
  delete process.env.BRIDGE_ALLOWED_DIRS;
  delete process.env.BRIDGE_PUBLIC_WS_URL;
  delete process.env.BRIDGE_ARTIFACT_BASE_URL;
  delete process.env.BRIDGE_AUTO_ARTIFACTS;
  delete process.env.BRIDGE_ARTIFACT_REGISTRY_FILE;
  delete process.env.BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR;
  delete process.env.BRIDGE_FILE_TRANSFER_PARTIAL_DIR;
  delete process.env.BRIDGE_FILE_TRANSFER_STATE_FILE;
  delete process.env.BRIDGE_DISABLE_MDNS;
  delete process.env.BRIDGE_CODEX_ASSIST_MODEL;
  delete process.env.BRIDGE_CODEX_ASSIST_REASONING_EFFORT;
  delete process.env.CODEX_HOME;
  delete process.env.BRIDGE_CODEX_SOURCE_ID;
  delete process.env.BRIDGE_CODEX_APP_SERVER_MODE;
  delete process.env.BRIDGE_CODEX_SHARED_APP_SERVER_URL;
  delete process.env.BRIDGE_CODEX_APP_SERVER_PORT;
  delete process.env.BRIDGE_CODEX_APP_SERVER_URL;
}

function restoreBridgeEnv(): void {
  restoreEnvVar("BRIDGE_PORT", originalBridgeEnv.port);
  restoreEnvVar("BRIDGE_HOST", originalBridgeEnv.host);
  restoreEnvVar("BRIDGE_API_KEY", originalBridgeEnv.apiKey);
  restoreEnvVar("BRIDGE_AUTH_MODE", originalBridgeEnv.authMode);
  restoreEnvVar("BRIDGE_REQUIRE_API_KEY", originalBridgeEnv.requireApiKey);
  restoreEnvVar(
    "BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE",
    originalBridgeEnv.allowUnauthenticatedRemote,
  );
  restoreEnvVar(
    "BRIDGE_ALLOW_UNAUTHENTICATED_DIAGNOSTICS",
    originalBridgeEnv.allowUnauthenticatedDiagnostics,
  );
  restoreEnvVar("BRIDGE_ALLOWED_DIRS", originalBridgeEnv.allowedDirs);
  restoreEnvVar("BRIDGE_PUBLIC_WS_URL", originalBridgeEnv.publicWsUrl);
  restoreEnvVar("BRIDGE_ARTIFACT_BASE_URL", originalBridgeEnv.artifactBaseUrl);
  restoreEnvVar("BRIDGE_AUTO_ARTIFACTS", originalBridgeEnv.autoArtifacts);
  restoreEnvVar(
    "BRIDGE_ARTIFACT_REGISTRY_FILE",
    originalBridgeEnv.artifactRegistryFile,
  );
  restoreEnvVar(
    "BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR",
    originalBridgeEnv.fileTransferDownloadDir,
  );
  restoreEnvVar(
    "BRIDGE_FILE_TRANSFER_PARTIAL_DIR",
    originalBridgeEnv.fileTransferPartialDir,
  );
  restoreEnvVar(
    "BRIDGE_FILE_TRANSFER_STATE_FILE",
    originalBridgeEnv.fileTransferStateFile,
  );
  restoreEnvVar("BRIDGE_DISABLE_MDNS", originalBridgeEnv.disableMdns);
  restoreEnvVar(
    "BRIDGE_CODEX_ASSIST_MODEL",
    originalBridgeEnv.codexAssistModel,
  );
  restoreEnvVar(
    "BRIDGE_CODEX_ASSIST_REASONING_EFFORT",
    originalBridgeEnv.codexAssistReasoningEffort,
  );
  restoreEnvVar("CODEX_HOME", originalBridgeEnv.codexHome);
  restoreEnvVar("BRIDGE_CODEX_SOURCE_ID", originalBridgeEnv.codexSourceId);
  restoreEnvVar(
    "BRIDGE_CODEX_APP_SERVER_MODE",
    originalBridgeEnv.codexAppServerMode,
  );
  restoreEnvVar(
    "BRIDGE_CODEX_SHARED_APP_SERVER_URL",
    originalBridgeEnv.codexSharedAppServerUrl,
  );
  restoreEnvVar(
    "BRIDGE_CODEX_APP_SERVER_PORT",
    originalBridgeEnv.codexAppServerPort,
  );
  restoreEnvVar(
    "BRIDGE_CODEX_APP_SERVER_URL",
    originalBridgeEnv.codexAppServerUrl,
  );
}

function restoreEnvVar(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
    return;
  }
  process.env[key] = value;
}
