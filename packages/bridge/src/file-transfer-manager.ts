import { join } from "node:path";
import type { FileTransferDownloadStore, OpenedDownloadTransfer } from "./file-transfer-download-store.js";
import { FileTransferError } from "./file-transfer-errors.js";
import type { FileTransferClientMessage, FileTransferServerMessage } from "./file-transfer-protocol.js";
import type { PersistedUploadTransfer } from "./file-transfer-state-store.js";
import type { TransferFileIdentity } from "./file-transfer-state-store.js";
import type { FileTransferUploadStore, UploadAppendResult } from "./file-transfer-upload-store.js";
import {
  DiagnosticReportArchiver,
} from "./file-transfer-diagnostic.js";
import type { LocalFeatureRuntimeConversationState } from "./local-features/runtime.js";
import {
  FileMutationAuthError,
  type FileMutationAuthorizer,
} from "./file-mutation-auth.js";
import {
  validateFileTransferBaseUrl,
  validateFileTransferPeerBaseUrl,
} from "./file-transfer-utils.js";

const OFFER_MESSAGE = "file_transfer_offer_v2";
const UPLOAD_READY_MESSAGE = "file_transfer_upload_ready_v2";
const UPLOAD_RESULT_MESSAGE = "file_transfer_upload_result_v2";
const UPLOAD_RESULT_WITH_PATH_MESSAGE = "file_transfer_upload_result_v3";
const CANCEL_RESULT_MESSAGE = "file_transfer_cancel_result_v2";

export interface FileTransferClientBinding {
  supports(messageType: string): boolean;
  isOpen(): boolean;
  send(message: FileTransferServerMessage): boolean;
  /** HTTP origin derived from this authenticated WebSocket handshake. */
  httpBaseUrl?: string;
}

interface BoundUploadClient {
  client: object;
  requestId: string;
}

interface BoundDownloadClient {
  client: object;
  sizeBytes: number;
}

interface AuthorizedUpload {
  client: object;
  filename: string;
  sizeBytes: number;
}

export interface OfferFileInput {
  filePath: string;
  projectPath: string;
  ttlSeconds?: number;
  baseUrl?: string;
  signal?: AbortSignal;
  /** Optional descriptor-bound identity supplied by the secure file browser. */
  expectedIdentity?: TransferFileIdentity;
  /** Optional immutable root boundary supplied by the secure file browser. */
  canonicalRoot?: string;
}

export interface OfferedFile {
  status: "offered";
  transferId: string;
  recipientCount: 1;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  expiresAt: string;
}

export interface FileTransferManagerOptions {
  downloadStore: FileTransferDownloadStore;
  uploadStore: FileTransferUploadStore;
  baseUrl?: string;
  fileMutationAuthorizer?: FileMutationAuthorizer;
  diagnosticReportArchiver?: DiagnosticReportArchiver;
  allowDiagnosticWithoutMutationAuthorization?: boolean;
}

/** Coordinates live peers while byte/session authority stays in persistent stores. */
export class FileTransferManager {
  readonly downloadStore: FileTransferDownloadStore;
  readonly uploadStore: FileTransferUploadStore;
  private readonly baseUrl?: string;
  private readonly fileMutationAuthorizer?: FileMutationAuthorizer;
  private readonly diagnosticReportArchiver?: DiagnosticReportArchiver;
  private readonly allowDiagnosticWithoutMutationAuthorization: boolean;
  private readonly clients = new Map<object, FileTransferClientBinding>();
  private readonly uploadClients = new Map<string, BoundUploadClient>();
  private readonly downloadClients = new Map<string, BoundDownloadClient>();
  private readonly authorizedUploads = new Map<string, AuthorizedUpload>();
  private accepting = true;
  private readonly activeControlOperations = new Set<Promise<void>>();
  private readonly activeOfferOperations = new Set<Promise<unknown>>();
  private readonly activeDiagnosticOperations = new Set<Promise<void>>();
  private closeBarrier?: Promise<void>;
  private readonly diagnosticArchiveLocks = new Map<string, Promise<void>>();
  private readonly diagnosticReceiptVerifications = new Map<string, Promise<boolean>>();
  private diagnosticArchiveTail: Promise<void> = Promise.resolve();
  private diagnosticArchiverReady = false;

  constructor(options: FileTransferManagerOptions) {
    this.downloadStore = options.downloadStore;
    this.uploadStore = options.uploadStore;
    this.baseUrl = options.baseUrl;
    this.fileMutationAuthorizer = options.fileMutationAuthorizer;
    this.diagnosticReportArchiver = options.diagnosticReportArchiver;
    this.allowDiagnosticWithoutMutationAuthorization =
      options.allowDiagnosticWithoutMutationAuthorization === true;
  }

