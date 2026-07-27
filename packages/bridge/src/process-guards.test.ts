import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { installProcessGuards } from "./process-guards.js";

describe("installProcessGuards", () => {
  it("terminates once after an unknown process-level failure", () => {
    const emitter = new EventEmitter();
    const terminate = vi.fn();
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      installProcessGuards(
        emitter as unknown as NodeJS.Process,
        terminate,
      );
      installProcessGuards(
        emitter as unknown as NodeJS.Process,
        terminate,
      );

      expect(emitter.listenerCount("unhandledRejection")).toBe(1);
      expect(emitter.listenerCount("uncaughtException")).toBe(1);

      expect(() => {
        emitter.emit(
          "unhandledRejection",
          new Error("background write failed"),
          Promise.resolve(),
        );
        emitter.emit("uncaughtException", new Error("handler blew up"));
      }).not.toThrow();

      expect(errorSpy).toHaveBeenCalledTimes(2);
      expect(terminate).toHaveBeenCalledTimes(1);
      expect(terminate).toHaveBeenCalledWith(1);
    } finally {
      errorSpy.mockRestore();
    }
  });
});
