import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { join } from "node:path";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import {
  hashHunkChangeLines,
  type HunkFingerprint,
  stageFiles,
  stageHunks,
  unstageFiles,
  unstageHunks,
  gitCommit,
  getStagedDiff,
  listGitFiles,
  listGitFilesForClient,
  listFileSystemFiles,
  listProjectFilesAndDirectories,
  listProjectFilesAndDirectoriesForClient,
  listProjectFiles,
  listBranches,
  createBranch,
  checkoutBranch,
  revertFiles,
  revertHunks,
  gitStatus,
} from "./git-operations.js";

// ---- Test Helpers ----

/** Create a temporary git repository with an initial commit. */
function createTempRepo(): string {
  const dir = join(tmpdir(), `git-ops-test-${randomUUID().slice(0, 8)}`);
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init"], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  execFileSync("git", ["config", "commit.gpgsign", "false"], { cwd: dir });
  writeFileSync(join(dir, "initial.txt"), "initial\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial"], { cwd: dir });
  return dir;
}

function createTempProject(): string {
  const dir = join(tmpdir(), `git-ops-fs-test-${randomUUID().slice(0, 8)}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

function gitCmd(args: string[], cwd: string): string {
  return execFileSync(
    "git",
    ["-c", "core.quotePath=false", ...args],
    { cwd, encoding: "utf-8" },
  ).trim();
}

function createBareRemote(): string {
  const dir = join(tmpdir(), `git-ops-remote-${randomUUID().slice(0, 8)}`);
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init", "--bare"], { cwd: dir });
  return dir;
}

// ---- Phase 1: Staging ----

describe("gitStatus", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("reports clean repositories without uncommitted changes", () => {
    expect(gitStatus(repo)).toEqual({
      hasUncommittedChanges: false,
      stagedCount: 0,
      unstagedCount: 0,
      untrackedCount: 0,
      remoteStatusIncluded: false,
      hasRemoteChanges: false,
      commitsAhead: 0,
      commitsBehind: 0,
      hasUpstream: false,
    });
  });

  it("counts unstaged tracked changes", () => {
    writeFileSync(join(repo, "initial.txt"), "changed\n");

    expect(gitStatus(repo)).toEqual({
      hasUncommittedChanges: true,
      stagedCount: 0,
      unstagedCount: 1,
      untrackedCount: 0,
      remoteStatusIncluded: false,
      hasRemoteChanges: false,
      commitsAhead: 0,
      commitsBehind: 0,
      hasUpstream: false,
    });
  });

  it("counts staged changes", () => {
    writeFileSync(join(repo, "initial.txt"), "changed\n");
    execFileSync("git", ["add", "initial.txt"], { cwd: repo });

    expect(gitStatus(repo)).toEqual({
      hasUncommittedChanges: true,
      stagedCount: 1,
      unstagedCount: 0,
      untrackedCount: 0,
      remoteStatusIncluded: false,
      hasRemoteChanges: false,
      commitsAhead: 0,
      commitsBehind: 0,
      hasUpstream: false,
    });
  });

  it("counts untracked files separately", () => {
    writeFileSync(join(repo, "new.txt"), "new\n");

    expect(gitStatus(repo)).toEqual({
      hasUncommittedChanges: true,
      stagedCount: 0,
      unstagedCount: 0,
      untrackedCount: 1,
      remoteStatusIncluded: false,
      hasRemoteChanges: false,
      commitsAhead: 0,
      commitsBehind: 0,
      hasUpstream: false,
    });
  });

  it("includes pushable commits when remote status is requested", () => {
    const remote = createBareRemote();
    try {
      const current = gitCmd(["rev-parse", "--abbrev-ref", "HEAD"], repo);
      gitCmd(["remote", "add", "origin", remote], repo);
      gitCmd(["push", "-u", "origin", current], repo);
      writeFileSync(join(repo, "ahead.txt"), "ahead\n");
      gitCmd(["add", "ahead.txt"], repo);
      gitCmd(["commit", "-m", "ahead"], repo);

      expect(gitStatus(repo, { includeRemote: true })).toMatchObject({
        remoteStatusIncluded: true,
        hasRemoteChanges: true,
        commitsAhead: 1,
        commitsBehind: 0,
        hasUpstream: true,
        branch: current,
      });
    } finally {
      rmSync(remote, { recursive: true, force: true });
    }
  });

  it("includes pullable commits when remote status is requested", () => {
    const remote = createBareRemote();
    const clone = join(tmpdir(), `git-ops-clone-${randomUUID().slice(0, 8)}`);
    try {
      const current = gitCmd(["rev-parse", "--abbrev-ref", "HEAD"], repo);
      gitCmd(["remote", "add", "origin", remote], repo);
      gitCmd(["push", "-u", "origin", current], repo);
      execFileSync("git", ["clone", "--branch", current, remote, clone]);
      execFileSync("git", ["config", "user.email", "test@test.com"], {
        cwd: clone,
      });
      execFileSync("git", ["config", "user.name", "Test"], { cwd: clone });
      execFileSync("git", ["config", "commit.gpgsign", "false"], { cwd: clone });
      writeFileSync(join(clone, "behind.txt"), "behind\n");
      gitCmd(["add", "behind.txt"], clone);
      gitCmd(["commit", "-m", "behind"], clone);
      gitCmd(["push"], clone);

      expect(gitStatus(repo, { includeRemote: true })).toMatchObject({
        remoteStatusIncluded: true,
        hasRemoteChanges: true,
        commitsAhead: 0,
        commitsBehind: 1,
        hasUpstream: true,
        branch: current,
      });
    } finally {
      rmSync(remote, { recursive: true, force: true });
      rmSync(clone, { recursive: true, force: true });
    }
  });
});

describe("stageFiles", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("stages specified files into the index", () => {
    writeFileSync(join(repo, "a.txt"), "aaa\n");
    writeFileSync(join(repo, "b.txt"), "bbb\n");

    stageFiles(repo, ["a.txt"]);

    const staged = gitCmd(["diff", "--cached", "--name-only"], repo);
    expect(staged).toBe("a.txt");
  });

  it("stages multiple files at once", () => {
    writeFileSync(join(repo, "a.txt"), "aaa\n");
    writeFileSync(join(repo, "b.txt"), "bbb\n");

    stageFiles(repo, ["a.txt", "b.txt"]);

    const staged = gitCmd(["diff", "--cached", "--name-only"], repo);
    expect(staged.split("\n").sort()).toEqual(["a.txt", "b.txt"]);
  });

  it("throws for non-existent file", () => {
    expect(() => stageFiles(repo, ["nonexistent.txt"])).toThrow();
  });

  it("stages a file with non-ASCII characters in the path", () => {
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs", "あいう.md"), "hello\n");

    stageFiles(repo, ["docs/あいう.md"]);

    const staged = gitCmd(["diff", "--cached", "--name-only"], repo);
    expect(staged).toBe("docs/あいう.md");
  });

  it("stages a file with spaces in the path", () => {
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs", "空 白.md"), "hello\n");

    stageFiles(repo, ["docs/空 白.md"]);

    const staged = gitCmd(["diff", "--cached", "--name-only"], repo);
    expect(staged).toBe("docs/空 白.md");
  });
});

describe("stageHunks", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("stages only the specified hunk from a multi-hunk file", () => {
    // Create a file with multiple separated regions
    const lines: string[] = [];
    for (let i = 0; i < 20; i++) lines.push(`line ${i}`);
    writeFileSync(join(repo, "multi.txt"), lines.join("\n") + "\n");
    execFileSync("git", ["add", "multi.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add multi"], { cwd: repo });

    // Modify two separated regions to create two hunks
    const modified = [...lines];
    modified[2] = "CHANGED line 2";
    modified[17] = "CHANGED line 17";
    writeFileSync(join(repo, "multi.txt"), modified.join("\n") + "\n");

    // Stage only hunk 0
    stageHunks(repo, [{ file: "multi.txt", hunkIndex: 0 }]);

    // Verify only the first change is staged
    const cachedDiff = gitCmd(["diff", "--cached"], repo);
    expect(cachedDiff).toContain("CHANGED line 2");
    expect(cachedDiff).not.toContain("CHANGED line 17");

    // Verify the second change is still in working tree
    const workDiff = gitCmd(["diff"], repo);
    expect(workDiff).toContain("CHANGED line 17");
  });

  it("stages all requested hunks when multiple specified", () => {
    const lines: string[] = [];
    for (let i = 0; i < 20; i++) lines.push(`line ${i}`);
    writeFileSync(join(repo, "multi.txt"), lines.join("\n") + "\n");
    execFileSync("git", ["add", "multi.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add multi"], { cwd: repo });

    const modified = [...lines];
    modified[2] = "CHANGED line 2";
    modified[17] = "CHANGED line 17";
    writeFileSync(join(repo, "multi.txt"), modified.join("\n") + "\n");

    stageHunks(repo, [
      { file: "multi.txt", hunkIndex: 0 },
      { file: "multi.txt", hunkIndex: 1 },
    ]);

    const cachedDiff = gitCmd(["diff", "--cached"], repo);
    expect(cachedDiff).toContain("CHANGED line 2");
    expect(cachedDiff).toContain("CHANGED line 17");
  });

  it("throws for out-of-range hunk index", () => {
    writeFileSync(join(repo, "a.txt"), "changed\n");

    // a.txt is untracked, stage it first then modify
    execFileSync("git", ["add", "a.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add a"], { cwd: repo });
    writeFileSync(join(repo, "a.txt"), "modified\n");

    expect(() => stageHunks(repo, [{ file: "a.txt", hunkIndex: 5 }])).toThrow(
      /out of range/,
    );
  });

  it("stages a hunk from an untracked file", () => {
    const content = Array.from({ length: 12 }, (_, i) => `line ${i}`).join("\n");
    writeFileSync(join(repo, "new.txt"), `${content}\n`);

    stageHunks(repo, [{ file: "new.txt", hunkIndex: 0 }]);

    const cachedDiff = gitCmd(["diff", "--cached", "--", "new.txt"], repo);
    expect(cachedDiff).toContain("new file mode 100644");
    expect(cachedDiff).toContain("+line 0");
  });

  it("stages a hunk from an untracked file with non-ASCII path", () => {
    mkdirSync(join(repo, "docs"), { recursive: true });
    const content = Array.from({ length: 12 }, (_, i) => `line ${i}`).join("\n");
    writeFileSync(join(repo, "docs", "あいう.md"), `${content}\n`);

    stageHunks(repo, [{ file: "docs/あいう.md", hunkIndex: 0 }]);

    const cachedDiff = gitCmd(["diff", "--cached", "--", "docs/あいう.md"], repo);
    expect(cachedDiff).toContain("new file mode 100644");
    expect(cachedDiff).toContain("+++ b/docs/あいう.md");
  });
});

describe("unstageFiles", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("removes staged files from the index", () => {
    writeFileSync(join(repo, "a.txt"), "aaa\n");
    execFileSync("git", ["add", "a.txt"], { cwd: repo });

    unstageFiles(repo, ["a.txt"]);

    const staged = gitCmd(["diff", "--cached", "--name-only"], repo);
    expect(staged).toBe("");
  });

  it("is safe when file is not staged", () => {
    // Should not throw for an already-unstaged tracked file
    expect(() => unstageFiles(repo, ["initial.txt"])).not.toThrow();
  });
});

describe("unstageHunks", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("unstages only the specified hunk", () => {
    const lines: string[] = [];
    for (let i = 0; i < 20; i++) lines.push(`line ${i}`);
    writeFileSync(join(repo, "multi.txt"), lines.join("\n") + "\n");
    execFileSync("git", ["add", "multi.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add multi"], { cwd: repo });

    const modified = [...lines];
    modified[2] = "CHANGED line 2";
    modified[17] = "CHANGED line 17";
    writeFileSync(join(repo, "multi.txt"), modified.join("\n") + "\n");
    execFileSync("git", ["add", "multi.txt"], { cwd: repo });

    unstageHunks(repo, [{ file: "multi.txt", hunkIndex: 0 }]);

    const cachedDiff = gitCmd(["diff", "--cached"], repo);
    expect(cachedDiff).not.toContain("CHANGED line 2");
    expect(cachedDiff).toContain("CHANGED line 17");

    const workDiff = gitCmd(["diff"], repo);
    expect(workDiff).toContain("CHANGED line 2");
    expect(workDiff).not.toContain("CHANGED line 17");
  });

  it("throws for out-of-range hunk index", () => {
    writeFileSync(join(repo, "a.txt"), "changed\n");
    execFileSync("git", ["add", "a.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add a"], { cwd: repo });
    writeFileSync(join(repo, "a.txt"), "modified\n");
    execFileSync("git", ["add", "a.txt"], { cwd: repo });

    expect(() => unstageHunks(repo, [{ file: "a.txt", hunkIndex: 5 }])).toThrow(
      /out of range/,
    );
  });
});

describe("revertHunks", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("reverts only the specified working-tree hunk", () => {
    const lines: string[] = [];
    for (let i = 0; i < 20; i++) lines.push(`line ${i}`);
    writeFileSync(join(repo, "multi.txt"), lines.join("\n") + "\n");
    execFileSync("git", ["add", "multi.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add multi"], { cwd: repo });

    const modified = [...lines];
    modified[2] = "CHANGED line 2";
    modified[17] = "CHANGED line 17";
    writeFileSync(join(repo, "multi.txt"), modified.join("\n") + "\n");

    revertHunks(repo, [{ file: "multi.txt", hunkIndex: 1 }]);

    const workDiff = gitCmd(["diff"], repo);
    expect(workDiff).toContain("CHANGED line 2");
    expect(workDiff).not.toContain("CHANGED line 17");
  });

  it("throws for out-of-range hunk index", () => {
    writeFileSync(join(repo, "a.txt"), "changed\n");
    execFileSync("git", ["add", "a.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add a"], { cwd: repo });
    writeFileSync(join(repo, "a.txt"), "modified\n");

    expect(() => revertHunks(repo, [{ file: "a.txt", hunkIndex: 5 }])).toThrow(
      /out of range/,
    );
  });

  it("reverts a hunk from an untracked file", () => {
    const lines: string[] = [];
    for (let i = 0; i < 20; i++) lines.push(`line ${i}`);
    writeFileSync(join(repo, "new.txt"), lines.join("\n") + "\n");

    revertHunks(repo, [{ file: "new.txt", hunkIndex: 0 }]);

    expect(existsSync(join(repo, "new.txt"))).toBe(false);
    expect(gitCmd(["status", "--short"], repo)).toBe("");
  });
});

describe("revertFiles", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("reverts tracked file changes", () => {
    writeFileSync(join(repo, "initial.txt"), "changed\n");

    revertFiles(repo, ["initial.txt"]);

    expect(gitCmd(["diff", "--name-only"], repo)).toBe("");
    expect(gitCmd(["show", "HEAD:initial.txt"], repo)).toBe(
      readFileSync(join(repo, "initial.txt"), "utf-8").trim(),
    );
  });

  it("removes untracked files", () => {
    writeFileSync(join(repo, "new.txt"), "new\n");

    revertFiles(repo, ["new.txt"]);

    expect(existsSync(join(repo, "new.txt"))).toBe(false);
    expect(gitCmd(["status", "--short"], repo)).toBe("");
  });

  it("handles tracked and untracked files together", () => {
    writeFileSync(join(repo, "initial.txt"), "changed\n");
    writeFileSync(join(repo, "new.txt"), "new\n");

    revertFiles(repo, ["initial.txt", "new.txt"]);

    expect(gitCmd(["diff", "--name-only"], repo)).toBe("");
    expect(existsSync(join(repo, "new.txt"))).toBe(false);
    expect(gitCmd(["status", "--short"], repo)).toBe("");
  });
});

// ---- Phase 2: Commit / Status ----

describe("gitCommit", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("creates a commit and returns hash + message", () => {
    writeFileSync(join(repo, "new.txt"), "hello\n");
    execFileSync("git", ["add", "new.txt"], { cwd: repo });

    const result = gitCommit(repo, "feat: add new file");

    expect(result.hash).toMatch(/^[0-9a-f]+$/);
    expect(result.message).toBe("feat: add new file");

    // Verify commit exists in log
    const log = gitCmd(["log", "--oneline", "-1"], repo);
    expect(log).toContain("feat: add new file");
  });

  it("throws when nothing is staged", () => {
    expect(() => gitCommit(repo, "empty commit")).toThrow(/Nothing to commit/);
  });
});

describe("getStagedDiff", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("returns only staged changes", () => {
    writeFileSync(join(repo, "initial.txt"), "staged\n");
    execFileSync("git", ["add", "initial.txt"], { cwd: repo });
    writeFileSync(join(repo, "other.txt"), "unstaged\n");

    const diff = getStagedDiff(repo);

    expect(diff).toContain("+++ b/initial.txt");
    expect(diff).not.toContain("other.txt");
  });

  it("returns empty string for clean repo", () => {
    expect(getStagedDiff(repo)).toBe("");
  });

  it("returns an unescaped diff for non-ASCII paths", () => {
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs", "あいう.md"), "hello\n");
    execFileSync("git", ["add", "docs/あいう.md"], { cwd: repo });

    const diff = getStagedDiff(repo);

    expect(diff).toContain("diff --git a/docs/あいう.md b/docs/あいう.md");
    expect(diff).not.toContain("\\343\\201");
  });

  it("returns an unescaped diff for paths with spaces", () => {
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs", "空 白.md"), "hello\n");
    execFileSync("git", ["add", "docs/空 白.md"], { cwd: repo });

    const diff = getStagedDiff(repo);

    expect(diff).toContain("diff --git a/docs/空 白.md b/docs/空 白.md");
    expect(diff).not.toContain("\\347\\251\\272");
  });
});

describe("listGitFiles", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
    execFileSync("git", ["config", "core.quotePath", "true"], { cwd: repo });
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("returns unescaped tracked and untracked non-ASCII paths", () => {
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs", "あいう.md"), "hello\n");
    writeFileSync(join(repo, "docs", "空 白.md"), "space\n");
    execFileSync("git", ["add", "docs/あいう.md"], { cwd: repo });

    const files = listGitFiles(repo);

    expect(files).toContain("docs/あいう.md");
    expect(files).toContain("docs/空 白.md");
    expect(files.join("\n")).not.toContain("\\343\\201");
    expect(files.join("\n")).not.toContain("\\347\\251");
  });

  it("keeps paths with embedded newlines intact", () => {
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs", "line\nbreak.md"), "hello\n");

    const files = listGitFiles(repo);

    expect(files).toContain("docs/line\nbreak.md");
  });

  it("does not mark an exact entry limit as truncated", async () => {
    writeFileSync(join(repo, "a.md"), "a\n");
    writeFileSync(join(repo, "b.md"), "b\n");

    await expect(
      listGitFilesForClient(repo, {
        maxEntries: 3,
        maxBytes: 1024,
      }),
    ).resolves.toMatchObject({
      truncated: false,
      totalFiles: 3,
    });
  });

  it("stops after observing an entry beyond the limit", async () => {
    writeFileSync(join(repo, "a.md"), "a\n");
    writeFileSync(join(repo, "b.md"), "b\n");
    writeFileSync(join(repo, "c.md"), "c\n");

    const result = await listGitFilesForClient(repo, {
      maxEntries: 2,
      maxBytes: 1024,
    });

    expect(result.files).toHaveLength(2);
    expect(result.truncated).toBe(true);
    expect(result.totalFiles).toBeUndefined();
  });

  it("limits serialized UTF-8 file entry bytes", async () => {
    writeFileSync(join(repo, "あ.md"), "a\n");

    const result = await listGitFilesForClient(repo, {
      maxEntries: 10,
      maxBytes: Buffer.byteLength(JSON.stringify("あ.md"), "utf8"),
    });

    expect(result.files).toEqual(["あ.md"]);
    expect(result.truncated).toBe(true);
  });
});

describe("listFileSystemFiles", () => {
  let project: string;

  beforeEach(() => {
    project = createTempProject();
  });

  afterEach(() => {
    rmSync(project, { recursive: true, force: true });
  });

  it("returns relative files for non-git project directories", async () => {
    mkdirSync(join(project, "notes"), { recursive: true });
    mkdirSync(join(project, ".obsidian"), { recursive: true });
    writeFileSync(join(project, "README.md"), "hello\n");
    writeFileSync(join(project, "notes", "today.md"), "note\n");
    writeFileSync(join(project, ".obsidian", "app.json"), "{}\n");

    await expect(listFileSystemFiles(project)).resolves.toEqual([
      ".obsidian/app.json",
      "notes/today.md",
      "README.md",
    ]);
  });

  it("skips generated and cache directories", async () => {
    mkdirSync(join(project, "notes"), { recursive: true });
    mkdirSync(join(project, "node_modules", "pkg"), { recursive: true });
    mkdirSync(join(project, "build"), { recursive: true });
    mkdirSync(join(project, "dist"), { recursive: true });
    mkdirSync(join(project, ".git", "objects"), { recursive: true });
    writeFileSync(join(project, "notes", "today.md"), "note\n");
    writeFileSync(join(project, "node_modules", "pkg", "index.js"), "pkg\n");
    writeFileSync(join(project, "build", "app.js"), "build\n");
    writeFileSync(join(project, "dist", "app.js"), "dist\n");
    writeFileSync(join(project, ".git", "config"), "git\n");

    await expect(listFileSystemFiles(project)).resolves.toEqual([
      "notes/today.md",
    ]);
  });

  it("does not follow symbolic links", async () => {
    mkdirSync(join(project, "target"), { recursive: true });
    writeFileSync(join(project, "target", "secret.md"), "secret\n");
    symlinkSync("target", join(project, "linked-target"), "dir");

    await expect(listFileSystemFiles(project)).resolves.toEqual([
      "target/secret.md",
    ]);
  });

  it("honors max depth and max files", async () => {
    mkdirSync(join(project, "a", "b", "c"), { recursive: true });
    writeFileSync(join(project, "a", "one.md"), "1\n");
    writeFileSync(join(project, "a", "two.md"), "2\n");
    writeFileSync(join(project, "a", "b", "deep.md"), "deep\n");
    writeFileSync(join(project, "a", "b", "c", "too-deep.md"), "deep\n");

    await expect(
      listFileSystemFiles(project, { maxDepth: 2, maxFiles: 2 }),
    ).resolves.toEqual(["a/one.md", "a/two.md"]);
  });
});

describe("listProjectFiles", () => {
  let project: string;

  afterEach(() => {
    if (project) rmSync(project, { recursive: true, force: true });
  });

  it("falls back to filesystem listing for non-git projects", async () => {
    project = createTempProject();
    mkdirSync(join(project, "notes"), { recursive: true });
    writeFileSync(join(project, "notes", "today.md"), "note\n");

    await expect(listProjectFiles(project)).resolves.toEqual([
      "notes/today.md",
    ]);
  });

  it("uses git listing when the project is a git repository", async () => {
    project = createTempRepo();
    writeFileSync(join(project, ".gitignore"), "ignored.log\n");
    writeFileSync(join(project, "tracked.md"), "tracked\n");
    writeFileSync(join(project, "ignored.log"), "ignored\n");
    execFileSync("git", ["add", ".gitignore", "tracked.md"], { cwd: project });

    const files = await listProjectFiles(project);

    expect(files).toContain("tracked.md");
    expect(files).not.toContain("ignored.log");
  });
});

describe("listProjectFilesAndDirectories", () => {
  let project: string;

  afterEach(() => {
    if (project) rmSync(project, { recursive: true, force: true });
  });

  it("adds directory mention candidates with trailing slashes", async () => {
    project = createTempRepo();
    mkdirSync(join(project, "apps", "mobile", "lib"), { recursive: true });
    writeFileSync(join(project, "apps", "mobile", "lib", "main.dart"), "\n");
    writeFileSync(join(project, "README.md"), "\n");
    execFileSync("git", ["add", "."], { cwd: project });

    await expect(listProjectFilesAndDirectories(project)).resolves.toEqual([
      "apps/",
      "apps/mobile/",
      "apps/mobile/lib/",
      "apps/mobile/lib/main.dart",
      "initial.txt",
      "README.md",
    ]);
  });

  it("limits client entries after adding directory candidates", async () => {
    project = createTempRepo();
    mkdirSync(join(project, "src", "features"), { recursive: true });
    writeFileSync(join(project, "src", "features", "a.ts"), "a\n");
    writeFileSync(join(project, "src", "features", "b.ts"), "b\n");

    const result = await listProjectFilesAndDirectoriesForClient(project, {
      maxEntries: 3,
      maxBytes: 1024,
    });

    expect(result.files).toHaveLength(3);
    expect(result.truncated).toBe(true);
  });

  it("does not truncate an exact filesystem fallback limit", async () => {
    project = createTempProject();
    writeFileSync(join(project, "a.txt"), "a\n");
    writeFileSync(join(project, "b.txt"), "b\n");
    writeFileSync(join(project, "c.txt"), "c\n");

    await expect(
      listProjectFilesAndDirectoriesForClient(project, {
        maxEntries: 3,
        maxBytes: 1024,
      }),
    ).resolves.toEqual({
      files: ["a.txt", "b.txt", "c.txt"],
      truncated: false,
      totalFiles: 3,
    });
  });

  it("reports a truncated filesystem fallback at the depth limit", async () => {
    project = createTempProject();
    mkdirSync(join(project, "a", "b", "c"), { recursive: true });
    writeFileSync(join(project, "a", "b", "c", "deep.txt"), "deep\n");

    await expect(
      listProjectFilesAndDirectoriesForClient(project, {
        maxDepth: 2,
        maxEntries: 10,
        maxBytes: 1024,
      }),
    ).resolves.toEqual({
      files: [],
      truncated: true,
      totalFiles: undefined,
    });
  });
});

// ---- Phase 3: Branch Operations ----

describe("listBranches", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
    // Create some branches
    execFileSync("git", ["branch", "feat/login"], { cwd: repo });
    execFileSync("git", ["branch", "feat/signup"], { cwd: repo });
    execFileSync("git", ["branch", "fix/bug"], { cwd: repo });
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("returns current branch and all branches", () => {
    const result = listBranches(repo);

    expect(result.current).toMatch(/^(main|master)$/);
    expect(result.branches).toContain("feat/login");
    expect(result.branches).toContain("feat/signup");
    expect(result.branches).toContain("fix/bug");
    expect(result.branches.length).toBeGreaterThanOrEqual(4); // main + 3 created
  });

  it("includes ahead/behind status for branches with upstream", () => {
    const remote = createBareRemote();
    try {
      execFileSync("git", ["remote", "add", "origin", remote], { cwd: repo });
      const current = gitCmd(["rev-parse", "--abbrev-ref", "HEAD"], repo);
      execFileSync("git", ["push", "-u", "origin", current], { cwd: repo });

      execFileSync("git", ["checkout", "feat/login"], { cwd: repo });
      execFileSync("git", ["push", "-u", "origin", "feat/login"], { cwd: repo });

      writeFileSync(join(repo, "ahead.txt"), "ahead\n");
      execFileSync("git", ["add", "ahead.txt"], { cwd: repo });
      execFileSync("git", ["commit", "-m", "ahead commit"], { cwd: repo });

      const result = listBranches(repo);
      expect(result.remoteStatusByBranch["feat/login"]).toMatchObject({
        ahead: 1,
        behind: 0,
        hasUpstream: true,
      });
    } finally {
      rmSync(remote, { recursive: true, force: true });
    }
  });

  it("includes diverged ahead and behind status for branches with upstream", () => {
    const remote = createBareRemote();
    const clone = join(tmpdir(), `git-ops-clone-${randomUUID().slice(0, 8)}`);
    try {
      execFileSync("git", ["remote", "add", "origin", remote], { cwd: repo });
      execFileSync("git", ["checkout", "feat/login"], { cwd: repo });
      execFileSync("git", ["push", "-u", "origin", "feat/login"], { cwd: repo });

      writeFileSync(join(repo, "local.txt"), "local\n");
      execFileSync("git", ["add", "local.txt"], { cwd: repo });
      execFileSync("git", ["commit", "-m", "local commit"], { cwd: repo });

      execFileSync("git", ["clone", remote, clone]);
      execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: clone });
      execFileSync("git", ["config", "user.name", "Test"], { cwd: clone });
      execFileSync("git", ["config", "commit.gpgsign", "false"], { cwd: clone });
      execFileSync("git", ["checkout", "feat/login"], { cwd: clone });
      writeFileSync(join(clone, "remote.txt"), "remote\n");
      execFileSync("git", ["add", "remote.txt"], { cwd: clone });
      execFileSync("git", ["commit", "-m", "remote commit"], { cwd: clone });
      execFileSync("git", ["push", "origin", "feat/login"], { cwd: clone });

      execFileSync("git", ["fetch", "origin"], { cwd: repo });

      const result = listBranches(repo);
      expect(result.remoteStatusByBranch["feat/login"]).toMatchObject({
        ahead: 1,
        behind: 1,
        hasUpstream: true,
      });
    } finally {
      rmSync(clone, { recursive: true, force: true });
      rmSync(remote, { recursive: true, force: true });
    }
  });

  it("reports no upstream for branches without tracking", () => {
    const result = listBranches(repo);
    expect(result.remoteStatusByBranch["feat/login"]).toMatchObject({
      ahead: 0,
      behind: 0,
      hasUpstream: false,
    });
  });

  it("does not run per-branch rev-list commands for stale upstream refs", () => {
    execFileSync("git", ["remote", "add", "origin", repo], { cwd: repo });
    execFileSync("git", ["config", "branch.feat/login.remote", "origin"], {
      cwd: repo,
    });
    execFileSync(
      "git",
      ["config", "branch.feat/login.merge", "refs/heads/deleted-upstream"],
      { cwd: repo },
    );

    const originalWrite = process.stderr.write;
    let stderr = "";
    process.stderr.write = function write(chunk, ...args) {
      stderr += String(chunk);
      return originalWrite.call(this, chunk, ...args);
    } as typeof process.stderr.write;

    try {
      const result = listBranches(repo);
      expect(result.remoteStatusByBranch["feat/login"]).toMatchObject({
        ahead: 0,
        behind: 0,
        hasUpstream: true,
      });
    } finally {
      process.stderr.write = originalWrite;
    }

    expect(stderr).not.toContain("fatal:");
    expect(stderr).not.toContain("deleted-upstream");
  });

  it("includes branches checked out in linked worktrees", () => {
    const worktree = join(
      tmpdir(),
      `git-ops-worktree-${randomUUID().slice(0, 8)}`,
    );
    try {
      execFileSync("git", ["worktree", "add", worktree, "feat/login"], {
        cwd: repo,
      });

      const result = listBranches(repo);
      expect(result.checkedOutBranches).toContain(result.current);
      expect(result.checkedOutBranches).toContain("feat/login");
    } finally {
      execFileSync("git", ["worktree", "remove", "--force", worktree], {
        cwd: repo,
      });
      rmSync(worktree, { recursive: true, force: true });
    }
  });
});

describe("createBranch", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("creates a branch without checkout", () => {
    createBranch(repo, "new-branch", false);

    const branches = gitCmd(["branch", "--list"], repo);
    expect(branches).toContain("new-branch");

    // Should still be on the original branch
    const current = gitCmd(["rev-parse", "--abbrev-ref", "HEAD"], repo);
    expect(current).toMatch(/^(main|master)$/);
  });

  it("creates and checks out a branch when checkout=true", () => {
    createBranch(repo, "new-branch", true);

    const current = gitCmd(["rev-parse", "--abbrev-ref", "HEAD"], repo);
    expect(current).toBe("new-branch");
  });

  it("throws for duplicate branch name", () => {
    createBranch(repo, "dup-branch", false);
    expect(() => createBranch(repo, "dup-branch", false)).toThrow();
  });
});

describe("checkoutBranch", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
    execFileSync("git", ["branch", "other"], { cwd: repo });
  });
  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  it("switches to the specified branch", () => {
    checkoutBranch(repo, "other");

    const current = gitCmd(["rev-parse", "--abbrev-ref", "HEAD"], repo);
    expect(current).toBe("other");
  });

  it("throws for non-existent branch", () => {
    expect(() => checkoutBranch(repo, "nonexistent")).toThrow();
  });
});

// ---- Hunk fingerprint addressing (P0-1) ----

/**
 * Reproduce what the mobile client displays: run the same default-context
 * `git diff --no-color` the app renders, and derive one fingerprint per
 * displayed hunk (header quadruple + sha1 over the +/- change lines).
 */
function displayedHunkFingerprints(
  repo: string,
  file: string,
  options?: { cached?: boolean },
): HunkFingerprint[] {
  const args = options?.cached
    ? ["diff", "--cached", "--no-color", "--", file]
    : ["diff", "--no-color", "--", file];
  const diff = execFileSync("git", ["-c", "core.quotePath=false", ...args], {
    cwd: repo,
    encoding: "utf-8",
  });
  const headerRe = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;
  const lines = diff.split("\n");
  const starts: number[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (headerRe.test(lines[i])) starts.push(i);
  }
  return starts.map((start, idx) => {
    const match = headerRe.exec(lines[start]);
    if (!match) throw new Error("unreachable: header matched above");
    const end = idx + 1 < starts.length ? starts[idx + 1] : lines.length;
    const changeLines = lines
      .slice(start + 1, end)
      .filter((line) => line.startsWith("+") || line.startsWith("-"));
    return {
      oldStart: Number(match[1]),
      oldLines: match[2] === undefined ? 1 : Number(match[2]),
      newStart: Number(match[3]),
      newLines: match[4] === undefined ? 1 : Number(match[4]),
      changesHash: hashHunkChangeLines(changeLines),
    };
  });
}

describe("hunk fingerprint addressing", () => {
  let repo: string;

  beforeEach(() => {
    repo = createTempRepo();
  });

  afterEach(() => {
    rmSync(repo, { recursive: true, force: true });
  });

  /** Commit a file of `count` numbered lines and return them. */
  function seedFile(name: string, count = 30): string[] {
    const lines = Array.from({ length: count }, (_, i) => `line ${i}`);
    writeFileSync(join(repo, name), `${lines.join("\n")}\n`);
    execFileSync("git", ["add", name], { cwd: repo });
    execFileSync("git", ["commit", "-m", `add ${name}`], { cwd: repo });
    return lines;
  }

  it("pins the changes-hash contract shared with the mobile client", () => {
    // Golden value — apps/mobile/lib/utils/diff_parser.dart pins the same one.
    expect(hashHunkChangeLines(["-old line", "+new line"])).toBe(
      "72e37c089cc6615e099c2668f6cd4c797d676f9f",
    );
  });

  // Changes 2–4 lines apart merge into ONE displayed hunk under the default
  // 3 context lines, but split into TWO under --unified=0 — exactly the regime
  // where the old index-based addressing reverted the wrong code.
  for (const gap of [2, 3, 4]) {
    it(`reverts exactly the displayed hunk when changes are ${gap} lines apart`, () => {
      const original = seedFile(`near-${gap}.txt`);
      const modified = [...original];
      modified[5] = "changed five";
      modified[5 + gap] = "changed other";
      writeFileSync(join(repo, `near-${gap}.txt`), `${modified.join("\n")}\n`);

      const fingerprints = displayedHunkFingerprints(repo, `near-${gap}.txt`);
      expect(fingerprints).toHaveLength(1);

      revertHunks(repo, [
        { file: `near-${gap}.txt`, hunkIndex: 0, fingerprint: fingerprints[0] },
      ]);

      expect(readFileSync(join(repo, `near-${gap}.txt`), "utf-8")).toBe(
        `${original.join("\n")}\n`,
      );
    });
  }

  it("stages the whole displayed hunk when changes are 3 lines apart", () => {
    const original = seedFile("stage-near.txt");
    const modified = [...original];
    modified[5] = "changed five";
    modified[8] = "changed eight";
    writeFileSync(join(repo, "stage-near.txt"), `${modified.join("\n")}\n`);

    const fingerprints = displayedHunkFingerprints(repo, "stage-near.txt");
    expect(fingerprints).toHaveLength(1);

    stageHunks(repo, [
      { file: "stage-near.txt", hunkIndex: 0, fingerprint: fingerprints[0] },
    ]);

    const staged = gitCmd(["diff", "--cached", "--", "stage-near.txt"], repo);
    expect(staged).toContain("changed five");
    expect(staged).toContain("changed eight");
    expect(gitCmd(["diff", "--", "stage-near.txt"], repo)).toBe("");
  });

  // The displayed diff (collectGitDiff) ships untrimmed stdout, so the
  // client hashes and counts untrimmed bytes. The Bridge-side re-run must
  // not trim either: a trailing whitespace-only context line or a trailing
  // \r would otherwise vanish, corrupting the patch or the hash.
  it("stages a hunk whose trailing context includes a blank line", () => {
    writeFileSync(join(repo, "blank-tail.txt"), "l1\nl2\nl3\nl4\nl5\n\n");
    execFileSync("git", ["add", "blank-tail.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add blank-tail"], { cwd: repo });
    writeFileSync(join(repo, "blank-tail.txt"), "l1\nl2\nl3x\nl4\nl5\n\n");

    const fingerprints = displayedHunkFingerprints(repo, "blank-tail.txt");
    expect(fingerprints).toHaveLength(1);

    stageHunks(repo, [
      { file: "blank-tail.txt", hunkIndex: 0, fingerprint: fingerprints[0] },
    ]);

    expect(gitCmd(["diff", "--cached", "--", "blank-tail.txt"], repo)).toContain(
      "l3x",
    );
    expect(gitCmd(["diff", "--", "blank-tail.txt"], repo)).toBe("");
  });

  it("reverts a CRLF hunk addressed by fingerprint", () => {
    const original = "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\n";
    writeFileSync(join(repo, "crlf.txt"), original);
    execFileSync("git", ["add", "crlf.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add crlf"], { cwd: repo });
    writeFileSync(join(repo, "crlf.txt"), "a\r\nb\r\nc\r\ndX\r\ne\r\nf\r\ng\r\n");

    const fingerprints = displayedHunkFingerprints(repo, "crlf.txt");
    expect(fingerprints).toHaveLength(1);

    revertHunks(repo, [
      { file: "crlf.txt", hunkIndex: 0, fingerprint: fingerprints[0] },
    ]);

    expect(readFileSync(join(repo, "crlf.txt"), "utf-8")).toBe(original);
  });

  it("stages an added line carrying trailing whitespace at the diff's end", () => {
    writeFileSync(join(repo, "ws-tail.txt"), "l1\nl2\nl3\n");
    execFileSync("git", ["add", "ws-tail.txt"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add ws-tail"], { cwd: repo });
    writeFileSync(join(repo, "ws-tail.txt"), "l1\nl2\nl3\ntail  \n");

    const fingerprints = displayedHunkFingerprints(repo, "ws-tail.txt");
    expect(fingerprints).toHaveLength(1);

    stageHunks(repo, [
      { file: "ws-tail.txt", hunkIndex: 0, fingerprint: fingerprints[0] },
    ]);

    expect(gitCmd(["diff", "--cached", "--", "ws-tail.txt"], repo)).toContain(
      "tail",
    );
    expect(gitCmd(["diff", "--", "ws-tail.txt"], repo)).toBe("");
  });

  it("reverts only the selected hunk when changes are far apart", () => {
    const original = seedFile("far.txt");
    const modified = [...original];
    modified[2] = "changed two";
    modified[17] = "changed seventeen";
    writeFileSync(join(repo, "far.txt"), `${modified.join("\n")}\n`);

    const fingerprints = displayedHunkFingerprints(repo, "far.txt");
    expect(fingerprints).toHaveLength(2);

    revertHunks(repo, [
      { file: "far.txt", hunkIndex: 1, fingerprint: fingerprints[1] },
    ]);

    const expected = [...original];
    expected[2] = "changed two";
    expect(readFileSync(join(repo, "far.txt"), "utf-8")).toBe(
      `${expected.join("\n")}\n`,
    );
  });

  it("unstages the displayed staged hunk", () => {
    const original = seedFile("unstage.txt");
    const modified = [...original];
    modified[5] = "changed five";
    writeFileSync(join(repo, "unstage.txt"), `${modified.join("\n")}\n`);
    execFileSync("git", ["add", "unstage.txt"], { cwd: repo });

    const fingerprints = displayedHunkFingerprints(repo, "unstage.txt", {
      cached: true,
    });
    expect(fingerprints).toHaveLength(1);

    unstageHunks(repo, [
      { file: "unstage.txt", hunkIndex: 0, fingerprint: fingerprints[0] },
    ]);

    expect(gitCmd(["diff", "--cached", "--", "unstage.txt"], repo)).toBe("");
    expect(gitCmd(["diff", "--", "unstage.txt"], repo)).toContain(
      "changed five",
    );
  });

  it("stages an untracked file's displayed hunk", () => {
    writeFileSync(join(repo, "brand-new.txt"), "alpha\nbeta\n");
    // The displayed diff for untracked files comes from the intent-to-add
    // dance the Bridge itself performs when producing diff_result.
    execFileSync("git", ["add", "--intent-to-add", "--", "brand-new.txt"], {
      cwd: repo,
    });
    const fingerprints = displayedHunkFingerprints(repo, "brand-new.txt");
    execFileSync("git", ["reset", "--", "brand-new.txt"], { cwd: repo });
    expect(fingerprints).toHaveLength(1);

    stageHunks(repo, [
      { file: "brand-new.txt", hunkIndex: 0, fingerprint: fingerprints[0] },
    ]);

    expect(
      gitCmd(["diff", "--cached", "--name-only", "--", "brand-new.txt"], repo),
    ).toBe("brand-new.txt");
  });

  it("rejects a stale fingerprint instead of touching the wrong lines", () => {
    const original = seedFile("stale.txt");
    const modified = [...original];
    modified[5] = "changed five";
    writeFileSync(join(repo, "stale.txt"), `${modified.join("\n")}\n`);
    const fingerprints = displayedHunkFingerprints(repo, "stale.txt");

    // The worktree moves on after the client captured the diff.
    modified[6] = "changed six";
    writeFileSync(join(repo, "stale.txt"), `${modified.join("\n")}\n`);

    expect(() =>
      revertHunks(repo, [
        { file: "stale.txt", hunkIndex: 0, fingerprint: fingerprints[0] },
      ]),
    ).toThrow(/no longer matches/);
    expect(readFileSync(join(repo, "stale.txt"), "utf-8")).toBe(
      `${modified.join("\n")}\n`,
    );
  });

  it("rejects a fingerprint for a file with no current diff", () => {
    seedFile("clean.txt");
    expect(() =>
      revertHunks(repo, [
        {
          file: "clean.txt",
          hunkIndex: 0,
          fingerprint: {
            oldStart: 1,
            oldLines: 1,
            newStart: 1,
            newLines: 1,
            changesHash: hashHunkChangeLines(["-a", "+b"]),
          },
        },
      ]),
    ).toThrow(/No current diff/);
  });

  it("still honours the legacy index-based path when fingerprints are absent", () => {
    const original = seedFile("legacy.txt");
    const modified = [...original];
    modified[2] = "changed two";
    modified[17] = "changed seventeen";
    writeFileSync(join(repo, "legacy.txt"), `${modified.join("\n")}\n`);

    // Old clients send bare {file, hunkIndex}: U0 splits these far-apart
    // changes into two hunks, index 1 is the second change.
    revertHunks(repo, [{ file: "legacy.txt", hunkIndex: 1 }]);

    const expected = [...original];
    expected[2] = "changed two";
    expect(readFileSync(join(repo, "legacy.txt"), "utf-8")).toBe(
      `${expected.join("\n")}\n`,
    );
  });
});
