# Duplicate-capability matrix

“Retire” below always means after the named replacement and parity gate; Phase 0 deletes nothing.

| Capability | Competing implementations | Canonical owner | Disposition and gate |
| --- | --- | --- | --- |
| Model inference | vMLX `Engine`; Swift `JANGKit.Model`/`JANGInference`; Python `jang_tools inference`; JANG Studio `InferenceRunner` | `vMLXEngine` implementing `ModelInferenceProvider` | Adapt all consumers; retire other production paths after JANG/JANGTQ load, output, trace, cancel, and metrics parity |
| Model identity/library | `ModelLibrary`; app `ModelRef`/`ModelSummary`; paths in chat/server; JANG `ConversionPlan` and review folders | `ModelArtifactRepository` | Evolve library; retain path compatibility until chat/server migration and restart tests pass |
| Model selectors | Chat picker, Server picker, Studio Models/Library, JANG Source step | Artifact repository queries | Preserve UX-specific presentation; remove independent discovery/identity logic after all selectors resolve artifact IDs |
| Downloads/install | `DownloadManager`; `StudioModelInstallCoordinator`; JANG/HF publishing/download helpers | Download engine adapted to `MLXStudioJobs` | Keep transfer code; unify durable job/event model after pause/resume/cancel verification |
| Chat | `ChatScreen`/`ChatViewModel`/SQLite; `StudioChatScreen`/UserDefaults | `ChatScreen` and `vmlx.sqlite3` | Port missing UI parity, finish migration, then retire Studio chat types/store |
| Server | `vMLXServer`; app server actors; Python architecture servers | `vMLXServer` | Keep API routes; Python servers remain diagnostic references only after optimized artifacts serve through vMLX |
| Jobs | `DownloadManager.Job`; `ModelJob`/`StudioJobService`; `ProgressEvent`/Python runner | `MLXStudioJobs` | Adapt engines into one state machine; retire duplicate facades after recovery/cancel persistence tests |
| Metrics | `MetricsCollector`; server metrics; benchmark/test-inference local timing/RSS fields | `RuntimeMetricsProvider` backed by `MetricsCollector` | Map all measurements to one session manifest; remove local collectors after metric equivalence tests |
| Logs/diagnostics | `LogStore`/`DebugBundle`; Studio diagnostic issue store; JANG diagnostics bundles/process tails | `LogStore`, job logs, unified diagnostic export | Adapt/redact sources; retire duplicate stores after export coverage and secret/path redaction tests |
| Evaluation | MLX `Evaluate.swift`; server benchmark panel; JANG prompt evaluator/masked compare; Python benchmarks | `MLXStudioEvaluation` using vMLX provider | Reuse scorers/fixtures; remove bespoke runners after saved-run and identical-settings tests |
| Prompt suites | `ExpertPromptSuite`; generated UI suites; Python JSONL suites | `EvaluationSuite` | Provide import adapter and versioned export; retire Expert-only persistence after round-trip/golden tests |
| Expert Atlas | JANG Expert Lab builders/store and UI-local state | `JANGExpertLab` service over traced results | Split reusable domain; retire UI-owned build/storage after persisted Atlas parity |
| Pruning recommendation | Existing Expert Lab hit/mass heuristic; canonical MAN/MSAN activation-norm strategies; capability-gated Kimi/MiniMax/DSV4 REAP adapters; JANG `recommend` conversion profile | `PruningStrategy` candidate generation plus measured evaluation | Raw scores remain strategy-specific; preserve adapter aggregation/provenance, keep DSV4 analysis-only until build parity, and require structural plus evaluation gates |
| Verification | MLX install verifiers; JANG preflight/post-convert; Python validators | Shared `VerificationReport` with contributing checks | Adapt checks; retire duplicated orchestration only after fixture and real-artifact parity |
| Subprocess execution | `PythonRunner`, `PythonCLIInvoker`, `InferenceRunner`, publish-specific handles | `PythonJANGWorker` | Consolidate deterministic argv/env, JSONL, cancel escalation, redaction, versions, partial-output policy |
| Settings | `SettingsStore`/SQLite; JANG `AppSettings`; scattered UserDefaults | MLX `SettingsStore` plus narrowly scoped UI preferences | Migrate relevant JANG settings; retire JANG settings with shell |
| Publishing | Python `publish`/modelcard/examples; JANG Studio services/sheets | Publishing job invoking structured worker operations | Keep Python implementation initially; remove UI subprocess ownership after dry-run, token-redaction, cancel, and manifest tests |
| Artifact manifests | JANG config/index/sidecars; image metadata; ad hoc conversion plans | `ArtifactManifest` and lineage repository | Import existing sidecars as evidence; every future artifact operation writes a canonical manifest |
| Comparison UI | JANG masked comparison; future MLX quick compare/blind A/B | `MLXStudioEvaluation` result model | Build one execution engine; multiple UI modes consume the same persisted results |

## Authority rules

- A capability may have multiple adapters or presentations, but only one durable identity and one production execution authority.
- Reference implementations remain runnable in tests until their replacement passes explicit parity; they are not linked into the final app as fallbacks.
- Estimates and measurements use distinct fields and labels. A completed build never silently overwrites the estimate that preceded it.
- Experimental strategies cannot be selected by beginner defaults or treated as production simply because an adapter exists.
