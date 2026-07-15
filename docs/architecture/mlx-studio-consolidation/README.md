# MLX Studio consolidation: Phase 0

Status: complete architecture baseline

Canonical product repository: `hornsan1/mlx-studio-beta`

Inventory date: 2026-07-14

This directory is the decision and inventory baseline for consolidating MLX Studio and JANG Studio into one application named **MLX Studio**. Phase 0 changes documentation only. It does not add SwiftPM targets, move production code, alter a database, or change the installed application.

## Pinned source revisions

| Repository | Revision | Role |
| --- | --- | --- |
| `hornsan1/mlx-studio-beta` | `1d9efb000a2b87a53fad08273f91317fdcc31196` | Canonical product repository and technical chassis |
| `hornsan1/jangq-private` | `5d5487c27fa81d9f51da27264ae855964e334070` | Migration source for JANG conversion, optimization, Expert Lab, verification, and publishing |
| `hornsan1/jang-studio-beta` | `cfcc8f058065ec25371c45ad035eea2ca2399ab5` | Public beta-release host only; no canonical implementation |

All paths and conclusions in these documents refer to those revisions. A later implementation PR must refresh this baseline if any source revision changes.

## Architecture conclusions

1. MLX Studio is the only product shell. vMLX remains the runtime; JANG remains the optimization and artifact technology.
2. vMLX is the sole production inference authority. Chat, evaluation, tracing, validation, benchmarks, comparison, and serving must converge on one provider boundary.
3. `models.sqlite3` evolves into the canonical project, artifact, job, and evaluation store. Existing chat, settings, and image-history databases remain physically separate.
4. Python JANG tooling is first integrated as a structured, cancellable worker. Native migration follows parity evidence rather than replacing specialized converters wholesale.
5. Expert Lab's reusable prompt, Atlas, mask, and validation domain survives; its direct `JANGKit.Model` and screen-owned execution paths do not.
6. REAP exists as specialized Python implementations. Shared MAN, MSAN, and MAESTRO strategies do not exist at the pinned revisions.
7. Recommendations are candidate plans selected by measured evaluation. MAESTRO remains explicitly experimental.

## Deliverables

ADR numbers in this directory are local to the consolidation decision set. They do not renumber or supersede existing Markdown ADRs elsewhere in the repository.

- [Repository and capability inventory](repository-inventory.md)
- [Current and proposed dependency graphs](dependency-graph.md)
- [Duplicate-capability matrix](duplicate-capabilities.md)
- [File migration map](migration-map.csv)
- [Database migration proposal](database-migration.md)
- [Pull-request sequence](pr-sequence.md)
- [Risks and conditional retirement list](risks-and-retirement.md)
- [JANG Studio retirement record and migration guide](jang-studio-retirement.md)
- [ADR-001: MLX Studio is the sole product](ADR-001-product-identity.md)
- [ADR-002: vMLX is the sole inference runtime](ADR-002-runtime-authority.md)
- [ADR-003: One artifact domain](ADR-003-artifact-domain.md)
- [ADR-004: Structured optimization worker](ADR-004-optimization-worker.md)
- [ADR-005: Pruning algorithms are strategies](ADR-005-pruning-strategies.md)
- [ADR-006: MAESTRO is experimental](ADR-006-maestro-experimental.md)
- [ADR-007: Recommendations are evaluated](ADR-007-evaluated-recommendations.md)

## Glossary

| Term | Meaning |
| --- | --- |
| Artifact | An immutable, addressable model directory plus its manifest and lineage |
| Source | The imported local path or repository revision from which artifacts descend |
| Project | The lifecycle container joining a source, artifacts, plans, jobs, and evaluations |
| vMLX | The in-process MLX/Metal inference and API-serving runtime |
| JANG | Mixed-precision quantization and optimization technology |
| JANGTQ | JANG TurboQuant artifact/runtime format |
| Expert Atlas | Per-layer/per-expert routing and prompt evidence derived from traced runs |
| Candidate plan | A structurally valid pruning/quantization proposal awaiting evaluation |
| Measurement | A value produced by a completed build or runtime observation |
| Estimate | A pre-build prediction that must be labelled as such |

## Phase 0 exit gate

Phase 0 is complete when each required capability has an exact source, canonical owner, destination, migration phase, and retirement gate; all documented paths exist at the pinned revisions; and the accepted ADRs remove ambiguity about product identity, runtime authority, artifact ownership, worker boundaries, strategy maturity, and recommendation selection.

The implementation sequence is complete through the PR 20 retirement gate. The retirement record preserves the original Phase 0 pins while naming the coordinated source freeze, public redirect, package proof, migration steps, rollback path and intentional compatibility survivors.
