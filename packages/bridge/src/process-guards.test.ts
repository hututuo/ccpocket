import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { installProcessGuards } from "./process-guards.js";

describe("installProcessGuards", () => {
  it("logs unhandled rejections and uncaught exceptions without throwing", () => {
    const emitter = new EventEmitter();
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      installProcessGuards(emitter as unknown as NodeJS.Process);

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
    } finally {
      errorSpy.mockRestore();
    }
  });
});
