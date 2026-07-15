# Pull-request sequence

Every PR is reviewable independently. A PR may begin only after its prerequisites and the preceding runtime/data safety gate pass.

| PR | Output | Prerequisite | Required tests/checks and exit gate |
| ---: | --- | --- | --- |
| 1 | Architecture records and complete inventory | Pinned source revisions | Documentation-only diff; path, graph, CSV coverage, link, and consistency checks pass |
| 2 | Add Foundation-only `MLXStudioDomain` value types/contracts | ADRs accepted | Serialization/equality/sendability tests; no SQLite/MLX/SwiftUI imports |
| 3 | Add artifact schema and transactional migration tests | Domain stable | Empty/v1/v2/interrupted/idempotent/rollback tests; no consumer switch |
| 4 | Add persistence repositories and durable jobs; migrate Models and Downloads state | Schema proven | Existing library/watcher behavior, deletion safety, JANG detection, job recovery, pause/resume/cancel, restart, and installed-model smoke pass |
| 5 | Add `ModelInferenceProvider` and vMLX adapter; migrate one generation path | Artifact repository available | Output/settings/cancel/metrics parity on a small real artifact; no server listener for Chat |
| 6 | Add evaluation suites/cases/manifests/results without full UI | Provider boundary usable | JSONL round trip, scorers, generation manifest, persistence/restart tests |
| 7 | Decouple JANG Expert Lab from `JANGKit.Model` | Trace-capable provider available | Existing Atlas/plan tests plus real BF16/vMLX trace and masked-compare parity |
| 8 | Add structured `PythonJANGWorker` | Durable jobs available | Golden JSONL, deterministic/redacted command, cancellation escalation, partial output, version and diagnostic tests |
| 9 | Add optimization plan, strategy protocol, constraints, directives, validator | Domain/worker stable | Structural mask, Auto/Keep/Remove, estimate-label, serialization tests |
| 10 | Implement MAN and MSAN production strategies | Strategy contract stable | Golden rankings, percentile display normalization, architecture fixtures, candidate validation |
| 11 | Add capability-gated REAP adapters | MAN/MSAN comparison available | Kimi/MiniMax/DSV4 supported fixtures; unsupported architectures fail before work starts |
| 12 | Add MAESTRO experimental adapter | Common evaluation runner available | Explicit label/support matrix; one-shot/recovery distinction; never default |
| 13 | Optimize workspace MVP: select, objective, plan, build, verify | Worker + plans + base strategies | Quantize-only, prune-only, analyze-only, cancel/fail/recover and installed-app flows |
| 14 | Expert controls and Atlas | Expert Lab decoupled | Auto/Keep/Remove, layer constraints, evidence, live estimates, invalid-mask blocking |
| 15 | Quick Compare | Evaluation persistence stable | Identical prompts/settings/templates, sequential fallback, reproducible manifests |
| 16 | Blind A/B | Quick Compare stable | Randomized balanced assignment, hidden identity, persisted judgment/reveal tests |
| 17 | Prompt-suite runner and domain scorecards | Suite primitives stable | Import/export, exact/regex/unit adapters, custom prompts, restart/resume |
| 18 | Loss Attribution | Four artifact variants representable | Missing variants, A/B/A-C/C-D/A-D attribution, quality/performance/human reports |
| 19 | Navigation and service consolidation | Feature parity matrix green | Home/Chat/Models/Optimize/Evaluate plus secondary navigation; no duplicate selector/runtime/job/comparison paths |
| 20 | JANG Studio retirement | All required JANG capabilities and migration docs shipped | Redirect release host, remove old shell from active development, final duplicate-runtime scan |

## Cross-PR release gates

- Any persistent-schema PR includes rollback fixtures before schema changes.
- Any inference/loader PR proves a real artifact through the installed app or live CLI, not compile success alone.
- Any artifact-producing PR writes a canonical manifest and lineage edge.
- Any runtime-affecting PR proves Chat remains serverless and Serve remains vMLX-backed.
- Any strategy PR identifies maturity and supported architectures; experimental methods are never implicit.
- Retirement PRs identify the preceding parity test that makes deletion safe.

## PR 2 handoff contract

After Phase 0 review, PR 2 adds only core domain types and protocol-neutral generation/evaluation/optimization request/result types. It must not add database code, workers, UI, concrete vMLX adapters, or migrate existing model consumers.
