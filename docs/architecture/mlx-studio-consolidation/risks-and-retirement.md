# Risks and conditional retirement

## Unresolved technical risks

| Risk | Evidence | Required mitigation / owner phase |
| --- | --- | --- |
| Source drift | MLX Studio default advanced beyond the previously open feature branch | Pin SHAs per PR; refresh inventory before implementation if any source changes |
| Licensing/provenance | Code moves from private JANGQ into the product repo | Record origin/commit/license for every migrated file before PR 2+ merge |
| Swift/platform mismatch | MLX uses Swift 5.12/macOS 14; JANG runtime uses Swift 6/macOS 15 | Port code to product floor and run strict-concurrency checks; do not add a macOS 15 floor implicitly |
| Duplicate low-level kernels | vMLX already contains JANG/JANGTQ loaders and kernels while JANGQ has separate Metal/runtime targets | Produce symbol/format/kernel parity matrix before moving JANGCoreMetal/JANGMetal |
| Runtime capability gaps | JANGQ may support artifacts not accepted by the pinned vMLX loader | Gate retirement on real load/generate/trace/serve matrix per format and architecture |
| Fragmented converters | Many specialized Python entry points do not share arguments or JSONL behavior | PR 8 establishes a declared-operation worker and versioned JSONL boundary; add per-command adapters and parity tests without synthesizing unsupported universal flags |
| REAP portability | REAP aggregation differs across Kimi and MiniMax; DSV4 has a calibration forward but its pinned converter explicitly applies no REAP plan | PR 11 gates exact architectures, preserves per-adapter aggregation, and labels DSV4 analysis-only until worker/build parity exists |
| Missing strategies | No shared MAN, MSAN, or MAESTRO implementation exists at the Phase 0 SHAs | MAN/MSAN land in PR 10 with pinned literature/reference provenance and golden tests; MAESTRO remains a separately gated PR 12 experiment |
| Expert Lab coupling | The pinned source combines domain, SQLite, runner, and direct `JANGKit.Model`; UI files still contain orchestration | PR 7 removes the canonical target's `JANGKit.Model` edge via `ModelInferenceProvider`; continue splitting store/UI seams while preserving validator gates |
| Cross-store integrity | Chat and artifact databases cannot enforce foreign keys across files | Repository validation, repair report, nullable compatibility IDs, and no guessed matches |
| Large-model hashing cost | Full content hashes may read hundreds of GB | Incremental hashing job, cached file records, cancellation/resume, manifest hash distinct from content completion |
| Migration safety | Live app has existing chat/model/settings/image data | Test copied installed databases; use SQLite backup API and transactional versioning; never overwrite originals |
| Path/privacy leakage | Worker commands/logs/manifests can include local volume/user paths and tokens | Structured redaction at capture/export; token in environment/keychain only; redaction golden tests |
| Cancellation/partial outputs | Current subprocess paths have differing cancel behavior | One job state machine, SIGTERM/SIGKILL escalation, declared cleanup/quarantine/keep policy |
| Thermal/unified-memory pressure | Analysis/build/evaluation can exceed Apple Silicon memory | Preflight estimates, sequential evaluation, concurrency limits, thermal and swap observations |
| Evaluation validity | Baseline-invalid prompts and non-identical settings can create false pruning confidence | Baseline qualification, canonical generation configuration, suite/artifact/runtime fingerprints |
| UI consolidation regression | Chat and model workflows still have duplicate polished/feature-rich paths | Feature matrix and installed-app regression suite before navigation deletion |
| Public-host transition | `jang-studio-beta` is release-only but users may still depend on it | Redirect only after parity and migration documentation; keep historical releases accessible |

## Conditional retirement list

No item below is deleted in Phase 0.