  async init(): Promise<void> {
    await this.uploadStore.init();
    if (
      this.diagnosticReportArchiver &&
      (this.fileMutationAuthorizer ||
        this.allowDiagnosticWithoutMutationAuthorization)
    ) {
      try {
        await this.diagnosticReportArchiver.init();
        this.diagnosticArchiverReady = true;
      } catch (error) {
        this.diagnosticArchiverReady = false;
        const detail = error instanceof Error ? error.message : String(error);
        console.warn(`[file-transfer] Diagnostic reports unavailable: ${detail}`);
      }
    }
  }

  get diagnosticReportsAvailable(): boolean {
    return Boolean(
      this.accepting &&
        this.diagnosticArchiverReady &&
        this.diagnosticReportArchiver &&
        (this.fileMutationAuthorizer ||
          this.allowDiagnosticWithoutMutationAuthorization),
    );
  }

  connect(client: object, binding: FileTransferClientBinding): void {
    if (!this.accepting) return;
    this.clients.set(client, binding);
  }

  disconnect(client: object): void {
    this.clients.delete(client);
    for (const [transferId, binding] of this.uploadClients) {
      if (binding.client === client) this.uploadClients.delete(transferId);
    }
    // Download sessions persist for HTTP resume; only the live-client shortcut
    // is removed. Cross-reconnect cancellation requires the download token.
    for (const [transferId, binding] of this.downloadClients) {
      if (binding.client === client) this.downloadClients.delete(transferId);
    }
    for (const [transferId, authorization] of this.authorizedUploads) {
      if (authorization.client === client) {
        this.authorizedUploads.delete(transferId);
      }
    }
    this.fileMutationAuthorizer?.disconnect(client);
  }

  close(): Promise<void> {
    this.closeBarrier ??= this.closeInternal();
    return this.closeBarrier;
  }

  private async closeInternal(): Promise<void> {
    // Reject new WS control work first, then wait every prepare/resume/cancel
    // already admitted before releasing the persistent state lock.
    this.accepting = false;
    while (
      this.activeControlOperations.size > 0 ||
      this.activeOfferOperations.size > 0 ||
      this.activeDiagnosticOperations.size > 0
    ) {
      await Promise.allSettled([
        ...this.activeControlOperations,
        ...this.activeOfferOperations,
        ...this.activeDiagnosticOperations,
      ]);
    }
    this.clients.clear();
    this.uploadClients.clear();
    this.downloadClients.clear();
    this.authorizedUploads.clear();
    this.diagnosticArchiveLocks.clear();
    this.diagnosticReceiptVerifications.clear();
    await this.uploadStore.close();
  }

  offerFile(input: OfferFileInput): Promise<OfferedFile> {
    return this.trackOffer(() => this.offerFileInternal(input));
  }

  private async offerFileInternal(input: OfferFileInput): Promise<OfferedFile> {
    throwIfOfferCancelled(input.signal);
    const selected = this.singleOfferRecipient();
    return this.offerFileToBinding(
      selected.client,
      selected.binding,
      input,
      () => {
        const current = this.singleOfferRecipient();
        if (current.client !== selected.client) {
          throw new FileTransferError(409, "recipient_changed", "Compatible phone set changed while preparing the file");
        }
        return current.binding;
      },
    );
  }

  /** Offer a file only to the live client that requested it. */
  offerFileToClient(
    client: object,
    input: OfferFileInput,
  ): Promise<OfferedFile> {
    return this.trackOffer(() => this.offerFileToClientInternal(client, input));
  }

  private async offerFileToClientInternal(
    client: object,
    input: OfferFileInput,
  ): Promise<OfferedFile> {
    throwIfOfferCancelled(input.signal);
    const selected = this.targetedOfferRecipient(client);
    return this.offerFileToBinding(
      client,
      selected,
      input,
      () => {
        const current = this.targetedOfferRecipient(client);
        if (current !== selected) {
          throw new FileTransferError(409, "recipient_changed", "The requesting phone changed while preparing the file");
        }
        return current;
      },
    );
  }

