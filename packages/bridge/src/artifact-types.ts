export type ArtifactSource =
  "assistant_markdown" | "image_generation" | "structured_tool";

export type ArtifactKind = "source" | "preview";

export type ArtifactLinkKind = "link" | "image" | "generated";

/** Defense-in-depth bound for one assistant/tool-result message. */
export const MAX_ARTIFACTS_PER_MESSAGE = 64;

export interface ArtifactFileIdentity {
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
}

/**
 * A high-confidence local-file mention produced by a provider adapter or the
 * Markdown candidate extractor. It is Bridge-internal and may contain a local
 * path. Never serialize this object directly to a client.
 */
export interface ArtifactCandidate {
  source: ArtifactSource;
  linkKind: ArtifactLinkKind;
  /** Decoded local path, still relative to the session project when relative. */
  localPath: string;
  /** Original Markdown href, used only to match an existing rendered link. */
  originalHref?: string;
  label?: string;
  textContentIndex?: number;
}

/** Safe metadata returned to a CC Pocket client. */
export interface ArtifactRef {
  id: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  kind: ArtifactKind;
  source: ArtifactSource;
  /** Present only for project-local source files and never an absolute path. */
  projectRelativePath?: string;
  originalHref?: string;
  textContentIndex?: number;
  line?: number;
  column?: number;
}

/** Bridge-only descriptor persisted by ArtifactRegistry. */
export interface ArtifactRegistryEntry {
  artifactId: string;
  /** SHA-256 of the message-local candidate semantics, never a raw path/href. */
  candidateKey: string;
  /** Stable provider session/thread UUID, never the Bridge runtime short id. */
  ownerId: string;
  messageId: string;
  canonicalPath: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  identity: ArtifactFileIdentity;
  kind: ArtifactKind;
  source: ArtifactSource;
  line?: number;
  column?: number;
  createdAt: number;
  lastAccessAt: number;
  expiresAt: number;
}

export interface RegisterArtifactInput {
  candidateKey: string;
  ownerId: string;
  messageId: string;
  canonicalPath: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  identity: ArtifactFileIdentity;
  kind: ArtifactKind;
  source: ArtifactSource;
  line?: number;
  column?: number;
}

export interface ResolveArtifactInput {
  artifactId: string;
  ownerId: string;
  messageId: string;
  /** Canonicalized by ArtifactManager; ignored only for image_generation. */
  candidateRoots: string[];
  ttlSeconds?: number;
}

export interface ResolvedArtifact {
  artifactId: string;
  relativeUrl: string;
  expiresAt: string;
}
