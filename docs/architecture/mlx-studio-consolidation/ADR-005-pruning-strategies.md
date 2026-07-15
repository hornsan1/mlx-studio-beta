# ADR-005: Pruning algorithms are strategies

- Status: Accepted
- Date: 2026-07-14

## Context

Current Expert Lab logic combines prompt tracing, Atlas construction, mask editing, evaluation gates, and a ranking heuristic. REAP exists in model-specific Python modules. MAN, MSAN, and MAESTRO do not share an implementation boundary.

## Decision

MAN, MSAN, REAP, MAESTRO, and manual pruning conform to one `PruningStrategy` contract. Strategies analyze an artifact and calibration suite, then propose structurally valid candidate plans. Screen state edits a shared `OptimizationPlan`; it never owns an algorithm implementation.

## Consequences

- Raw strategy scores remain strategy-specific; percentiles are display/ranking aids only.
- Auto/Keep/Remove directives and survivor constraints are applied by a common validator.
- Existing Expert Atlas and reviewed-mask evidence become strategy inputs and plan evidence.
- Architecture-specific REAP code is adapted behind capability checks rather than presented as universal support.
