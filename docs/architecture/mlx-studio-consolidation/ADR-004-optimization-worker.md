# ADR-004: JANG tooling begins as a structured worker

- Status: Accepted
- Date: 2026-07-14

## Context

JANG conversion and pruning include mature Python code plus architecture-specific entry points. Rewriting them before integration would discard coverage and delay a coherent product, while screen-owned subprocess code would reproduce JANG Studio's coupling.

## Decision

Integrate Python through an actor conforming to `OptimizationWorker`. Commands are constructed deterministically by a non-UI layer and communicate with versioned JSONL events. The worker supports cancellation with escalation, structured errors, bounded/redacted logs, manifests, diagnostic exports, tool-version capture, and explicit partial-output policy.

## Consequences

- Existing Python converters remain the initial artifact producers.
- JANG Studio's `PythonRunner`, `PythonCLIInvoker`, and argument builders are inputs to one consolidated worker, not copied into screens.
- Every specialized command must declare capabilities and event coverage before it can be exposed.
- Native Swift/MLX/Metal ports replace worker operations only after parity tests pass.