  private async offerFileToBinding(
    client: object,
    selectedBinding: FileTransferClientBinding,
    input: OfferFileInput,
    currentBinding: () => FileTransferClientBinding,
  ): Promise<OfferedFile> {
    const baseUrl = this.resolveBaseUrl(
      input.baseUrl,
      selectedBinding.httpBaseUrl,
    );
    const issued = await this.downloadStore.issue(input.filePath, {
      projectPath: input.projectPath,
      ttlSeconds: input.ttlSeconds,
      expectedIdentity: input.expectedIdentity,
      canonicalRoot: input.canonicalRoot,
    });
    try {
      throwIfOfferCancelled(input.signal);
      this.requireAcceptingOffers();
      const current = currentBinding();
      if (current.httpBaseUrl !== selectedBinding.httpBaseUrl) {
        throw new FileTransferError(
          409,
          "recipient_origin_changed",
          "The compatible phone HTTP origin changed while preparing the file",
        );
      }
      const { entry, downloadToken } = issued;
      const offer: FileTransferServerMessage = {
        type: OFFER_MESSAGE,
        transferId: entry.transferId,
        filename: entry.filename,
        mimeType: entry.mimeType,
        sizeBytes: entry.sizeBytes,
        downloadUrl: `${baseUrl}/api/file-transfers/downloads/${encodeURIComponent(entry.transferId)}`,
        downloadToken,
        etag: entry.etag,
        expiresAt: new Date(entry.expiresAt).toISOString(),
      };
      throwIfOfferCancelled(input.signal);
      this.requireAcceptingOffers();
      if (!current.isOpen() || !current.send(offer)) {
        throw new FileTransferError(409, "recipient_disconnected", "The compatible phone disconnected before delivery");
      }
      this.downloadClients.set(entry.transferId, {
        client,
        sizeBytes: entry.sizeBytes,
      });
      return {
        status: "offered",
        transferId: entry.transferId,
        recipientCount: 1,
        filename: entry.filename,
        mimeType: entry.mimeType,
        sizeBytes: entry.sizeBytes,
        expiresAt: new Date(entry.expiresAt).toISOString(),
      };
    } catch (error) {
      await this.downloadStore.remove(issued.entry.transferId).catch(() => undefined);
      throw error;
    }
  }

  private trackOffer<T>(operation: () => Promise<T>): Promise<T> {
    if (!this.accepting) return Promise.reject(offersClosedError());
    let tracked!: Promise<T>;
    tracked = Promise.resolve()
      .then(() => {
        this.requireAcceptingOffers();
        return operation();
      })
      .finally(() => {
        this.activeOfferOperations.delete(tracked);
      });
    this.activeOfferOperations.add(tracked);
    return tracked;
  }

  private requireAcceptingOffers(): void {
    if (!this.accepting) throw offersClosedError();
  }

  handleClientMessage(client: object, message: FileTransferClientMessage): Promise<void> {
    if (!this.accepting) return Promise.resolve();
    let tracked!: Promise<void>;
    tracked = this.handleClientMessageInternal(client, message).finally(() => {
      this.activeControlOperations.delete(tracked);
    });
    this.activeControlOperations.add(tracked);
    return tracked;
  }

  private async handleClientMessageInternal(
    client: object,
    message: FileTransferClientMessage,
  ): Promise<void> {
    switch (message.type) {
      case "file_transfer_upload_prepare_v2":
        await this.prepareUpload(client, message);
        return;
      case "file_transfer_receive_result_v2":
        await this.handleReceiveResult(client, message);
        return;
      case "file_transfer_cancel_v2":
        await this.handleCancel(client, message);
        return;
      case "file_transfer_download_resume_v2":
        await this.handleDownloadResume(client, message);
        return;
    }
  }

  authorizeDownload(transferId: string, token: string) {
    return this.downloadStore.authorize(transferId, token);
  }

  openDownload(transferId: string, token: string): Promise<OpenedDownloadTransfer> {
    return this.downloadStore.openAuthorized(transferId, token);
  }

  async statusUpload(transferId: string, uploadToken: string): Promise<PersistedUploadTransfer> {
    return this.uploadStore.status(transferId, uploadToken);
  }

  async appendUpload(
    transferId: string,
    uploadToken: string,
    uploadOffset: number,
    contentLength: number,
    body: AsyncIterable<Buffer | Uint8Array | string>,
    signal: AbortSignal,
  ): Promise<UploadAppendResult> {
    const result = await this.uploadStore.append(
      transferId,
      uploadToken,
      uploadOffset,
      contentLength,
      body,
      signal,
    );
    if (result.completed) await this.handleCompletedUpload(result.entry);
    return result;
  }

  setDiagnosticRuntimeStateProvider(
    provider: () => LocalFeatureRuntimeConversationState[],
  ): void {
    this.diagnosticReportArchiver?.setRuntimeStateProvider(provider);
  }

