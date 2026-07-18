import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

describe("file transfer module independence", () => {
  it("does not import the separately revertible artifact-preview feature", async () => {
    const sourceDirectory = join(process.cwd(), "src");
    const modules = (await readdir(sourceDirectory)).filter(
      (name) => /^file-transfer-.*\.ts$/.test(name) && !name.endsWith(".test.ts"),
    );
    for (const module of modules) {
      const source = await readFile(join(sourceDirectory, module), "utf8");
      expect(source, module).not.toMatch(/from\s+["']\.\/artifact-/);
    }
  });
});
