import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { readCodexDesktopProjectCatalog } from "./codex-desktop-project-catalog.js";

const roots = new Set<string>();

async function codexHome(state: unknown): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-project-catalog-"));
  roots.add(root);
  await mkdir(root, { recursive: true });
  await writeFile(
    join(root, ".codex-global-state.json"),
    JSON.stringify(state),
    "utf8",
  );
  return root;
}

afterEach(async () => {
  await Promise.all(
    [...roots].map((root) => rm(root, { recursive: true, force: true })),
  );
  roots.clear();
});

describe("Codex Desktop project catalog", () => {
  it("uses the explicit Desktop project assignment and custom name", async () => {
    const home = await codexHome({
      "local-projects": {
        "project-1": {
          id: "project-1",
          name: "CC Pocket",
          rootPaths: ["/workspace/ccpocket"],
        },
      },
      "thread-project-assignments": {
        "thread-1": {
          projectKind: "local",
          projectId: "project-1",
          cwd: "/private/worktrees/ccpocket",
        },
      },
      "projectless-thread-ids": [],
    });

    const catalog = await readCodexDesktopProjectCatalog({ codexHome: home });

    expect(catalog.available).toBe(true);
    expect(catalog.groupingFor("thread-1", "/private/worktrees/ccpocket")).toEqual({
      projectGroupKind: "desktopProject",
      projectGroupingSnapshotComplete: true,
      projectGroupId: "project-1",
      projectGroupName: "CC Pocket",
      projectGroupPath: "/workspace/ccpocket",
    });
  });

  it("keeps projectless and unmatched Codex threads in one stable bucket", async () => {
    const home = await codexHome({
      "local-projects": {},
      "thread-project-assignments": {},
      "projectless-thread-ids": ["thread-explicit"],
    });
    const catalog = await readCodexDesktopProjectCatalog({ codexHome: home });

    expect(catalog.groupingFor("thread-explicit", "/private/tmp/a")).toEqual({
      projectGroupKind: "projectless",
      projectGroupingSnapshotComplete: true,
    });
    expect(catalog.groupingFor("thread-unassigned", "/private/tmp/b")).toEqual({
      projectGroupKind: "projectless",
      projectGroupingSnapshotComplete: true,
    });
  });

  it("accepts a structurally valid empty Desktop catalog", async () => {
    const home = await codexHome({
      "local-projects": {},
      "thread-project-assignments": {},
      "projectless-thread-ids": [],
    });

    const catalog = await readCodexDesktopProjectCatalog({ codexHome: home });

    expect(catalog.available).toBe(true);
    expect(catalog.groupingFor("thread-new", "/private/tmp/new")).toEqual({
      projectGroupKind: "projectless",
      projectGroupingSnapshotComplete: true,
    });
  });

  it("uses the longest registered root while an assignment is pending", async () => {
    const home = await codexHome({
      "local-projects": {
        parent: {
          id: "parent",
          name: "All work",
          rootPaths: ["/workspace"],
        },
        child: {
          id: "child",
          name: "Mobile",
          rootPaths: ["/workspace/mobile"],
        },
      },
      "thread-project-assignments": {},
      "projectless-thread-ids": [],
    });
    const catalog = await readCodexDesktopProjectCatalog({ codexHome: home });

    expect(catalog.matchesProjectName("mob")).toBe(true);
    expect(catalog.matchesProjectName("desktop only")).toBe(false);
    expect(catalog.groupingFor("thread-new", "/workspace/mobile/app")).toMatchObject({
      projectGroupId: "child",
      projectGroupName: "Mobile",
      projectGroupPath: "/workspace/mobile",
    });
  });

  it("refreshes a cached project name after Desktop rewrites global state", async () => {
    const home = await codexHome({
      "local-projects": {
        project: {
          id: "project",
          name: "Before",
          rootPaths: ["/workspace/project"],
        },
      },
      "thread-project-assignments": {
        thread: { projectId: "project" },
      },
      "projectless-thread-ids": [],
    });
    const before = await readCodexDesktopProjectCatalog({ codexHome: home });
    expect(before.groupingFor("thread", "/private/worktree")).toMatchObject({
      projectGroupName: "Before",
    });

    await writeFile(
      join(home, ".codex-global-state.json"),
      JSON.stringify({
        "local-projects": {
          project: {
            id: "project",
            name: "After rename",
            rootPaths: ["/workspace/project"],
          },
        },
        "thread-project-assignments": {
          thread: { projectId: "project" },
        },
        "projectless-thread-ids": [],
      }),
      "utf8",
    );

    const after = await readCodexDesktopProjectCatalog({ codexHome: home });
    expect(after.groupingFor("thread", "/private/worktree")).toMatchObject({
      projectGroupName: "After rename",
    });
  });

  it("fails closed instead of publishing malformed projects as projectless", async () => {
    const home = await codexHome({
      "local-projects": {
        broken: {
          id: "broken",
          name: "Broken",
          rootPaths: "/workspace/broken",
        },
      },
      "thread-project-assignments": {},
      "projectless-thread-ids": [],
    });

    const catalog = await readCodexDesktopProjectCatalog({ codexHome: home });

    expect(catalog.available).toBe(false);
    expect(catalog.groupingFor("thread", "/workspace/broken")).toBeUndefined();
  });

  it("rejects non-local assignments instead of mapping them to local projects", async () => {
    const home = await codexHome({
      "local-projects": {
        local: {
          id: "local",
          name: "Local",
          rootPaths: ["/workspace/local"],
        },
      },
      "thread-project-assignments": {
        thread: { projectKind: "remote", projectId: "local" },
      },
      "projectless-thread-ids": [],
    });

    const catalog = await readCodexDesktopProjectCatalog({ codexHome: home });

    expect(catalog.available).toBe(false);
  });

  it("retains the last good catalog while Desktop rewrites malformed state", async () => {
    const home = await codexHome({
      "local-projects": {
        project: {
          id: "project",
          name: "Stable project",
          rootPaths: ["/workspace/project"],
        },
      },
      "thread-project-assignments": {
        thread: { projectKind: "local", projectId: "project" },
      },
      "projectless-thread-ids": [],
    });
    const before = await readCodexDesktopProjectCatalog({ codexHome: home });
    expect(before.groupingFor("thread", "/private/worktree")).toMatchObject({
      projectGroupName: "Stable project",
    });

    await writeFile(
      join(home, ".codex-global-state.json"),
      JSON.stringify({
        "local-projects": { project: "rewrite-in-progress" },
        "thread-project-assignments": {},
        "projectless-thread-ids": [],
      }),
      "utf8",
    );

    const after = await readCodexDesktopProjectCatalog({ codexHome: home });
    expect(after.available).toBe(true);
    expect(after.groupingFor("thread", "/private/worktree")).toMatchObject({
      projectGroupName: "Stable project",
    });
  });

  it("fails open to legacy path grouping when Desktop state is unavailable", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-project-catalog-"));
    roots.add(root);

    const catalog = await readCodexDesktopProjectCatalog({ codexHome: root });

    expect(catalog.available).toBe(false);
    expect(catalog.groupingFor("thread-1", "/workspace/project")).toBeUndefined();
  });
});
