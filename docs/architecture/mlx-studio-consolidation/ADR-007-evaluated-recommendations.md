# ADR-007: Recommendations are selected by evaluation

- Status: Accepted
- Date: 2026-07-14

## Context

Routing frequency, activation magnitude, and pruning saliency are useful but incomplete proxies for capability retention. Averaging incomparable MAN, MSAN, REAP, and MAESTRO scores would imply unsupported precision.

## Decision

Strategies produce candidate plans. The recommendation service applies structural constraints, builds candidates when affordable, evaluates them on identical generation settings and relevant suites, and selects the measured trade-off that satisfies the user's objective. Unbuilt predictions remain labelled estimates.

## Consequences

- Candidate provenance, runtime versions, hardware, execution order, and generation settings are persisted.
- Baseline-invalid prompts are reported separately and cannot authorize pruning.
- Human preference and task validators remain first-class alongside perplexity and runtime metrics.
- The UI distinguishes estimated savings/risk from measured post-build results.