  private async prepareUpload(
    client: object,
    message: Extract<FileTransferClientMessage, { type: "file_transfer_upload_prepare_v2" }>,
  ): Promise<void> {
    const binding = this.clients.get(client);
    if (
      !binding?.isOpen() ||
      !binding.supports(UPLOAD_READY_MESSAGE) ||
      (!binding.supports(UPLOAD_RESULT_MESSAGE) &&
        !binding.supports(UPLOAD_RESULT_WITH_PATH_MESSAGE))
    ) {
      return;
    }
    try {
      if (
        message.purpose === "diagnostic_report" &&
        !binding.supports(UPLOAD_RESULT_WITH_PATH_MESSAGE)
      ) {
        throw new FileTransferError(
          409,
          "diagnostic_result_unsupported",
          "Diagnostic reports require file_transfer_upload_result_v3",
        );
      }
      if (
        message.purpose === "diagnostic_report" &&
        !this.diagnosticReportsAvailable
      ) {
        throw new FileTransferError(
          503,
          "diagnostic_archiver_unavailable",
          "Diagnostic report archiving is unavailable",
        );
      }
      const completedReceipt = message.purpose === "diagnostic_report"
        ? await this.uploadStore.findDiagnosticReceipt(
            message.transferId,
            message.resumeToken,
            message.filename,
            message.sizeBytes,
            {
              purpose: message.purpose,
              diagnosticReport: message.diagnosticReport,
            },
          )
        : undefined;
      if (completedReceipt) {
        let receiptValid = false;
        try {
          const verificationKey = [
            completedReceipt.entry.transferId,
            completedReceipt.receipt.archiveSha256,
            completedReceipt.receipt.mobileReportCanonicalSha256,
          ].join("\u0000");
          const existingVerification = this.diagnosticReceiptVerifications.get(
            verificationKey,
          );
          if (existingVerification) {
            receiptValid = await existingVerification;
          } else {
            const verification = this.runSerializedDiagnosticOperation(
              () => this.diagnosticReportArchiver!.verifyReceipt(
                completedReceipt.entry.diagnosticReport!,
                completedReceipt.receipt,
              ),
            );
            this.diagnosticReceiptVerifications.set(
              verificationKey,
              verification,
            );
            try {
              receiptValid = await verification;
            } finally {
              if (
                this.diagnosticReceiptVerifications.get(verificationKey) ===
                verification
              ) {
                this.diagnosticReceiptVerifications.delete(verificationKey);
              }
            }
          }
        } catch (error) {
          if (isTerminalDiagnosticArchiveFailure(error)) {
            await this.uploadStore.removeCompletedUpload(
              completedReceipt.entry,
            );
          }
          throw error;
        }
        if (!receiptValid) {
          // The immutable archive disappeared after its receipt was committed.
          // Remove only the exact now-missing completed upload state, then let
          // this same prepare create a fresh resumable transfer.
          await this.uploadStore.removeCompletedUpload(completedReceipt.entry);
        } else {
          await this.uploadStore.ensureDiagnosticReceiptPayloadRemoved(
            completedReceipt.entry,
          );
          this.uploadClients.set(message.transferId, {
            client,
            requestId: message.requestId,
          });
          const sent = binding.send({
            type: UPLOAD_RESULT_WITH_PATH_MESSAGE,
            requestId: message.requestId,
            transferId: message.transferId,
            success: true,
            filename: completedReceipt.receipt.filename,
            sizeBytes: completedReceipt.receipt.sizeBytes,
            savedPath: completedReceipt.receipt.savedPath,
            purpose: "diagnostic_report",
            reportId: completedReceipt.receipt.reportId,
          });
          if (sent) this.uploadClients.delete(message.transferId);
          return;
        }
      }
      const diagnosticAuthorizationBypassed =
        message.purpose === "diagnostic_report" &&
        this.allowDiagnosticWithoutMutationAuthorization;
      if (!this.fileMutationAuthorizer && !diagnosticAuthorizationBypassed) {
        throw new FileMutationAuthError(
          "unsupported_capability",
          "Phone uploads are locked until Bridge file mutation authorization is available",
        );
      }
      const existingAuthorization = this.authorizedUploads.get(
        message.transferId,
      );
      const requiresAuthorization =
        !diagnosticAuthorizationBypassed &&
        (existingAuthorization?.client !== client ||
          existingAuthorization.filename !== message.filename ||
          existingAuthorization.sizeBytes !== message.sizeBytes);
      if (requiresAuthorization) {
        await this.fileMutationAuthorizer!.authorize(
          client,
          {
            kind: "upload",
            transferId: message.transferId,
            filename: message.filename,
            sizeBytes: message.sizeBytes,
          },
          message.mutationAuthorization,
        );
      }
      const prepared = await this.uploadStore.prepare(
        message.transferId,
        message.resumeToken,
        message.filename,
        message.sizeBytes,
        {
          ...(message.purpose ? { purpose: message.purpose } : {}),
          ...(message.diagnosticReport
            ? { diagnosticReport: message.diagnosticReport }
            : {}),
        },
      );
      if (requiresAuthorization) {
        this.authorizedUploads.set(message.transferId, {
          client,
          filename: message.filename,
          sizeBytes: message.sizeBytes,
        });
      }
      this.uploadClients.set(message.transferId, {
        client,
        requestId: message.requestId,
      });
      if (prepared.status === "complete") {
        await this.handleCompletedUpload(prepared.entry, message.requestId);
        return;
      }
      const baseUrl = this.resolveBaseUrl(undefined, binding.httpBaseUrl);
      const ready: FileTransferServerMessage = {
        type: UPLOAD_READY_MESSAGE,
        requestId: message.requestId,
        transferId: message.transferId,
        uploadUrl: `${baseUrl}/api/file-transfers/uploads/${encodeURIComponent(message.transferId)}`,
        uploadToken: prepared.uploadToken,
        resumeToken: prepared.resumeToken,
        uploadOffset: prepared.entry.offset,
        sizeBytes: prepared.entry.sizeBytes,
        expiresAt: new Date(prepared.entry.expiresAt).toISOString(),
        maxChunkSizeBytes: this.uploadStore.maxChunkSizeBytes,
      };
      if (!binding.isOpen() || !binding.send(ready)) {
        this.uploadClients.delete(message.transferId);
      }
    } catch (error) {
      this.sendUploadFailure(client, binding, message, error);
    }
  }

