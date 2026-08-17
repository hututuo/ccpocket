import { describe, expect, it } from "vitest";
import {
  isPathWithinAllowedDirectory,
  normalizePlatformPath,
  parseAllowedDirectories,
  resolveOwnerFileAccessPolicy,
  resolvePlatformPath,
  resolvePlatformPathFrom,
  stripWindowsExtendedPathPrefix,
} from "./path-utils.js";

describe("path-utils", () => {
  it("accepts Windows subdirectories under an allowed parent", () => {
    expect(
      isPathWithinAllowedDirectory(
        "D:\\Users\\alice\\src\\ccpocket",
        "D:\\Users\\alice",
        "win32",
      ),
    ).toBe(true);
  });

  it("normalizes extended Windows drive paths", () => {
    expect(stripWindowsExtendedPathPrefix("\\\\?\\D:\\Users\\alice\\project"))
      .toBe("D:\\Users\\alice\\project");
    expect(stripWindowsExtendedPathPrefix("//?/D:/Users/alice/project"))
      .toBe("D:\\Users\\alice\\project");
    expect(
      resolvePlatformPath("\\\\?\\D:\\Users\\alice\\project", "win32"),
    ).toBe("D:\\Users\\alice\\project");
    expect(resolvePlatformPath("//?/D:/Users/alice/project", "win32")).toBe(
      "D:\\Users\\alice\\project",
    );
  });

  it("normalizes extended Windows UNC paths", () => {
    expect(
      stripWindowsExtendedPathPrefix("\\\\?\\UNC\\server\\share\\project"),
    ).toBe("\\\\server\\share\\project");
    expect(
      stripWindowsExtendedPathPrefix("//?/UNC/server/share/project"),
    ).toBe("\\\\server\\share\\project");
  });

  it("rejects paths outside the allowed parent on Windows", () => {
    expect(
      isPathWithinAllowedDirectory(
        "E:\\Users\\alice\\src\\ccpocket",
        "D:\\Users\\alice",
        "win32",
      ),
    ).toBe(false);
  });

  it("keeps POSIX normalization behavior unchanged", () => {
    expect(normalizePlatformPath("/tmp/project/../repo", "linux")).toBe(
      "/tmp/repo",
    );
    expect(
      isPathWithinAllowedDirectory("/tmp/repo/src", "/tmp/repo", "linux"),
    ).toBe(true);
  });

  it("resolves relative paths against an explicit base path", () => {
    expect(resolvePlatformPathFrom("/tmp/repo", "../shared", "linux")).toBe(
      "/tmp/shared",
    );
    expect(
      resolvePlatformPathFrom("D:\\Users\\alice\\repo", "..\\shared", "win32"),
    ).toBe("D:\\Users\\alice\\shared");
  });

  it("uses default allowed directories when unset or blank", () => {
    expect(parseAllowedDirectories(undefined, "linux", ["/home/alice"]))
      .toEqual(["/home/alice"]);
    expect(parseAllowedDirectories("  ", "linux", ["/home/alice"]))
      .toEqual(["/home/alice"]);
  });

  it("allows unrestricted access only with an exact star", () => {
    expect(parseAllowedDirectories("*", "linux", ["/home/alice"]))
      .toEqual([]);
    expect(() => parseAllowedDirectories("*, /opt/project", "linux"))
      .toThrow("must be either '*'");
  });

  it("enables owner full-disk access only behind API-key authentication", () => {
    expect(
      resolveOwnerFileAccessPolicy(
        "*",
        "owner-secret",
        "linux",
        ["/home/alice"],
      ),
    ).toEqual({
      fullDiskReadRequested: true,
      ownerFullDiskRead: true,
      allowedDirs: [],
    });
  });

  it("fails a bare full-disk request closed to the safe default roots", () => {
    expect(
      resolveOwnerFileAccessPolicy("*", undefined, "linux", ["/home/alice"]),
    ).toEqual({
      fullDiskReadRequested: true,
      ownerFullDiskRead: false,
      allowedDirs: ["/home/alice"],
    });
    expect(
      resolveOwnerFileAccessPolicy("*", "  ", "linux", ["/home/alice"]),
    ).toEqual({
      fullDiskReadRequested: true,
      ownerFullDiskRead: false,
      allowedDirs: ["/home/alice"],
    });
  });

  it("preserves ordinary scoped directory configuration", () => {
    expect(
      resolveOwnerFileAccessPolicy(
        "/home/alice, /opt/project",
        undefined,
        "linux",
        ["/fallback"],
      ),
    ).toEqual({
      fullDiskReadRequested: false,
      ownerFullDiskRead: false,
      allowedDirs: ["/home/alice", "/opt/project"],
    });
  });

  it("rejects non-empty configurations without a path", () => {
    expect(() => parseAllowedDirectories(",", "linux", ["/home/alice"]))
      .toThrow("at least one path");
    expect(() => parseAllowedDirectories(" , , ", "linux"))
      .toThrow("at least one path");
  });

  it("parses and resolves configured allowed directories", () => {
    expect(parseAllowedDirectories("/home/alice, /opt/project", "linux"))
      .toEqual(["/home/alice", "/opt/project"]);
    expect(parseAllowedDirectories("C:\\Users\\alice", "win32"))
      .toEqual(["C:\\Users\\alice"]);
  });
});
