import type { FileBrowserManager } from "../../file-browser-manager.js";
import type {
  FileBrowserClientMessage,
  FileBrowserServerMessage,
} from "../protocol.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "../runtime.js";

const REQUEST_TYPES = [
  "file_browser_roots_v1",
  "file_browser_list_v1",
  "file_browser_stat_v1",
  "file_browser_preview_v1",
  "file_browser_download_v1",
  "file_mutation_auth_state_v1",
  "file_mutation_auth_challenge_v1",
  "file_mutation_auth_enroll_v1",
] as const satisfies readonly FileBrowserClientMessage["type"][];

const RESULT_TYPE_BY_REQUEST = {
  file_browser_roots_v1: "file_browser_roots_result_v1",
  file_browser_list_v1: "file_browser_list_result_v1",
  file_browser_stat_v1: "file_browser_stat_result_v1",
  file_browser_preview_v1: "file_browser_preview_result_v1",
  file_browser_download_v1: "file_browser_download_result_v1",
  file_mutation_auth_state_v1: "file_mutation_auth_result_v1",
  file_mutation_auth_challenge_v1: "file_mutation_auth_result_v1",
  file_mutation_auth_enroll_v1: "file_mutation_auth_result_v1",
} as const satisfies Record<
  FileBrowserClientMessage["type"],
  FileBrowserServerMessage["type"]
>;

/** One removable local-feature seam for root-scoped file browsing. */
export function createFileBrowserHandlers(
  runtime: LocalFeatureRuntime,
): readonly LocalFeatureHandler[] {
  return [new FileBrowserFeatureHandler(runtime, runtime.fileBrowser)];
}

class FileBrowserFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = REQUEST_TYPES;
  private readonly boundClients = new WeakSet<object>();

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    private readonly manager?: FileBrowserManager,
  ) {}

  async handle(
    message: FileBrowserClientMessage,
    context: Parameters<LocalFeatureHandler["handle"]>[1],
  ): Promise<void> {
    const resultType = RESULT_TYPE_BY_REQUEST[message.type];
    if (!this.runtime.supports(context.client, resultType)) return;

    if (!this.manager) {
      this.runtime.send(context.client, {
        type: resultType,
        requestId: message.requestId,
        success: false,
        errorCode: "unsupported_capability",
        error: "File browser capability was not negotiated",
      } as FileBrowserServerMessage);
      return;
    }

    this.bind(context.client);
    await this.manager.handleClientMessage(
      context.client,
      message,
      context.signal,
    );
  }

  capabilitiesChanged(client: object): void {
    if (this.manager) this.bind(client);
  }

  disconnect(client: object): void {
    this.boundClients.delete(client);
    this.manager?.disconnect(client);
  }

  close(): Promise<void> {
    return this.manager?.close() ?? Promise.resolve();
  }

  private bind(client: object): void {
    const manager = this.manager;
    if (!manager || this.boundClients.has(client)) return;
    manager.connect(client, {
      isOpen: () => this.runtime.isClientOpen?.(client) ?? true,
      send: (message) => {
        if (
          !(this.runtime.isClientOpen?.(client) ?? true) ||
          !this.runtime.supports(client, message.type)
        ) {
          return false;
        }
        this.runtime.send(client, message);
        return true;
      },
    });
    this.boundClients.add(client);
  }
}
