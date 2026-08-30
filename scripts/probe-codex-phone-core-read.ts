import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";

import { CodexProcess } from "../packages/bridge/src/codex-process.js";

const execFileAsync = promisify(execFile);
const EXPECTED_CODEX_VERSION = "codex-cli 0.151.0";
const EXPECTED_CODEX_SHA256 =
  "98491713ffb196061003ee148636e743997cc31d76144ba7c53462269896891d";
const MAX_LIST_LIMIT = 20;

interface JsonRecord {
  readonly [key: string]: unknown;
}

function asRecord(value: unknown): JsonRecord | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined;
}

function sha256(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function stableShape(value: unknown, depth = 0): unknown {
  if (depth >= 4) return typeof value;
  if (Array.isArray(value)) {
    const shapes = value
      .slice(0, 8)
      .map((entry) => stableShape(entry, depth + 1));
    return { type: "array", sample: shapes };
  }
  const record = asRecord(value);
  if (record) {
    return Object.fromEntries(
      Object.keys(record)
        .sort()
        .map((key) => [key, stableShape(record[key], depth + 1)]),
    );
  }
  return value === null ? "null" : typeof value;
}

function summarizeThread(thread: JsonRecord): JsonRecord {
  const turns = Array.isArray(thread.turns) ? thread.turns : [];
  const turnIds = new Set<string>();
  const itemIds = new Set<string>();
  const itemKinds = new Map<string, number>();
  let invalidTurnIds = 0;
  let invalidItemIds = 0;
  let duplicateTurnIds = 0;
  let duplicateItemIds = 0;
  let itemCount = 0;

  for (const turnValue of turns) {
    const turn = asRecord(turnValue);
    const turnId = turn?.id;
    if (typeof turnId !== "string" || turnId.length === 0) {
      invalidTurnIds += 1;
    } else if (turnIds.has(turnId)) {
      duplicateTurnIds += 1;
    } else {
      turnIds.add(turnId);
    }
    const items = Array.isArray(turn?.items) ? turn.items : [];
    for (const itemValue of items) {
      itemCount += 1;
      const item = asRecord(itemValue);
      const itemId = item?.id;
      if (typeof itemId !== "string" || itemId.length === 0) {
        invalidItemIds += 1;
      } else if (itemIds.has(itemId)) {
        duplicateItemIds += 1;
      } else {
        itemIds.add(itemId);
      }
      const kind = typeof item?.type === "string" ? item.type : "<missing>";
      itemKinds.set(kind, (itemKinds.get(kind) ?? 0) + 1);
    }
  }

  const serialized = JSON.stringify(thread);
  return {
    threadIdDigest: sha256(String(thread.id ?? "")),
    byteCount: Buffer.byteLength(serialized),
    contentDigest: sha256(serialized),
    shapeDigest: sha256(JSON.stringify(stableShape(thread))),
    turnCount: turns.length,
    itemCount,
    invalidTurnIds,
    invalidItemIds,
    duplicateTurnIds,
    duplicateItemIds,
    itemKinds: Object.fromEntries(
      [...itemKinds].sort(([left], [right]) => left.localeCompare(right)),
    ),
  };
}

function summarizeItemPage(
  entries: ReadonlyArray<{ turnId: string; item: Record<string, unknown> }>,
): JsonRecord {
  const turnIds = new Set<string>();
  const itemIds = new Set<string>();
  const itemKinds = new Map<string, number>();
  let invalidItemIds = 0;
  let duplicateItemIds = 0;
  for (const entry of entries) {
    turnIds.add(entry.turnId);
    const itemId = entry.item.id;
    if (typeof itemId !== "string" || itemId.length === 0) {
      invalidItemIds += 1;
    } else if (itemIds.has(itemId)) {
      duplicateItemIds += 1;
    } else {
      itemIds.add(itemId);
    }
    const kind =
      typeof entry.item.type === "string" ? entry.item.type : "<missing>";
    itemKinds.set(kind, (itemKinds.get(kind) ?? 0) + 1);
  }
  const serialized = JSON.stringify(entries);
  return {
    byteCount: Buffer.byteLength(serialized),
    contentDigest: sha256(serialized),
    shapeDigest: sha256(JSON.stringify(stableShape(entries))),
    turnCount: turnIds.size,
    itemCount: entries.length,
    invalidItemIds,
    duplicateItemIds,
    itemKinds: Object.fromEntries(
      [...itemKinds].sort(([left], [right]) => left.localeCompare(right)),
    ),
  };
}

function summarizeTimelinePage(entries: ReadonlyArray<JsonRecord>): JsonRecord {
  const positions = new Set<number>();
  const kinds = new Map<string, number>();
  let invalidPositions = 0;
  let duplicatePositions = 0;
  for (const entry of entries) {
    const position = entry.position;
    if (!Number.isSafeInteger(position) || Number(position) < 0) {
      invalidPositions += 1;
    } else if (positions.has(Number(position))) {
      duplicatePositions += 1;
    } else {
      positions.add(Number(position));
    }
    const kind = typeof entry.type === "string" ? entry.type : "<missing>";
    kinds.set(kind, (kinds.get(kind) ?? 0) + 1);
  }
  const serialized = JSON.stringify(entries);
  const sortedPositions = [...positions].sort((left, right) => left - right);
  return {
    byteCount: Buffer.byteLength(serialized),
    contentDigest: sha256(serialized),
    shapeDigest: sha256(JSON.stringify(stableShape(entries))),
    entryCount: entries.length,
    invalidPositions,
    duplicatePositions,
    firstPosition: sortedPositions[0],
    lastPosition: sortedPositions.at(-1),
    kinds: Object.fromEntries(
      [...kinds].sort(([left], [right]) => left.localeCompare(right)),
    ),
  };
}

async function resolveExactCodex(): Promise<JsonRecord> {
  const { stdout: whichOutput } = await execFileAsync("/usr/bin/which", [
    "codex",
  ]);
  const executable = whichOutput.trim();
  const bytes = await readFile(executable);
  const digest = sha256(bytes);
  const { stdout, stderr } = await execFileAsync(executable, ["--version"]);
  const version = `${stdout}${stderr}`.trim();
  if (version !== EXPECTED_CODEX_VERSION || digest !== EXPECTED_CODEX_SHA256) {
    throw new Error(
      `unexpected Codex build: version=${JSON.stringify(version)} sha256=${digest}`,
    );
  }
  return { version, sha256: digest };
}

async function main(): Promise<void> {
  const build = await resolveExactCodex();
  const requestedThreadId = process.argv[2];
  const projectPath = process.cwd();
  const codex = new CodexProcess();
  try {
    await codex.initializeOnly(projectPath);
    const listed = await codex.listThreads({ limit: MAX_LIST_LIMIT });
    const threadId = requestedThreadId ?? listed.data[0]?.id;
    if (!threadId) {
      process.stdout.write(
        `${JSON.stringify({ build, listed: 0, result: "NO_THREAD" }, null, 2)}\n`,
      );
      return;
    }
    const firstTurns = await codex.listThreadTurns({
      threadId,
      limit: 20,
      cursor: null,
      sortDirection: "desc",
      itemsView: "notLoaded",
    });
    const firstFullTurns = await codex.listThreadTurns({
      threadId,
      limit: 2,
      cursor: null,
      sortDirection: "desc",
      itemsView: "full",
    });
    const repeatedFullTurns = await codex.listThreadTurns({
      threadId,
      limit: 2,
      cursor: null,
      sortDirection: "desc",
      itemsView: "full",
    });
    const olderFullTurns = firstFullTurns.nextCursor
      ? await codex.listThreadTurns({
          threadId,
          limit: 2,
          cursor: firstFullTurns.nextCursor,
          sortDirection: "desc",
          itemsView: "full",
        })
      : null;
    let itemApi: JsonRecord;
    try {
      const items = await codex.listThreadItems({
        threadId,
        limit: 1,
        cursor: null,
        sortDirection: "desc",
      });
      itemApi = {
        supported: true,
        summary: summarizeItemPage(items.data),
      };
    } catch (error) {
      itemApi = {
        supported: false,
        error:
          error instanceof Error
            ? error.message.replace(/[\r\n]+/g, " ").slice(0, 200)
            : "unknown error",
      };
    }
    let timelineApi: JsonRecord;
    try {
      const firstTimeline = await codex.listThreadTimeline({
        threadId,
        limit: 200,
        cursor: null,
      });
      const repeatedTimeline = await codex.listThreadTimeline({
        threadId,
        limit: 200,
        cursor: null,
      });
      const nextTimeline = firstTimeline.nextCursor
        ? await codex.listThreadTimeline({
            threadId,
            limit: 200,
            cursor: firstTimeline.nextCursor,
          })
        : null;
      const firstTimelineSummary = summarizeTimelinePage(firstTimeline.data);
      const repeatedTimelineSummary = summarizeTimelinePage(
        repeatedTimeline.data,
      );
      timelineApi = {
        supported: true,
        first: {
          ...firstTimelineSummary,
          nextCursorPresent: firstTimeline.nextCursor !== null,
        },
        repeated: repeatedTimelineSummary,
        next: nextTimeline ? summarizeTimelinePage(nextTimeline.data) : null,
        repeatedReadStable:
          firstTimelineSummary.contentDigest ===
            repeatedTimelineSummary.contentDigest &&
          firstTimelineSummary.shapeDigest ===
            repeatedTimelineSummary.shapeDigest,
      };
    } catch (error) {
      timelineApi = {
        supported: false,
        error:
          error instanceof Error
            ? error.message.replace(/[\r\n]+/g, " ").slice(0, 200)
            : "unknown error",
      };
    }
    const turnSummary = summarizeThread({
      id: threadId,
      turns: firstTurns.data,
    });
    const firstSummary = summarizeThread({
      id: threadId,
      turns: firstFullTurns.data,
    });
    const secondSummary = summarizeThread({
      id: threadId,
      turns: repeatedFullTurns.data,
    });
    process.stdout.write(
      `${JSON.stringify(
        {
          build,
          listed: listed.data.length,
          nextCursorPresent: listed.nextCursor !== null,
          explicitThread: requestedThreadId !== undefined,
          boundedRequests: olderFullTurns ? 5 : 4,
          turns: {
            ...turnSummary,
            nextCursorPresent: firstTurns.nextCursor !== null,
            backwardsCursorPresent: firstTurns.backwardsCursor !== null,
          },
          newestFullTurns: {
            ...firstSummary,
            nextCursorPresent: firstFullTurns.nextCursor !== null,
            backwardsCursorPresent: firstFullTurns.backwardsCursor !== null,
          },
          repeatedNewestFullTurns: secondSummary,
          olderFullTurns: olderFullTurns
            ? summarizeThread({ id: threadId, turns: olderFullTurns.data })
            : null,
          itemApi,
          timelineApi,
          repeatedReadStable:
            firstSummary.contentDigest === secondSummary.contentDigest &&
            firstSummary.shapeDigest === secondSummary.shapeDigest,
        },
        null,
        2,
      )}\n`,
    );
  } finally {
    codex.stop();
  }
}

void main().catch((error) => {
  process.stderr.write(
    `codex-phone-core-read-probe: ${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exitCode = 1;
});
