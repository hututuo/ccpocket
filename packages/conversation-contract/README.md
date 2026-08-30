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
```

`generate` writes deterministic `schema.json`, `contract.ts`, `contract.dart`,
and `profile-manifest.json`. The production path pins Dart `3.13.0` and formats
the Dart artifact before its digest is calculated. `check` repeats that process
in a temporary directory and fails on byte drift. No timestamp, host path, or
random value enters an output. The CLI uses Dart from `PATH`, or the project's
`mise` Flutter `3.47.0` tool when Dart is not already available.

The root `conversation:contract:*` scripts currently exercise package-internal
fixtures only. The implementation owner must explicitly replace their inputs
and output paths when the reviewed PVMC-1 registry is added; the fixture is not
a protocol authority.
