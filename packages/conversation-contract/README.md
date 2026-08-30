# Conversation contract generator

This private workspace contains only the deterministic tooling used to turn one
active conversation-contract registry into derived artifacts. It intentionally
does not contain the PVMC-1 registry, product vectors, or production output
paths.

The registry owns a deliberately small JSON type DSL:

- `object` with explicitly required or optional `fields`;
- string-valued `enum`;
- `union` with a string discriminator and object-shaped variants;
- named `ref`;
- `string`, `integer`, and `boolean` scalars;
- `array`;
- string-keyed `map`.

Only the profile named by `activeProfileId` is generated and hard-gated.
Definitions for later profiles may coexist as design inventory, but they cannot
leak into the active Schema, TypeScript, Dart, manifest, or digest. Active hard
rules must bind an owner, runtime consumer, executable test, stable failure
reason, and an all-zero side-effect shape. Active negative vectors must carry
that exact reason and zero shape. Every active rule must have at least one
positive and one negative vector.

## CLI

```text
node src/cli.mjs validate --registry <registry.json> --vectors <vectors.json>
node src/cli.mjs generate --format-dart --registry <registry.json> --vectors <vectors.json> --out <dir>
node src/cli.mjs check --format-dart --registry <registry.json> --vectors <vectors.json> --out <dir>
node src/cli.mjs generate --format-dart --registry <registry.json> --vectors <vectors.json> --target-map <map.json>
node src/cli.mjs check --format-dart --registry <registry.json> --vectors <vectors.json> --target-map <map.json>
```

`generate` writes deterministic `schema.json`, `contract.ts`, `contract.dart`,
and `profile-manifest.json`. The production path pins Dart `3.13.0` and formats
the Dart artifact before its digest is calculated. `check` repeats that process
and fails on byte drift or unexpected entries in an artifact directory.
Generation walks every standalone output component and rejects user-level
symlinks/non-directories. On macOS it recognizes only a root-owned `/name ->
/private/name` system alias (for example `/var -> /private/var`) before applying
the same component checks. Target maps canonicalize the configured project root,
then reject any symlink or realpath escape below it. An exclusive lock and
unpredictable stage are used; the target parents and the stage `new`/`backup`
directories are held open and their lexical path, realpath, device, and inode are
rechecked before and after every mutation. A failed pre-mutation recheck touches
no victim; post-mutation drift stops automatic recovery instead of guessing.
Node does not expose `renameat`/`linkat`, so this tooling does not claim to be a
security boundary against a malicious process running as the same account that
wins the interval between the last recheck and the filesystem syscall.

Rollback removes an installed file only after its device, inode, size, and
digest still match the transaction. A prior target, including a symlink, is
restored by renaming the exact backup object instead of creating a hard link.
Cleanup validates the complete stage inventory before removing the lock; a
failure before lock removal retains lock plus stage, while a later cleanup
failure can retain stage residue with the lock already absent. The reported
last-known recovery locations explicitly allow either residue to be absent;
callers must inspect them rather than assume that every residue survives.
`check` rejects non-regular targets, every unexpected artifact-directory entry,
and lock/stage residue at every ancestor on the mapped target paths. No
timestamp, host path, or random value enters an output. The CLI uses Dart from
`PATH`, or the project's `mise` Flutter `3.47.0` tool when Dart is not already
available.

The root `conversation:contract:*` scripts are the formal project gate. They
consume only `docs/design/codex-kernel-v4/contracts/contract-registry.json` and
`contracts/vectors/phone-core-vectors.json`, then use `project-targets.json` to
check the four reviewed docs/Bridge/Mobile derived targets. The package-local
`generate`, `validate`, and `check` scripts deliberately exercise only the
`test/fixtures` model. They are generator regression tests, not a formal
protocol, release, or product acceptance gate.
