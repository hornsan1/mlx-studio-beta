# ADR-003: One artifact domain

- Status: Accepted
- Date: 2026-07-14

## Context

The model library, chat sessions, server sessions, JANG conversion plans, Expert Lab review bundles, and filesystem scans identify the same weights differently. Paths alone cannot express lineage, revisions, verification, or duplicate content.

## Decision

`MLXStudioDomain` owns Foundation-only project, source, artifact, manifest, lineage, hardware, optimization, generation, and evaluation value types. One `ModelArtifactRepository` backed by the evolved `models.sqlite3` is authoritative for all model variants. Artifact IDs are stable UUID strings; local URLs are mutable locations, not identities.

## Consequences

- Chat and server records gain nullable artifact references while legacy paths remain during migration.
- Existing `models` rows are backfilled idempotently and retained until all readers use the repository.
- Content and manifest hashes detect duplicates; lineage records every artifact-producing operation.
- UI screens may present different selectors, but every selector resolves through the same repository.
