const guardedProcesses = new WeakSet<object>();

/**
 * Last-resort process-level guards.
 *
 * Known async boundaries must handle their own failures. Reaching this guard
 * means process invariants are unknown, so continuing to serve sessions is
 * less safe than letting launchd/systemd restart a clean Bridge.
 */
export function installProcessGuards(
  proc: NodeJS.Process = process,
  terminate: (code: number) => void = (code) => proc.exit(code),
): void {
  if (guardedProcesses.has(proc)) return;
  guardedProcesses.add(proc);

  let terminating = false;
  const failClosed = (label: string, error: unknown) => {
    console.error(`[bridge] ${label}; terminating for a clean restart:`, error);
    if (terminating) return;
    terminating = true;
    proc.exitCode = 1;
    terminate(1);
  };

  proc.on("unhandledRejection", (reason) => {
    failClosed("Unhandled promise rejection", reason);
  });
  proc.on("uncaughtException", (error) => {
    failClosed("Uncaught exception", error);
  });
}
