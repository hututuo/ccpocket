import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const helperName = "file-browser-posix-helper";
const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const source = join(packageRoot, "src", `${helperName}.c`);
const output = join(packageRoot, "dist", helperName);

async function buildFileBrowserHelper() {
  if (process.platform !== "darwin" && process.platform !== "linux") {
    await rm(output, { force: true });
    console.warn(
      `[file-browser] Native helper is unsupported on ${process.platform}; the optional file browser will remain disabled`,
    );
    return;
  }

  const compiler = process.env.CC?.trim() || "cc";
  const probe = spawnSync(compiler, ["--version"], {
    encoding: "utf8",
    stdio: ["ignore", "ignore", "ignore"],
    timeout: 30_000,
  });
  if (probe.error?.code === "ENOENT") {
    await rm(output, { force: true });
    console.warn(
      "[file-browser] No C compiler is available; the optional file browser will remain disabled",
    );
    return;
  }
  if (probe.error || probe.status !== 0) {
    throw new Error("Unable to execute the configured C compiler");
  }

  await mkdir(dirname(output), { recursive: true });
  const temporary = `${output}.${process.pid}.${randomUUID()}.tmp`;
  const compiled = spawnSync(
    compiler,
    [
      "-std=c11",
      "-O2",
      "-Wall",
      "-Wextra",
      "-Werror",
      source,
      "-o",
      temporary,
    ],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 1024 * 1024,
      timeout: 30_000,
    },
  );
  if (compiled.status !== 0) {
    await rm(temporary, { force: true });
    throw new Error(
      `Unable to build the native file browser helper: ${
        compiled.stderr?.trim() || "compiler failed"
      }`,
    );
  }
  try {
    await chmod(temporary, 0o755);
    await rename(temporary, output);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
  console.log(`[file-browser] Built native helper for ${process.platform}`);
}

await buildFileBrowserHelper();
