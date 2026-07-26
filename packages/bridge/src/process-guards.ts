/**
 * Last-resort process-level guards.
 *
 * Node >= 15 runs with `--unhandled-rejections=throw`, so a single floating
 * promise rejection (e.g. a failed profile write to ~/.codex on a full disk)
 * would terminate the whole Bridge and kill every active session. Log and
 * keep serving instead of exiting.
 */
export function installProcessGuards(proc: NodeJS.Process = process): void {
  proc.on("unhandledRejection", (reason) => {
    console.error(
      "[bridge] Unhandled promise rejection (continuing):",
      reason,
    );
  });
  proc.on("uncaughtException", (err) => {
    console.error("[bridge] Uncaught exception (continuing):", err);
  });
}
