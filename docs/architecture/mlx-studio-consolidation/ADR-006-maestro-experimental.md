# ADR-006: MAESTRO is experimental

- Status: Accepted
- Date: 2026-07-14

## Context

No MAESTRO implementation exists at the pinned source revisions, and there is no supported-architecture or recovery-parity matrix.

## Decision

MAESTRO is displayed as **Global routing — Experimental**. It is never selected silently or used as the beginner default. The adapter must publish supported architectures, limitations, survivor constraints, recovery usage, one-shot retention, and post-recovery retention.

## Consequences

- Unsupported artifacts are rejected before analysis.
- Experimental results cannot outrank production strategies without the same evaluation evidence.
- Promotion to production maturity requires an explicit ADR update backed by architecture-matrix validation.