  private async handleReceiveResult(
    client: object,
    message: Extract<FileTransferClientMessage, { type: "file_transfer_receive_result_v2" }>,
  ): Promise<void> {
    const binding = this.downloadClients.get(message.transferId);
    if (
      binding?.client === client &&
      message.success &&
      message.receivedBytes === binding.sizeBytes
    ) {
      try {
        await this.downloadStore.remove(message.transferId);
      } catch (error) {
        // The phone already committed the file. Retain both state and the live
        // binding so a repeated idempotent acknowledgement can retry cleanup;
        // optional transfer bookkeeping must never reject into the chat loop.
        console.warn(
          `[file-transfer] Unable to clean acknowledged download ${message.transferId}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
        return;
      }
      this.downloadClients.delete(message.transferId);
    }
  }

  private async handleCancel(
    client: object,
    message: Extract<FileTransferClientMessage, { type: "file_transfer_cancel_v2" }>,
  ): Promise<void> {
    const binding = this.clients.get(client);
    if (!binding?.isOpen() || !binding.supports(CANCEL_RESULT_MESSAGE)) return;
    try {
      if (message.direction === "upload") {
        let authorized = false;
        try {
          await this.uploadStore.cancel(message.transferId, message.resumeToken!);
          authorized = true;
        } catch (error) {
          // A repeated authenticated cancel after cleanup is idempotent. A
          // wrong secret has the same indistinguishable not-found response and
          // therefore never reveals or deletes an existing transfer.
          if (!(error instanceof FileTransferError) || error.code !== "upload_not_found") {
            throw error;
          }
        }
        // A deliberately indistinguishable not-found response must not let an
        // unauthenticated peer detach the real owner's completion route.
        if (authorized) {
          this.uploadClients.delete(message.transferId);
          this.authorizedUploads.delete(message.transferId);
        }
      } else {
        const liveOwner = this.downloadClients.get(message.transferId)?.client === client;
        let authorized = liveOwner;
        if (!liveOwner) {
          if (!message.downloadToken) {
            throw new FileTransferError(403, "download_cancel_unauthorized", "Download token is required after reconnect");
          }
          try {
            await this.downloadStore.cancel(message.transferId, message.downloadToken);
            authorized = true;
          } catch (error) {
            if (!(error instanceof FileTransferError) || error.code !== "download_not_found") {
              throw error;
            }
          }
        }
        if (authorized && liveOwner) await this.downloadStore.remove(message.transferId);
        // The token-authenticated cross-reconnect path already removed the
        // store entry. In both paths, keep another live owner's binding intact
        // when the supplied token was invalid or the transfer was unknown.
        if (authorized) this.downloadClients.delete(message.transferId);
      }
      binding.send({
        type: CANCEL_RESULT_MESSAGE,
        requestId: message.requestId,
        transferId: message.transferId,
        direction: message.direction,
        success: true,
      });
    } catch (error) {
      const transferError = error instanceof FileTransferError
        ? error
        : new FileTransferError(500, "cancel_failed", "Unable to cancel transfer");
      binding.send({
        type: CANCEL_RESULT_MESSAGE,
        requestId: message.requestId,
        transferId: message.transferId,
        direction: message.direction,
        success: false,
        errorCode: transferError.code,
        error: transferError.message,
      });
    }
  }

  private async handleDownloadResume(
    client: object,
    message: Extract<FileTransferClientMessage, { type: "file_transfer_download_resume_v2" }>,
  ): Promise<void> {
    const binding = this.clients.get(client);
    if (!binding?.isOpen() || !binding.supports("file_transfer_download_resumed_v2")) return;
    try {
      const entry = await this.downloadStore.resume(
        message.transferId,
        message.downloadToken,
      );
      if (
        this.clients.get(client) !== binding ||
        !binding.isOpen() ||
        !binding.supports("file_transfer_download_resumed_v2")
      ) {
        return;
      }
      const sent = binding.send({
        type: "file_transfer_download_resumed_v2",
        requestId: message.requestId,
        transferId: message.transferId,
        success: true,
        sizeBytes: entry.sizeBytes,
        etag: entry.etag,
        expiresAt: new Date(entry.expiresAt).toISOString(),
      });
      if (sent) {
        this.downloadClients.set(entry.transferId, {
          client,
          sizeBytes: entry.sizeBytes,
        });
      }
    } catch (error) {
      const transferError = error instanceof FileTransferError
        ? error
        : new FileTransferError(500, "download_resume_failed", "Unable to resume download");
      binding.send({
        type: "file_transfer_download_resumed_v2",
        requestId: message.requestId,
        transferId: message.transferId,
        success: false,
        errorCode: transferError.code,
        error: transferError.message,
      });
    }
  }

  private async handleCompletedUpload(
    entry: PersistedUploadTransfer,
    requestId?: string,
  ): Promise<void> {
    if (entry.purpose !== "diagnostic_report") {
      this.sendCompletedUpload(entry, requestId);
      return;
    }
    const owner = this.uploadClients.get(entry.transferId);
    const binding = owner ? this.clients.get(owner.client) : undefined;
    if (
      owner &&
      binding?.isOpen() &&
      !binding.supports(UPLOAD_RESULT_WITH_PATH_MESSAGE)
    ) {
      let failure: unknown = new FileTransferError(
        409,
        "diagnostic_result_unsupported",
        "Diagnostic reports require file_transfer_upload_result_v3",
      );
      try {
        await this.uploadStore.removeCompletedUpload(entry);
      } catch {
        failure = new FileTransferError(
          500,
          "diagnostic_rejected_payload_cleanup_failed",
          "Diagnostic report was rejected but its staged payload could not be safely removed",
        );
      }
      this.sendCompletedUploadFailure(
        entry,
        requestId,
        failure,
      );
      this.uploadClients.delete(entry.transferId);
      this.authorizedUploads.delete(entry.transferId);
      return;
    }
    const run = async (): Promise<void> => {
      try {
        if (!this.diagnosticReportArchiver || !entry.diagnosticReport) {
          throw new FileTransferError(
            503,
            "diagnostic_archiver_unavailable",
            "Diagnostic report archiving is unavailable",
          );
        }
        const bytes = await this.uploadStore.readCompletedUpload(entry);
        const archive = await this.diagnosticReportArchiver.archive(
          entry.diagnosticReport,
          bytes,
          entry.sizeBytes,
        );
        await this.uploadStore.commitDiagnosticReceipt(entry, {
          filename: archive.filename,
          savedPath: archive.savedPath,
          sizeBytes: entry.sizeBytes,
          purpose: "diagnostic_report",
          reportId: entry.diagnosticReport.reportId,
          archiveSha256: archive.archiveSha256,
          mobileReportCanonicalSha256:
            archive.mobileReportCanonicalSha256,
          committedAt: Date.now(),
        });
        const currentOwner = this.uploadClients.get(entry.transferId);
        const currentBinding = currentOwner
          ? this.clients.get(currentOwner.client)
          : undefined;
        if (!currentOwner || !currentBinding?.isOpen()) return;
        const sent = currentBinding.send({
          type: UPLOAD_RESULT_WITH_PATH_MESSAGE,
          requestId: requestId ?? currentOwner.requestId,
          transferId: entry.transferId,
          success: true,
          filename: archive.filename,
          // Keep the upload-result size in transfer semantics. The archived
          // envelope adds Bridge authority fields and is therefore normally
          // larger than the phone payload; Mobile validates this field against
          // its resumable checkpoint before deleting local staging.
          sizeBytes: entry.sizeBytes,
          savedPath: archive.savedPath,
          purpose: "diagnostic_report",
          reportId: entry.diagnosticReport.reportId,
        });
        if (sent) {
          this.uploadClients.delete(entry.transferId);
          this.authorizedUploads.delete(entry.transferId);
        }
      } catch (error) {
        let failure = error;
        let terminalPayloadRemoved = false;
        if (isTerminalDiagnosticArchiveFailure(error)) {
          try {
            if (isUnreadableDiagnosticPayload(error)) {
              await this.uploadStore.discardUnreadableDiagnosticUpload(entry);
            } else {
              await this.uploadStore.removeCompletedUpload(entry);
            }
            terminalPayloadRemoved = true;
          } catch {
            failure = new FileTransferError(
              500,
              "diagnostic_rejected_payload_cleanup_failed",
              "Diagnostic report was rejected but its staged payload could not be safely removed",
            );
          }
        }
        this.sendCompletedUploadFailure(entry, requestId, failure);
        if (terminalPayloadRemoved) {
          this.uploadClients.delete(entry.transferId);
          this.authorizedUploads.delete(entry.transferId);
        }
      }
    };
    const existing = this.diagnosticArchiveLocks.get(entry.transferId);
    if (existing) {
      await existing;
      return;
    }
    // Serialize distinct reports as well as deduplicating the same transfer.
    // Each report may read and parse up to 16 MiB, so an unbounded fan-out can
    // otherwise create a large transient RSS spike after simultaneous PATCHes.
    const operation = this.runSerializedDiagnosticOperation(run);
    this.diagnosticArchiveLocks.set(entry.transferId, operation);
    try {
      await operation;
    } finally {
      if (this.diagnosticArchiveLocks.get(entry.transferId) === operation) {
        this.diagnosticArchiveLocks.delete(entry.transferId);
      }
    }
  }

  private async runSerializedDiagnosticOperation<T>(
    run: () => Promise<T>,
  ): Promise<T> {
    const operation = this.diagnosticArchiveTail.then(run, run);
    const tracked = operation.then(() => undefined, () => undefined);
    this.diagnosticArchiveTail = tracked;
    this.activeDiagnosticOperations.add(tracked);
    try {
      return await operation;
    } finally {
      this.activeDiagnosticOperations.delete(tracked);
    }
  }

  private sendCompletedUploadFailure(
    entry: PersistedUploadTransfer,
    requestId: string | undefined,
    error: unknown,
  ): void {
    const owner = this.uploadClients.get(entry.transferId);
    const binding = owner ? this.clients.get(owner.client) : undefined;
    if (!owner || !binding?.isOpen() || !binding.supports(UPLOAD_RESULT_WITH_PATH_MESSAGE)) return;
    const transferError = error instanceof FileTransferError
      ? error
      : new FileTransferError(500, "diagnostic_archive_failed", "Unable to archive diagnostic report");
    binding.send({
      type: UPLOAD_RESULT_WITH_PATH_MESSAGE,
      requestId: requestId ?? owner.requestId,
      transferId: entry.transferId,
      success: false,
      errorCode: transferError.code,
      error: transferError.message,
      purpose: "diagnostic_report",
      ...(entry.diagnosticReport ? { reportId: entry.diagnosticReport.reportId } : {}),
    });
  }

  private sendCompletedUpload(entry: PersistedUploadTransfer, requestId?: string): void {
    const owner = this.uploadClients.get(entry.transferId);
    if (!owner) return;
    const binding = this.clients.get(owner.client);
    if (!binding?.isOpen()) return;
    const savedPath = entry.finalFilename
      ? join(this.uploadStore.directory, entry.finalFilename)
      : undefined;
    const canSendPath =
      savedPath !== undefined &&
      savedPath.length <= 4096 &&
      binding.supports(UPLOAD_RESULT_WITH_PATH_MESSAGE);
    if (!canSendPath && !binding.supports(UPLOAD_RESULT_MESSAGE)) return;
    const sent = binding.send(
      canSendPath
        ? {
            type: UPLOAD_RESULT_WITH_PATH_MESSAGE,
            requestId: requestId ?? owner.requestId,
            transferId: entry.transferId,
            success: true,
            filename: entry.finalFilename,
            sizeBytes: entry.sizeBytes,
            savedPath,
          }
        : {
            type: UPLOAD_RESULT_MESSAGE,
            requestId: requestId ?? owner.requestId,
            transferId: entry.transferId,
            success: true,
            filename: entry.finalFilename,
            sizeBytes: entry.sizeBytes,
          },
    );
    if (sent) this.uploadClients.delete(entry.transferId);
    if (sent) this.authorizedUploads.delete(entry.transferId);
  }

  private sendUploadFailure(
    client: object,
    binding: FileTransferClientBinding | undefined,
    message: Extract<FileTransferClientMessage, { type: "file_transfer_upload_prepare_v2" }>,
    error: unknown,
  ): void {
    if (this.clients.get(client) !== binding || !binding?.isOpen()) return;
    const transferError =
      error instanceof FileTransferError
        ? error
        : error instanceof FileMutationAuthError
          ? new FileTransferError(403, error.code, error.message)
          : new FileTransferError(
              500,
              "upload_prepare_failed",
              "Unable to prepare upload",
            );
    const type = binding.supports(UPLOAD_RESULT_WITH_PATH_MESSAGE)
      ? UPLOAD_RESULT_WITH_PATH_MESSAGE
      : UPLOAD_RESULT_MESSAGE;
    if (!binding.supports(type)) return;
    binding.send({
      type,
      requestId: message.requestId,
      transferId: message.transferId,
      success: false,
      errorCode: transferError.code,
      error: transferError.message,
    });
  }

  private singleOfferRecipient(): { client: object; binding: FileTransferClientBinding } {
    const compatible = [...this.clients.entries()].filter(
      ([, binding]) => binding.isOpen() && binding.supports(OFFER_MESSAGE),
    );
    if (compatible.length === 0) {
      throw new FileTransferError(409, "no_compatible_phone", "No compatible live phone is connected");
    }
    if (compatible.length !== 1) {
      throw new FileTransferError(409, "multiple_compatible_phones", "More than one compatible phone is connected");
    }
    return { client: compatible[0][0], binding: compatible[0][1] };
  }

  private targetedOfferRecipient(client: object): FileTransferClientBinding {
    const binding = this.clients.get(client);
    if (!binding?.isOpen()) {
      throw new FileTransferError(409, "recipient_disconnected", "The requesting phone is no longer connected");
    }
    if (!binding.supports(OFFER_MESSAGE)) {
      throw new FileTransferError(409, "recipient_incompatible", "The requesting phone does not support resumable downloads");
    }
    return binding;
  }

  private resolveBaseUrl(explicit?: string, peerBaseUrl?: string): string {
    const configured = validateFileTransferBaseUrl(this.baseUrl);
    const peer = validateFileTransferPeerBaseUrl(peerBaseUrl);
    const requested = explicit === undefined
      ? undefined
      : validateFileTransferBaseUrl(explicit);
    if (explicit !== undefined && !requested) {
      throw new FileTransferError(
        400,
        "invalid_transfer_base_url",
        "The requested transfer base URL is invalid",
      );
    }
    if (peer && requested && peer !== requested) {
      throw new FileTransferError(
        409,
        "transfer_base_url_mismatch",
        "The requested transfer base URL does not match the current WebSocket HTTP origin",
      );
    }
    const resolved = requested ?? peer ?? configured;
    if (!resolved) {
      throw new FileTransferError(503, "transfer_base_url_unavailable", "No mobile-reachable Bridge URL is available");
    }
    return resolved;
  }
}

function isTerminalDiagnosticArchiveFailure(error: unknown): boolean {
  if (!(error instanceof FileTransferError)) return false;
  return new Set([
    "diagnostic_metadata_invalid",
    "diagnostic_size_mismatch",
    "diagnostic_sha256_mismatch",
    "diagnostic_invalid_json",
    "diagnostic_sensitive_field",
    "diagnostic_source_mismatch",
    "diagnostic_payload_identity_mismatch",
    "diagnostic_envelope_too_large",
    "diagnostic_report_id_invalid",
    "diagnostic_report_collision",
    "diagnostic_receipt_identity_mismatch",
    "upload_final_changed",
    "upload_final_unavailable",
  ]).has(error.code);
}

function isUnreadableDiagnosticPayload(error: unknown): boolean {
  return error instanceof FileTransferError &&
    (error.code === "upload_final_changed" ||
      error.code === "upload_final_unavailable");
}

function throwIfOfferCancelled(signal?: AbortSignal): void {
  if (signal?.aborted) {
    throw new FileTransferError(
      499,
      "control_cancelled",
      "The local send request was cancelled before the phone offer",
    );
  }
}

function offersClosedError(): FileTransferError {
  return new FileTransferError(
    503,
    "transfer_shutting_down",
    "The file transfer service is shutting down",
  );
}
