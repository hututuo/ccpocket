import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  createPathArtifactCandidate,
  extractArtifactCandidates,
} from "./artifact-candidates.js";
import {
  artifactCandidateKey,
  ArtifactManager,
  ArtifactResolveError,
  splitArtifactLocationSuffix,
} from "./artifact-manager.js";
import { ArtifactRegistry } from "./artifact-registry.js";
import { ArtifactStore } from "./artifact-store.js";
import { GeneratedArtifactStore } from "./generated-artifact-store.js";

const roots: string[] = [];
const stores: ArtifactStore[] = [];

afterEach(async () => {
  for (const store of stores.splice(0)) store.close();
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

async function tempRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-manager-test-"));
  roots.push(root);
  return root;
}

function storeFor(allowedDirs: string[]): ArtifactStore {
  const store = new ArtifactStore({ allowedDirs, cleanupIntervalMs: 0 });
  stores.push(store);
  return store;
}

describe("splitArtifactLocationSuffix", () => {
  it.each([
    ["/tmp/file.ts:12", { filePath: "/tmp/file.ts", line: 12 }],
    ["/tmp/file.ts:12:3", { filePath: "/tmp/file.ts", line: 12, column: 3 }],
    [
      "C:\\work\\file.ts:9:2",
      { filePath: "C:\\work\\file.ts", line: 9, column: 2 },
    ],
  ])("parses %s", (input, expected) => {
    expect(splitArtifactLocationSuffix(input)).toEqual(expected);
  });

  it.each([
    "/tmp/file.ts",
    "/tmp/file.ts:0",
    "/tmp/file.ts:12:0",
    "C:\\work\\file.ts",
  ])("does not misparse %s", (input) =>
    expect(splitArtifactLocationSuffix(input)).toBeUndefined(),
  );
});

describe("ArtifactManager", () => {
  it("classifies project source locations separately from previews", async () => {
    const root = await tempRoot();
    const project = join(root, "worktree");
    const outside = join(root, "exports");
    await mkdir(join(project, "src"), { recursive: true });
    await mkdir(join(project, "reports"), { recursive: true });
    await mkdir(join(project, "images"), { recursive: true });
    await mkdir(outside, { recursive: true });
    await writeFile(join(project, "src", "main.ts"), "export {};\n");
    await writeFile(join(project, "reports", "报告 final.pdf"), "pdf");
    await writeFile(join(project, "images", "图.png"), "png");
    await writeFile(join(outside, "export.zip"), "zip");

    const registry = new ArtifactRegistry({
      filePath: join(root, "registry.json"),
    });
    const manager = new ArtifactManager({
      store: storeFor([project, outside]),
      registry,
    });
    const candidates = extractArtifactCandidates(
      [
        "[source](<src/main.ts:12:3>)",
        "[report](<reports/%E6%8A%A5%E5%91%8A%20final.pdf>)",
        "![image](<images/%E5%9B%BE.png>)",
        `[outside](<${join(outside, "export.zip")}>)`,
      ].join("\n"),
      { textContentIndex: 4 },
    );

    const refs = await manager.registerCandidates({
      ownerId: "thread-uuid",
      messageId: "message-uuid",
      cwd: project,
      candidateRoots: [outside],
      candidates,
    });

    expect(refs).toHaveLength(4);
    expect(refs[0]).toMatchObject({
      kind: "source",
      projectRelativePath: "src/main.ts",
      line: 12,
      column: 3,
      originalHref: "src/main.ts:12:3",
      textContentIndex: 4,
    });
    expect(refs[1]).toMatchObject({
      kind: "preview",
      filename: "报告 final.pdf",
    });
    expect(refs[1]).not.toHaveProperty("projectRelativePath");
    expect(refs[2]).toMatchObject({ kind: "preview", filename: "图.png" });
    expect(refs[3]).toMatchObject({ kind: "preview", filename: "export.zip" });
    expect(refs[3]).not.toHaveProperty("projectRelativePath");
  });

  it("routes project .html and .json through the preview chain", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    await mkdir(project);
    await writeFile(join(project, "report.html"), "<h1>report</h1>");
    await writeFile(join(project, "legacy.htm"), "<h1>legacy</h1>");
    await writeFile(join(project, "data.json"), '{"a":1}');
    await writeFile(join(project, "main.ts"), "export {};\n");
    const manager = new ArtifactManager({
      store: storeFor([project]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const candidates = extractArtifactCandidates(
      [
        "[report](report.html)",
        "[legacy](legacy.htm)",
        "[data](data.json)",
        "[source](main.ts)",
      ].join("\n"),
    );

    const refs = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "preview-routing",
      cwd: project,
      candidates,
    });

    // HTML renders in the sandboxed iframe and JSON pretty-prints on the
    // preview page; kind:"source" would strand both in the File Peek text
    // sheet with the whole preview route unreachable.
    expect(refs.slice(0, 3)).toEqual([
      expect.objectContaining({ kind: "preview", filename: "report.html" }),
      expect.objectContaining({ kind: "preview", filename: "legacy.htm" }),
      expect.objectContaining({ kind: "preview", filename: "data.json" }),
    ]);
    expect(refs[3]).toMatchObject({
      kind: "source",
      projectRelativePath: "main.ts",
    });
  });

  it("tries a complete colon filename before interpreting line metadata", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    await mkdir(project);
    await writeFile(join(project, "notes:12"), "literal filename");
    await writeFile(join(project, "source.ts"), "source");
    const manager = new ArtifactManager({
      store: storeFor([project]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const candidates = extractArtifactCandidates(
      "[literal](<notes:12>)\n[source](<source.ts:12>)",
    );

    const refs = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "message",
      cwd: project,
      candidates,
    });

    expect(refs[0]).not.toHaveProperty("line");
    expect(refs[0].filename).toBe("notes:12");
    expect(refs[1]).toMatchObject({ line: 12, filename: "source.ts" });
  });

  it("does not promote binary line locations to source refs", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    await mkdir(project);
    for (const filename of [
      "paper.pdf",
      "archive.bin",
      "paper.tex",
      "analysis.R",
      "build.gradle",
      "gradle.properties",
      "Dockerfile",
    ]) {
      await writeFile(join(project, filename), filename);
    }
    const manager = new ArtifactManager({
      store: storeFor([project]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const candidates = extractArtifactCandidates(
      [
        "[pdf](paper.pdf:12)",
        "[binary](archive.bin:3:2)",
        "[tex](paper.tex:4)",
        "[r](analysis.R:5)",
        "[gradle](build.gradle:6)",
        "[properties](gradle.properties:7)",
        "[docker](Dockerfile:8)",
      ].join("\n"),
    );

    const refs = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "source-kinds",
      cwd: project,
      candidates,
    });

    expect(refs.slice(0, 2)).toEqual([
      expect.objectContaining({
        kind: "preview",
        filename: "paper.pdf",
        line: 12,
      }),
      expect.objectContaining({
        kind: "preview",
        filename: "archive.bin",
        line: 3,
        column: 2,
      }),
    ]);
    for (const ref of refs.slice(2)) {
      expect(ref.kind).toBe("source");
      expect(ref.projectRelativePath).toBe(ref.filename);
    }
  });

  it("opens source refs by registry identity and keeps the verified inode", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    const outside = join(root, "outside");
    await mkdir(join(project, "src"), { recursive: true });
    await mkdir(outside);
    const sourcePath = join(project, "src", "main.ts");
    const movedPath = join(project, "src", "main-moved.ts");
    const secretPath = join(outside, "secret.ts");
    await writeFile(sourcePath, "registered source");
    await writeFile(secretPath, "outside replacement");
    const manager = new ArtifactManager({
      store: storeFor([root]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const [ref] = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "source-message",
      cwd: project,
      candidates: extractArtifactCandidates("[source](src/main.ts:2:1)"),
    });

    const opened = await manager.openAuthorizedSource({
      artifactId: ref.id,
      ownerId: "thread",
      messageId: "source-message",
      candidateRoots: [project],
      cwd: project,
      projectRelativePath: "src/main.ts",
    });
    try {
      expect(opened).toMatchObject({
        filename: "main.ts",
        mimeType: expect.stringContaining("typescript"),
        line: 2,
        column: 1,
      });
      await rename(sourcePath, movedPath);
      await symlink(secretPath, sourcePath);
      await expect(opened.handle.readFile("utf8")).resolves.toBe(
        "registered source",
      );
    } finally {
      await opened.handle.close();
    }
    await expect(
      manager.openAuthorizedSource({
        artifactId: ref.id,
        ownerId: "thread",
        messageId: "source-message",
        candidateRoots: [project],
        cwd: project,
        projectRelativePath: "src/main.ts",
      }),
    ).rejects.toMatchObject({ code: "file_changed", statusCode: 409 });
  });

  it("rejects changed source identity and mismatched relative paths", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    await mkdir(project);
    const sourcePath = join(project, "main.ts");
    await writeFile(sourcePath, "before");
    const manager = new ArtifactManager({
      store: storeFor([project]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const [ref] = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "source-message",
      cwd: project,
      candidates: extractArtifactCandidates("[source](main.ts)"),
    });
    const sourceInput = {
      artifactId: ref.id,
      ownerId: "thread",
      messageId: "source-message",
      candidateRoots: [project],
      cwd: project,
    };

    await expect(
      manager.openAuthorizedSource({
        ...sourceInput,
        projectRelativePath: "other.ts",
      }),
    ).rejects.toMatchObject({
      code: "source_path_mismatch",
      statusCode: 409,
    });

    await writeFile(sourcePath, "after with different identity");
    await expect(
      manager.openAuthorizedSource({
        ...sourceInput,
        projectRelativePath: "main.ts",
      }),
    ).rejects.toMatchObject({ code: "file_changed", statusCode: 409 });
  });

  it("ignores missing files, directories, and symlinks escaping allowed roots", async () => {
    const allowed = await tempRoot();
    const outside = await tempRoot();
    await mkdir(join(allowed, "directory"));
    await writeFile(join(outside, "secret.txt"), "secret");
    await symlink(join(outside, "secret.txt"), join(allowed, "escape.txt"));
    const manager = new ArtifactManager({
      store: storeFor([allowed]),
      registry: new ArtifactRegistry({
        filePath: join(allowed, "registry.json"),
      }),
    });
    const candidates = extractArtifactCandidates(
      "[missing](missing.txt)\n[dir](directory)\n[escape](escape.txt)",
    );

    await expect(
      manager.registerCandidates({
        ownerId: "thread",
        messageId: "message",
        cwd: allowed,
        candidates,
      }),
    ).resolves.toEqual([]);
  });

  it("deduplicates concurrent replay and resolves after registry restart", async () => {
    const root = await tempRoot();
    const filePath = join(root, "报告.pdf");
    const registryPath = join(root, "registry.json");
    await writeFile(filePath, "report");
    const manager = new ArtifactManager({
      store: storeFor([root]),
      registry: new ArtifactRegistry({ filePath: registryPath }),
    });
    const candidate = createPathArtifactCandidate(filePath, {
      source: "structured_tool",
    });
    const input = {
      ownerId: "provider-thread",
      messageId: "message",
      cwd: root,
      candidates: [candidate],
    };

    const [[first], [second]] = await Promise.all([
      manager.registerCandidates(input),
      manager.registerCandidates(input),
    ]);
    expect(second.id).toBe(first.id);

    const restartedStore = storeFor([root]);
    const restarted = new ArtifactManager({
      store: restartedStore,
      registry: new ArtifactRegistry({ filePath: registryPath }),
    });
    const resolved = await restarted.resolve({
      artifactId: first.id,
      ownerId: "provider-thread",
      messageId: "message",
      candidateRoots: [root],
    });
    expect(resolved.relativeUrl).toMatch(/^\/artifacts\/[A-Za-z0-9_-]{43}$/);
    expect(
      restartedStore.getEntry(resolved.relativeUrl.split("/").at(-1)!),
    ).toBeDefined();
  });

  it("keeps the old descriptor after a file changes and rejects resolution", async () => {
    const root = await tempRoot();
    const filePath = join(root, "result.pdf");
    await writeFile(filePath, "before");
    const manager = new ArtifactManager({
      store: storeFor([root]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const candidate = createPathArtifactCandidate(filePath, {
      source: "structured_tool",
    });
    const registration = {
      ownerId: "thread",
      messageId: "message",
      cwd: root,
      candidates: [candidate],
    };
    const [first] = await manager.registerCandidates(registration);
    await writeFile(filePath, "after with a different size");
    const [replayed] = await manager.registerCandidates(registration);
    expect(replayed.id).toBe(first.id);
    expect(replayed.sizeBytes).toBe(first.sizeBytes);

    await expect(
      manager.resolve({
        artifactId: first.id,
        ownerId: "thread",
        messageId: "message",
        candidateRoots: [root],
      }),
    ).rejects.toMatchObject({ code: "file_changed", statusCode: 409 });
  });

  it("returns the same not-found error for unknown, owner, and message mismatches", async () => {
    const root = await tempRoot();
    const filePath = join(root, "result.pdf");
    await writeFile(filePath, "result");
    const manager = new ArtifactManager({
      store: storeFor([root]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const [ref] = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "message",
      cwd: root,
      candidates: extractArtifactCandidates(`[file](<${filePath}>)`),
    });

    for (const input of [
      { artifactId: "Z".repeat(24), ownerId: "thread", messageId: "message" },
      { artifactId: ref.id, ownerId: "wrong", messageId: "message" },
      { artifactId: ref.id, ownerId: "thread", messageId: "wrong" },
    ]) {
      await expect(
        manager.resolve({ ...input, candidateRoots: [root] }),
      ).rejects.toEqual(
        expect.objectContaining<Partial<ArtifactResolveError>>({
          code: "artifact_not_found",
          statusCode: 404,
        }),
      );
    }
  });

  it("limits non-image candidates to canonical session roots", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    const projectPrefixSibling = join(root, "project-private");
    const external = join(root, "external");
    await mkdir(project);
    await mkdir(projectPrefixSibling);
    await mkdir(external);
    await writeFile(join(projectPrefixSibling, "secret.txt"), "secret");
    await writeFile(join(external, "report.pdf"), "report");
    await writeFile(join(external, "generated.png"), "image");
    await symlink(external, join(root, "external-link"));
    await symlink(
      join(projectPrefixSibling, "secret.txt"),
      join(project, "escape.txt"),
    );

    const manager = new ArtifactManager({
      store: storeFor([root]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
      generatedArtifactStore: new GeneratedArtifactStore({
        directory: join(root, "controlled"),
        trustedSourceRoots: [external],
      }),
    });
    const markdownCandidates = extractArtifactCandidates(
      [
        `[sibling](<${join(projectPrefixSibling, "secret.txt")}>)`,
        "[escape](escape.txt)",
        `[external](<${join(external, "report.pdf")}>)`,
      ].join("\n"),
    );
    const imageCandidate = createPathArtifactCandidate(
      join(external, "generated.png"),
      { source: "image_generation" },
    );

    const defaultRefs = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "message-default",
      cwd: project,
      candidateRoots: [join(root, "missing-root")],
      candidates: [...markdownCandidates, imageCandidate],
    });
    expect(defaultRefs).toHaveLength(1);
    expect(defaultRefs[0]).toMatchObject({ source: "image_generation" });

    const explicitlyScoped = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "message-explicit",
      cwd: project,
      candidateRoots: [join(root, "external-link")],
      candidates: [markdownCandidates[2]],
    });
    expect(explicitlyScoped).toHaveLength(1);
    expect(explicitlyScoped[0].filename).toBe("report.pdf");
  });

  it("copies structured images before inspection when user roots exclude home", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    const userAllowed = join(root, "user-allowed");
    const codexTemp = join(root, "codex-temp", "generated_images");
    const controlled = join(root, "private-artifacts");
    await mkdir(project);
    await mkdir(userAllowed);
    await mkdir(codexTemp, { recursive: true });
    const source = join(codexTemp, "生成 result.png");
    await writeFile(source, "generated content");
    const registry = new ArtifactRegistry({
      filePath: join(root, "registry.json"),
    });
    const manager = new ArtifactManager({
      // Simulates BRIDGE_ALLOWED_DIRS explicitly excluding both $HOME and the
      // Codex temp root. Only the private managed directory is added.
      store: storeFor([userAllowed, controlled]),
      registry,
      generatedArtifactStore: new GeneratedArtifactStore({
        directory: controlled,
        trustedSourceRoots: [codexTemp],
      }),
    });
    const candidate = createPathArtifactCandidate(source, {
      source: "image_generation",
    });

    const [materialized] = await manager.materializeGeneratedCandidates({
      ownerId: "provider-thread",
      messageId: "generated-message",
      cwd: project,
      candidates: [candidate],
    });
    expect(materialized).not.toBe(source);
    await expect(readFile(materialized, "utf8")).resolves.toBe(
      "generated content",
    );

    const [ref] = await manager.registerCandidates({
      ownerId: "provider-thread",
      messageId: "generated-message",
      cwd: project,
      candidates: [candidate],
    });
    expect(ref).toMatchObject({
      filename: "生成 result.png",
      kind: "preview",
      source: "image_generation",
    });
    const descriptor = await registry.getCandidate(
      "provider-thread",
      "generated-message",
      artifactCandidateKey(candidate),
    );
    expect(descriptor?.canonicalPath).not.toBe(source);
    expect(
      descriptor?.canonicalPath.startsWith(await realpath(controlled)),
    ).toBe(true);
    expect(descriptor?.canonicalPath).toBe(await realpath(materialized));
    await expect(readFile(descriptor!.canonicalPath, "utf8")).resolves.toBe(
      "generated content",
    );

    await rm(source);
    const [replayed] = await manager.registerCandidates({
      ownerId: "provider-thread",
      messageId: "generated-message",
      cwd: project,
      candidates: [candidate],
    });
    expect(replayed.id).toBe(ref.id);
    await expect(
      manager.resolve({
        artifactId: ref.id,
        ownerId: "provider-thread",
        messageId: "generated-message",
        candidateRoots: [project],
      }),
    ).resolves.toMatchObject({ artifactId: ref.id });
  });

  it("rechecks current session roots for replay and resolution", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    const external = join(root, "external");
    await mkdir(project);
    await mkdir(external);
    const filePath = join(external, "report.pdf");
    await writeFile(filePath, "report");
    const manager = new ArtifactManager({
      store: storeFor([root]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });
    const registration = {
      ownerId: "thread",
      messageId: "message",
      cwd: project,
      candidateRoots: [external],
      candidates: extractArtifactCandidates(`[report](<${filePath}>)`),
    };
    const [ref] = await manager.registerCandidates(registration);
    expect(ref).toBeDefined();

    await expect(
      manager.registerCandidates({
        ...registration,
        candidateRoots: [project],
      }),
    ).resolves.toEqual([]);
    await expect(
      manager.resolve({
        artifactId: ref.id,
        ownerId: "thread",
        messageId: "message",
        candidateRoots: [project],
      }),
    ).rejects.toMatchObject({ code: "path_not_allowed", statusCode: 403 });
    await expect(
      manager.resolve({
        artifactId: ref.id,
        ownerId: "thread",
        messageId: "message",
        candidateRoots: [external],
      }),
    ).resolves.toMatchObject({ artifactId: ref.id });
  });

  it("allows exact out-of-project previews only in authenticated owner-read mode", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    const external = join(root, "external");
    await mkdir(project);
    await mkdir(external);
    const filePath = join(external, "report.pdf");
    await writeFile(filePath, "report");
    const manager = new ArtifactManager({
      store: storeFor([]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
      allowUnscopedRead: true,
    });

    const [ref] = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "message",
      cwd: project,
      candidateRoots: [project],
      candidates: extractArtifactCandidates(`[report](<${filePath}>)`),
    });

    expect(ref).toMatchObject({
      filename: "report.pdf",
      kind: "preview",
    });
    await expect(
      manager.resolve({
        artifactId: ref.id,
        ownerId: "thread",
        messageId: "message",
        candidateRoots: [project],
      }),
    ).resolves.toMatchObject({ artifactId: ref.id });

    await writeFile(filePath, "changed");
    await expect(
      manager.resolve({
        artifactId: ref.id,
        ownerId: "thread",
        messageId: "message",
        candidateRoots: [],
      }),
    ).rejects.toMatchObject({ code: "file_changed" });
  });

  it("caps structured candidates before inspection and batch registration", async () => {
    const root = await tempRoot();
    const project = join(root, "project");
    await mkdir(project);
    const paths = Array.from({ length: 70 }, (_, index) =>
      join(project, `file-${index}.txt`),
    );
    await Promise.all(paths.map((path) => writeFile(path, path)));
    const manager = new ArtifactManager({
      store: storeFor([project]),
      registry: new ArtifactRegistry({ filePath: join(root, "registry.json") }),
    });

    const refs = await manager.registerCandidates({
      ownerId: "thread",
      messageId: "message-many",
      cwd: project,
      candidates: paths.map((path) =>
        createPathArtifactCandidate(path, { source: "structured_tool" }),
      ),
    });
    expect(refs).toHaveLength(64);
    expect(refs.at(-1)?.filename).toBe("file-63.txt");
  });
});
