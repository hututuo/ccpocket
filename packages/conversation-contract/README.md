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
and fails on byte drift or unexpected regular files in an artifact directory.
Generation rejects symlink/non-directory outputs, uses an exclusive lock and
unpredictable transaction staging, and never follows a pre-existing artifact
symlink. Target maps canonicalize the real project root first, then reject any
symlink or realpath escape below that root. Rollback deletes an installed file
only after its device, inode, size, and digest still match the transaction; if
external replacement or cleanup failure makes recovery unsafe, the lock, stage,
and backup remain as explicit recovery evidence. `check` rejects non-regular
targets, every unexpected directory entry, and unfinished lock/stage residue.
No timestamp, host path, or random value enters an output. The CLI uses Dart
from `PATH`, or the project's `mise` Flutter `3.47.0` tool when Dart is not
already available.

The root `conversation:contract:*` scripts are the formal project gate. They
consume only `docs/design/codex-kernel-v4/contracts/contract-registry.json` and
`contracts/vectors/phone-core-vectors.json`, then use `project-targets.json` to
check the four reviewed docs/Bridge/Mobile derived targets. The package-local
`generate`, `validate`, and `check` scripts deliberately exercise only the
`test/fixtures` model. They are generator regression tests, not a formal
protocol, release, or product acceptance gate.
