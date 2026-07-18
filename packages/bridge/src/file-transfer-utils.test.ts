import { describe, expect, it } from "vitest";
import {
  fileTransferContentDisposition,
  fileTransferMimeType,
  validateFileTransferBaseUrl,
  validateFileTransferPeerBaseUrl,
} from "./file-transfer-utils.js";

describe("file transfer independent utilities", () => {
  it("keeps CLI/configured origins mobile-reachable", () => {
    expect(validateFileTransferBaseUrl("http://100.64.0.1:8765/"))
      .toBe("http://100.64.0.1:8765");
    for (const value of [
      "http://localhost:8765",
      "http://127.0.0.1:8765",
      "http://[::1]:8765",
      "http://0.0.0.0:8765",
    ]) expect(validateFileTransferBaseUrl(value)).toBeUndefined();
  });

  it("accepts only exact loopback origins observed from an authenticated SSH tunnel", () => {
    expect(validateFileTransferPeerBaseUrl("http://localhost:18765/"))
      .toBe("http://localhost:18765");
    expect(validateFileTransferPeerBaseUrl("http://127.0.0.1:18765"))
      .toBe("http://127.0.0.1:18765");
    expect(validateFileTransferPeerBaseUrl("http://[::1]:18765"))
      .toBe("http://[::1]:18765");
    for (const value of [
      "http://127.0.0.2:18765",
      "http://0.0.0.0:18765",
      "http://user@localhost:18765",
      "http://localhost:18765/path",
      "http://localhost:18765?query=1",
    ]) expect(validateFileTransferPeerBaseUrl(value)).toBeUndefined();
  });

  it("provides transfer-owned MIME and safe attachment metadata", () => {
    expect(fileTransferMimeType("report.pdf")).toBe("application/pdf");
    expect(fileTransferMimeType("unknown.data")).toBe("application/octet-stream");
    expect(fileTransferContentDisposition("报告\".pdf"))
      .toContain("filename*=UTF-8''");
  });
});
