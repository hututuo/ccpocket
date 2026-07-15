import { describe, expect, it } from "vitest";
import {
  buildArtifactMarkdown,
  buildArtifactPreviewUrl,
  httpBaseUrlFromPublicWsUrl,
  resolveArtifactBaseUrl,
  validateArtifactBaseUrl,
} from "./artifact-url.js";

describe("validateArtifactBaseUrl", () => {
  it("accepts a mobile-reachable HTTP URL", () => {
    expect(validateArtifactBaseUrl(" http://192.168.1.20:8765/ ")).toBe(
      "http://192.168.1.20:8765",
    );
  });

  it.each([
    "file:///tmp/report.pdf",
    "ws://192.168.1.20:8765",
    "http://127.0.0.1:8765",
    "http://localhost:8765",
    "http://0.0.0.0:8765",
    "http://[::]:8765",
    "http://[::1]:8765",
    "http://[::ffff:127.0.0.1]:8765",
    "http://user:pass@192.168.1.20:8765",
    "http://192.168.1.20:8765?token=secret",
    "http://192.168.1.20:8765/bridge",
  ])("rejects unsafe or unreachable URL %s", (url) => {
    expect(validateArtifactBaseUrl(url)).toBeUndefined();
  });
});

describe("resolveArtifactBaseUrl", () => {
  it("prefers an explicit base URL origin", () => {
    expect(
      resolveArtifactBaseUrl({
        port: 8765,
        host: "0.0.0.0",
        explicitBaseUrl: "https://bridge.example.com",
        publicWsUrl: "wss://other.example.com/ws",
        addresses: [{ ip: "192.168.1.20", label: "LAN" }],
      }),
    ).toBe("https://bridge.example.com");
  });

  it("uses the origin of a public WebSocket URL", () => {
    expect(httpBaseUrlFromPublicWsUrl("wss://bridge.example.com/ws?x=1")).toBe(
      "https://bridge.example.com",
    );
  });

  it("prefers LAN over Tailscale for local fallback", () => {
    expect(
      resolveArtifactBaseUrl({
        port: 8765,
        host: "0.0.0.0",
        addresses: [
          { ip: "100.64.0.2", label: "Tailscale" },
          { ip: "192.168.1.20", label: "LAN" },
        ],
      }),
    ).toBe("http://192.168.1.20:8765");
  });

  it("returns undefined when no mobile address exists", () => {
    expect(
      resolveArtifactBaseUrl({
        port: 8765,
        host: "0.0.0.0",
        addresses: [],
      }),
    ).toBeUndefined();
  });
});

describe("artifact links", () => {
  it("builds a token-only preview URL", () => {
    expect(
      buildArtifactPreviewUrl(
        "http://192.168.1.20:8765/",
        "A".repeat(43),
      ),
    ).toBe(`http://192.168.1.20:8765/artifacts/${"A".repeat(43)}`);
  });

  it("escapes markdown label characters", () => {
    expect(
      buildArtifactMarkdown(
        "报告[最终]\\版.docx",
        `http://192.168.1.20:8765/artifacts/${"A".repeat(43)}`,
      ),
    ).toContain("报告\\[最终\\]\\\\版.docx");
  });
});
