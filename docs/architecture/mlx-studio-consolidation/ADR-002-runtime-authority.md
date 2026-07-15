# ADR-002: vMLX is the sole inference runtime

- Status: Accepted
- Date: 2026-07-14

## Context

Production inference currently exists in vMLX, `JANGKit.Model`, the Python `jang_tools inference` command, and JANG Studio test-inference UI. Multiple paths make output, tracing, metrics, chat templates, and artifact compatibility disagree.

## Decision

Define `ModelInferenceProvider` against `MLXStudioDomain` generation and trace types. `vMLXEngine` supplies the production implementation. Chat, Evaluate, Expert Lab, validation smoke tests, benchmarks, blind comparison, and Serve use this provider. Python may build artifacts but is not an evaluation or serving authority.

## Consequences

- `JANGExpertLab` is refactored away from `JANGKit.Model` before its UI is migrated.
- Runtime identity, artifact hash, settings, hardware, and metrics accompany every recorded generation.
- `JANGKit.Model`, `JANG/JANGInference.swift`, JANG generators, and `InferenceRunner.swift` remain references until vMLX compatibility and trace parity pass; then they are retired from production.
- Chat remains in-process and does not require an HTTP listener.