| Candidate | Why it becomes redundant | Deletion gate |
| --- | --- | --- |
| `JANGStudio/JANGStudio/App/JANGStudioApp.swift` and wizard shell under `JANGStudio/JANGStudio/Wizard/` | MLX Studio becomes sole product shell | PR 19 navigation parity and all Optimize/Evaluate flows pass installed-app QA |
| `JANGStudio/JANGStudio/Runner/InferenceRunner.swift` and `jang-tools/jang_tools/inference.py` as product inference | vMLX provider becomes sole authority | JANG/JANGTQ output, trace, cancel, metrics, validation and serve matrix passes |
| `jang-runtime/Sources/JANGKit/Model.swift` production use | Expert Lab and evaluation no longer need alternate model loader/generator | PR 7 provider refactor plus Swift/Python parity fixtures pass; reference tests may remain temporarily |
| `jang-runtime/Sources/JANG/JANGInference.swift`, `jang-runtime/Sources/JANG/JANGTQGenerator.swift`, and duplicate CLI generation surfaces | Duplicate production generation | All supported artifacts load/generate through vMLX and no app target imports them |
| JANG Studio `PythonRunner.swift`, `PythonCLIInvoker.swift`, `CLIArgsBuilder.swift`, publish-specific process handles | `PythonJANGWorker` owns subprocess execution | Worker command, progress, cancel, diagnostics, redaction and partial-output tests cover every exposed operation |
| `StudioChatScreen` sections in `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`, chat types/service in `Sources/vMLXApp/MLXStudio/MLXStudioServices.swift`, `Sources/vMLXApp/MLXStudio/StudioChatHistoryStore.swift` | `ChatScreen`/`ChatViewModel`/SQLite is canonical | Attachment, settings, edit/branch/regenerate, draft, export, search, restart, model identity, and installed-app parity |
| `Sources/vMLXApp/Chat/StudioChatHistoryMigration.swift` | One-time UserDefaults bridge no longer needed | Two shipped compatibility releases with migration completion telemetry/marker; explicit cleanup PR |
| `ModelJob`, `StudioJobService`, and duplicate job events in `MLXStudioServices.swift` | Shared durable job system | Downloads/inspect/validate/benchmark/package/optimization/evaluation/publishing all use `MLXStudioJobs` |
| JANG UI-local comparison and prompt-run orchestration in `JANGStudio/JANGStudio/Wizard/ExpertLabSheet.swift` and `JANGStudio/JANGStudio/Wizard/PrequantPruneSheet.swift` | Evaluation/optimization services own execution | Same-suite validation and reviewed-prune fixture parity plus persisted-run restart tests |
| Duplicate JANG verification orchestration in `JANGStudio/JANGStudio/Verify/PreflightRunner.swift` and `JANGStudio/JANGStudio/Verify/PostConvertVerifier.swift` | Shared verification service aggregates checks | All existing good/broken fixtures and native smoke checks represented in `VerificationReport` |
| JANG Studio settings/publishing/model-card sheets | MLX Studio Settings and job-driven Publish own workflows | Setting migration, dry-run, token security, model-card output and publish cancel tests pass |
| Legacy `models` table/path-only readers | Artifact repository is universal | All selectors/chat/server/jobs use artifact IDs; rollback window and two installed upgrade passes complete |
| Old JANG Studio active-development guidance | Product consolidation complete | PR 20 redirects README/releases and publishes migration instructions |

## Code that must be preserved or audited, not blanket-deleted

- `JANGCore` format/index/manifest primitives and `JANGCoreMetal` kernels until vMLX equivalence is proven.
- Architecture-specific converters and verifiers that have no product-native equivalent.
- Expert Lab validators that enforce baseline qualification, same-suite evidence, mask application, prompt coverage, and structural safety.
- Golden fixtures and parity tests even after their implementation moves.
- Historical JANG Studio releases and migration documentation.

## Retirement review checklist

1. Name the canonical replacement and exact parity evidence.
2. Confirm no production import, command, screen, database reader, or packaging script still uses the candidate.
3. Run focused unit/integration/golden tests plus the relevant real-artifact installed-app path.
4. Preserve provenance and fixtures needed to diagnose regressions.
5. Delete in a narrow PR with rollback instructions; never combine retirement with a new architecture implementation.
