import { describe, expect, it } from "vitest";
import {
  isFileTransferServerMessageType,
  parseFileTransferClientMessage,
} from "./file-transfer-protocol.js";

const transferId = "transfer_12345678";
const token = "a".repeat(43);

describe("file transfer v2 protocol", () => {
  it("accepts the frozen Mobile-owned upload identity", () => {
    expect(parseFileTransferClientMessage({
      type: "file_transfer_upload_prepare_v2",
      requestId: "request-1",
      transferId,
      resumeToken: token,
      filename: "报告.pdf",
      sizeBytes: 15 * 1024 * 1024 * 1024,
    })).toEqual({
      type: "file_transfer_upload_prepare_v2",
      requestId: "request-1",
      transferId,
      resumeToken: token,
      filename: "报告.pdf",
      sizeBytes: 15 * 1024 * 1024 * 1024,
    });
  });

  it("accepts receive acknowledgements, resume, and direction-scoped cancel", () => {
    expect(parseFileTransferClientMessage({
      type: "file_transfer_receive_result_v2",
      transferId,
      success: true,
      savedFilename: "报告.pdf",
      receivedBytes: 42,
    })).toMatchObject({ type: "file_transfer_receive_result_v2", receivedBytes: 42 });
    expect(parseFileTransferClientMessage({
      type: "file_transfer_download_resume_v2",
      requestId: "resume-1",
      transferId,
      downloadToken: token,
    })).toMatchObject({ type: "file_transfer_download_resume_v2", downloadToken: token });
    expect(parseFileTransferClientMessage({
      type: "file_transfer_cancel_v2",
      requestId: "cancel-1",
      transferId,
      direction: "upload",
      resumeToken: token,
    })).toMatchObject({ direction: "upload", resumeToken: token });
    expect(parseFileTransferClientMessage({
      type: "file_transfer_cancel_v2",
      requestId: "cancel-2",
      transferId,
      direction: "download",
    })).toMatchObject({ direction: "download" });
  });

  it("rejects malformed ids, secrets, key mixing, and unsafe sizes", () => {
    for (const message of [
      {
        type: "file_transfer_upload_prepare_v2",
        requestId: "r",
        transferId: "short",
        resumeToken: token,
        filename: "a",
        sizeBytes: 1,
      },
      {
        type: "file_transfer_upload_prepare_v2",
        requestId: "r",
        transferId,
        resumeToken: "short",
        filename: "a",
        sizeBytes: 1,
      },
      {
        type: "file_transfer_upload_prepare_v2",
        requestId: "r",
        transferId,
        resumeToken: token,
        filename: "a",
        sizeBytes: -1,
      },
      {
        type: "file_transfer_upload_prepare_v2",
        requestId: "r",
        transferId,
        resumeToken: token,
        filename: "a",
        sizeBytes: 15 * 1024 * 1024 * 1024 + 1,
      },
      {
        type: "file_transfer_receive_result_v2",
        transferId,
        success: true,
        receivedBytes: 15 * 1024 * 1024 * 1024 + 1,
      },
      {
        type: "file_transfer_receive_result_v2",
        transferId,
        success: true,
        receivedBytes: 1,
        unknown: true,
      },
      {
        type: "file_transfer_cancel_v2",
        requestId: "r",
        transferId,
        direction: "upload",
        resumeToken: token,
        downloadToken: token,
      },
      {
        type: "file_transfer_cancel_v2",
        requestId: "r",
        transferId,
        direction: "download",
        resumeToken: token,
      },
    ]) expect(parseFileTransferClientMessage(message)).toBeNull();
  });

  it("leaves unrelated messages alone and gates every v2 server type", () => {
    expect(parseFileTransferClientMessage({ type: "get_history", sessionId: "s" })).toBeUndefined();
    for (const type of [
      "file_transfer_offer_v2",
      "file_transfer_upload_ready_v2",
      "file_transfer_upload_result_v2",
      "file_transfer_upload_result_v3",
      "file_transfer_cancel_result_v2",
      "file_transfer_download_resumed_v2",
    ]) expect(isFileTransferServerMessageType(type)).toBe(true);
    expect(isFileTransferServerMessageType("file_transfer_offer")).toBe(false);
  });
});
