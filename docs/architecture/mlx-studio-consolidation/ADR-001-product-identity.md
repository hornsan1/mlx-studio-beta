# ADR-001: MLX Studio is the sole product

- Status: Accepted
- Date: 2026-07-14

## Context

MLX Studio and JANG Studio currently expose overlapping model selection, inference, validation, and lifecycle concepts. Two product shells would perpetuate duplicate navigation, persistence, and support boundaries.

## Decision

The application is named **MLX Studio**, described as “The native model workstation for Apple Silicon.” vMLX is the runtime brand and JANG is the optimization/artifact brand inside MLX Studio. `hornsan1/mlx-studio-beta` is the canonical product repository. `hornsan1/jangq-private` is a migration source. `hornsan1/jang-studio-beta` remains a release/redirect host and is not an implementation source.

## Consequences

- New user-facing workflows land only in MLX Studio.
- JANG names remain visible for formats, strategies, reports, and technology attribution.
- JANG Studio is retired only after its required capabilities pass parity gates in MLX Studio.
- Redirect and migration guidance replace continued development of the old shell.
