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
node src/cli.mjs generate --registry <registry.json> --vectors <vectors.json> --out <dir>
node src/cli.mjs check --registry <registry.json> --vectors <vectors.json> --out <dir>
```

`generate` writes deterministic `schema.json`, `contract.ts`, `contract.dart`,
and `profile-manifest.json`. `check` regenerates into a temporary directory and
fails on byte drift. No timestamp, host path, or random value enters an output.

The root `conversation:contract:*` scripts currently exercise package-internal
fixtures only. The implementation owner must explicitly replace their inputs
and output paths when the reviewed PVMC-1 registry is added; the fixture is not
a protocol authority.
