import { request } from "node:http";
import type { PublishedArtifact } from "./artifact-store.js";
import { validateArtifactBaseUrl } from "./artifact-url.js";

export interface ShareArtifactRequest {
  filePath: string;
  projectPath: string;
  port: number;
  ttlSeconds?: number;
  baseUrl?: string;
}

interface PublishResponse {
  artifact?: PublishedArtifact;
  error?: string;
  errorCode?: string;
}

export function parseShareTtl(rawValue?: string): number | undefined {
  if (rawValue === undefined) return undefined;
  if (!/^\d+$/.test(rawValue)) {
    throw new Error("--ttl must be an integer number of seconds");
  }
  const value = Number(rawValue);
  if (!Number.isSafeInteger(value) || value < 60 || value > 86_400) {
    throw new Error("--ttl must be between 60 and 86400 seconds");
  }
  return value;
}

export async function publishArtifactViaBridge(
  input: ShareArtifactRequest,
): Promise<PublishedArtifact> {
  if (input.baseUrl && !validateArtifactBaseUrl(input.baseUrl)) {
    throw new Error(
      "--base-url must be a mobile-reachable http:// or https:// URL",
    );
  }

  const payload = Buffer.from(
    JSON.stringify({
      filePath: input.filePath,
      projectPath: input.projectPath,
      ttlSeconds: input.ttlSeconds,
      baseUrl: input.baseUrl,
    }),
  );

  return new Promise((resolve, reject) => {
    const req = request(
      {
        hostname: "127.0.0.1",
        port: input.port,
        path: "/api/artifacts",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": payload.length,
          "X-CCPocket-Control": "1",
        },
      },
      (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (chunk: string) => {
          if (body.length < 64 * 1024) body += chunk;
        });
        res.on("end", () => {
          let parsed: PublishResponse;
          try {
            parsed = JSON.parse(body) as PublishResponse;
          } catch {
            reject(new Error(`Bridge returned HTTP ${res.statusCode ?? 0}`));
            return;
          }

          if (res.statusCode !== 201 || !parsed.artifact) {
            reject(
              new Error(
                parsed.error ?? `Bridge returned HTTP ${res.statusCode ?? 0}`,
              ),
            );
            return;
          }
          resolve(parsed.artifact);
        });
      },
    );

    req.setTimeout(5_000, () => {
      req.destroy(new Error("Timed out connecting to the local Bridge"));
    });
    req.on("error", (error) => {
      const detail = error instanceof Error ? error.message : String(error);
      reject(
        new Error(
          `Unable to reach the local Bridge on 127.0.0.1:${input.port}: ${detail}`,
        ),
      );
    });
    req.end(payload);
  });
}
