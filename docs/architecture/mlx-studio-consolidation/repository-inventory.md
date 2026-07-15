# Repository and package inventory

This inventory was derived from the pinned revisions in [README](README.md) using `swift package dump-package`, `xcodebuild -list -json`, Python packaging metadata and command registration, source searches, and read-only SQLite inspection.

## Repository roles and scale

| Repository | Relevant implementation roots | Role after consolidation |
| --- | --- | --- |
| `mlx-studio-beta` | `Package.swift`, `Sources/`, `tests/`, `MLXStudio/` | Canonical application, runtime, model library, persistence, server, and future consolidation targets |
| `jangq-private` | `jang-runtime/`, `jang-tools/`, `JANGStudio/` | Source/reference for JANG formats, Metal, conversion, Expert Lab, verification, pruning, and publishing |
| `jang-studio-beta` | Release metadata and README | Redirect users to MLX Studio after parity; no code is migrated from this host |

The MLX repository includes a large vendored MLX C/C++/Metal runtime under `Sources/Cmlx` and Swift model implementations under `vMLXLLM`/`vMLXVLM`. These remain in place and are not mechanically migrated. JANGQ contains a Swift runtime package, a Python package with many architecture-specific tools, and an Xcode application shell.

### Grouped preserve-in-place inventory

Counts are from the pinned MLX Studio tree, do not overlap the individually dispositioned rows, and are represented by four group rows in `migration-map.csv`.

`migration-map.csv` is a header-first, standards-compliant CSV with 748 unique dispositions: 740 exact paths and eight grouped inventories. The exact-path set is 266 MLX Studio files and 474 JANG source files; release-host metadata and preserve-in-place trees use the group rows.

| Group | Pinned path | Files | Treatment |
| --- | --- | ---: | --- |
| Vendored MLX C/C++/Metal runtime | `Sources/Cmlx/**` | 1,563 | Preserve in place |
| Vendored MLX Swift runtime | `Sources/MLX*/**` | 101 | Preserve in place |
| Model architecture implementations | `Sources/vMLXLLM/Models/**`, `Sources/vMLXVLM/Models/**` | 84 | Preserve in place |
| Inert application assets | `assets/**`, `Sources/vMLXApp/Resources/**`, `vMLX/Assets.xcassets/**` | 43 | Preserve in place |

The JANG source contributes four separately grouped non-authored or inert inventories: one generated `jang.metallib`, 15 JANG Studio test fixtures, seven demos/assets, and two Python test fixtures. These are preserved or regenerated according to their CSV deletion gates; they are not counted as individually dispositioned authored source.

## Current MLX Studio package

`Package.swift` declares Swift tools 5.12 and macOS 14. The products are:

| Layer | Products / targets |
| --- | --- |
| MLX runtime | `MLX`, `MLXRandom`, `MLXNN`, `MLXOptimizers`, `MLXFFT`, `MLXLinalg`, `MLXFast`; all ultimately depend on `Cmlx` |
| Model runtime | `vMLXLMCommon`, `vMLXLLM`, `vMLXVLM`, `vMLXEmbedders`, `vMLXWhisper`, `vMLXTTS` |
| Image/video | `vMLXFluxKit`, `vMLXFluxModels`, `vMLXFluxVideo`, `vMLXFlux` |
| Application/runtime | `vMLXEngine`, `vMLXServer`, `vMLXTheme`, executable `vMLXApp` exposed as `MLXStudio` |
| Tools | executables `vMLXCLI` (`vmlxctl`) and `RegressionCheck` (`regression-check`) |
| Tests | `vMLXParserTests` in `tests/vMLXTests`; `vMLXAppTests` in `tests/vMLXAppTests` |

Important current dependency edges are `vMLXLMCommon → MLX*`, `vMLXLLM/vMLXVLM → vMLXLMCommon`, `vMLXEngine → all supported modality runtimes`, `vMLXServer → vMLXEngine`, and `vMLXApp → vMLXEngine + vMLXServer + vMLXTheme`.

## Current JANG packages

### Swift runtime

`jang-runtime/Package.swift` declares Swift tools 6.0 and macOS 15.

| Product / target | Dependencies | Disposition |
| --- | --- | --- |
| `JANGMetal` | none | Reference; its device/error layer is superseded by MLX/Metal ownership |
| `JANG` | `JANGMetal`, `JANGCoreMetal` | Split format/trace concepts from duplicate inference |
| `JANGKit` | `JANG` | Adapt public request/trace concepts; retire `Model` inference after parity |
| `JANGExpertLab` | `JANGKit`, `JANG` | Migrate prompt/Atlas/plan/evidence domain, then remove runtime dependency |
| `JANGCore` | none | Move compatible format/index/manifest primitives |
| `JANGCoreMetal` | `JANGCore` | Compare/migrate kernels after vMLX kernel audit |
| `JANGCLI`, `JangCoreCLI`, `JangSpecIOBench` | runtime targets | Reference/diagnostic tools; not app runtime authorities |

Test targets are `JANGTests`, `JANGKitTests`, `JANGExpertLabTests`, `JANGCoreTests`, and `JANGCoreMetalTests`.

### Python tools

`jang-tools/pyproject.toml` defines package `jang` 2.5.31 for Python 3.11+. Core dependencies are `safetensors`, `numpy`, `tqdm`, `huggingface_hub`, and `jinja2`; optional runtime dependencies add MLX, MLX-LM, MLX-VLM, Torch, and Transformers.

The pinned package exposes these console entry points (name → implementation):

```text
jang → jang_tools.__main__:main
jang-convert-gemma4-jang → jang_tools.convert_gemma4_jang:main
jang-convert-gemma4-mxfp → jang_tools.convert_gemma4_mxfp:main
jang-convert-kimi-jangtq → jang_tools.kimi_prune.convert_kimi_jangtq:main
jang-convert-laguna-jangtq → jang_tools.convert_laguna_jangtq:main
jang-convert-laguna-mxfp4 → jang_tools.convert_laguna_mxfp4:main
jang-convert-mimo-v2-jang → jang_tools.mimo_v2.convert_jang:main
jang-convert-mistral3-jangtq → jang_tools.convert_mistral3_jangtq:main
jang-convert-mistral3-mxfp4 → jang_tools.convert_mistral3_mxfp4:main
jang-convert-zaya-jangtq → jang_tools.convert_zaya_jangtq:main
jang-convert-zaya-mxfp4 → jang_tools.convert_zaya_mxfp4:main
jang-convert-zaya1-vl-jangtq → jang_tools.convert_zaya1_vl_jangtq:main
jang-convert-zaya1-vl-mxfp4 → jang_tools.convert_zaya1_vl_mxfp4:main
jang-dsv4-build-role-codebooks → jang_tools.dsv4.build_role_codebooks:main
jang-dsv4-codesign-smoke → jang_tools.dsv4.experiments.codesign_smoke:main
jang-laguna-runtime → jang_tools.laguna.runtime:main
jang-mistral3-runtime → jang_tools.mistral3.runtime:main
jang-mmlu → jang_tools.eval.mmlu:main
jang-patch-dsv4-compressor-dtypes → jang_tools.patch_dsv4_compressor_dtypes:main
jang-verify-mimo-v2 → jang_tools.mimo_v2.verify_bundle:main
```

The `jang` command registers `inspect`, `validate`, `estimate`, `convert`, `profile`, `upgrade`, `spec build/inspect`, `inspect-source`, `examples`, `modelcard`, `inference`, `profiles`, `capabilities`, `estimate-model`, `publish`, `recommend`, `prequant-prune-qwen-moe`, `expert-lab-vmlx`, and `expert-lab-vmlx-build-eval`. `pyproject.toml` also exposes architecture-specific converters and utilities for Laguna, Mistral 3, Zaya/Zaya VL, Kimi, Gemma 4, MiMo V2, DSV4, and MMLU.

Only the common CLI path consistently owns the global JSONL progress emitter. Specialized commands require individual event/cancellation/capability audits before worker exposure.

### JANG Studio Xcode application

The Xcode project contains app target `JANGStudio`, unit target `JANGStudioTests`, and UI target `JANGStudioUITests`. Its schemes also expose the local JANG Swift products. The shell is a wizard coordinated by `WizardCoordinator.swift`; subprocess behavior is spread across `CLIArgsBuilder.swift`, `PythonRunner.swift`, `PythonCLIInvoker.swift`, `InferenceRunner.swift`, and adoption services. This entire UI target is a migration source, not a destination.

## Current application modes

`AppState.Mode` in `Sources/vMLXApp/vMLXApp.swift` defines Chat, Create, Models, Library, Server, Advanced Models, Diagnostics, Image, Terminal, and API. Beginner navigation exposes Chat/Create/Models/Library; Advanced adds Server/Advanced Models/Diagnostics. The consolidation target is Home/Chat/Models/Optimize/Evaluate with Create/Serve/Downloads/Diagnostics/Settings secondary. Phase 0 does not change navigation.

## Current persistence inventory

Read-only inspection of installed MLX Studio 0.2.5 build 2026071302 produced:

| Store | Source owner | Version | Tables | Live evidence |
| --- | --- | ---: | --- | --- |
| `vmlx.sqlite3` | `Sources/vMLXApp/Storage/Database.swift` | 4 | `sessions`, `messages`, `chat_drafts`, `api_keys` | 12 sessions, 55 messages |
| `models.sqlite3` | `Sources/vMLXEngine/Library/ModelLibraryDB.swift` | 2 | `models`, `user_dirs` | 11 model rows across bundle, HF, and user roots |
| `settings.sqlite3` | `Sources/vMLXEngine/Settings/SettingsDB.swift` | 1 | `global_settings`, `session_settings`, `chat_settings` | JSON settings records |
| `image_history.sqlite3` | `Sources/vMLXApp/Storage/ImageHistoryStore.swift` | 0 | `image_generations` | Independent image history |

The redesigned Studio chat also retains a legacy `UserDefaults` store in `StudioChatHistoryStore.swift`, bridged by `StudioChatHistoryMigration.swift`. It is a conditional retirement candidate.

## Required capability source map

Paths are relative to their repository.

| Capability | Current source of truth / exact implementation files | Finding and destination |
| --- | --- | --- |
| vMLX inference | `Sources/vMLXEngine/Engine.swift`, `EngineAdapters.swift`, `Stream.swift`, `ChatRequest.swift`; `Sources/vMLXLMCommon/Load.swift`, `Evaluate.swift`, `ChatSession.swift`, `ModelContainer.swift`; `Sources/vMLXLLM/LLMModelFactory.swift`; `Sources/vMLXVLM/VLMModelFactory.swift` | Canonical runtime; implement `ModelInferenceProvider` here |
| JANG/JANGTQ loading in vMLX | `Sources/vMLXLMCommon/JangLoader.swift`, `Sources/vMLXLMCommon/JangMXTQDequant.swift`, `Sources/vMLXLMCommon/JANGTQKernels.swift`, `Sources/vMLXLMCommon/JangSpecBundleLoader.swift`; model files under `Sources/vMLXLLM/Models/` and `Sources/vMLXVLM/Models/` | Preserve as production loading authority; reconcile missing format/kernel features from JANGQ |
| Model library | `Sources/vMLXEngine/Library/ModelLibrary.swift`, `ModelLibraryDB.swift`, `ModelLibraryWatcher.swift`; `ModelDetector.swift`, `ModelCapabilities.swift`, `CapabilityDetector.swift` | Evolve into `ModelArtifactRepository` plus artifact scanner |
| Downloads | `Sources/vMLXEngine/DownloadManager.swift`, `Sources/vMLXEngine/Security/HuggingFaceAuth.swift`, `Sources/vMLXEngine/Security/HuggingFaceDownloadSafety.swift`, `Sources/vMLXEngine/Security/HuggingFaceSearch.swift`; `Sources/vMLXApp/Downloads/DownloadsWindow.swift`, `Sources/vMLXApp/Downloads/ModelSearchPanel.swift`; `Sources/vMLXApp/MLXStudio/StudioModelInstallCoordinator.swift` | Keep transfer engine; adapt state/events into shared jobs |
| Chat | `Sources/vMLXApp/Chat/ChatScreen.swift`, `Sources/vMLXApp/Chat/ChatViewModel.swift`, `Sources/vMLXApp/Chat/ChatLaunchIntent.swift`, `Sources/vMLXApp/Chat/ChatModelEntryResolver.swift`, `Sources/vMLXApp/Storage/Database.swift`, `Sources/vMLXApp/Storage/Models.swift`; runtime `Engine.stream` | Canonical UI/runtime path; add artifact IDs and provider boundary |
| Duplicate chat | `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift` (`StudioChatScreen`), `Sources/vMLXApp/MLXStudio/MLXStudioServices.swift` chat types/services, `Sources/vMLXApp/MLXStudio/StudioChatHistoryStore.swift` | Reference parity, then retire after SQLite/UI parity |
| Server/API | `Sources/vMLXServer/Server.swift`, `Sources/vMLXServer/GatewayServer.swift`, `Sources/vMLXServer/Routes/OpenAIRoutes.swift`, `Sources/vMLXServer/Routes/AnthropicRoutes.swift`, `Sources/vMLXServer/Routes/OllamaRoutes.swift`; `Sources/vMLXApp/Server/HTTPServerActor.swift`, `Sources/vMLXApp/Server/GatewayActor.swift`, `Sources/vMLXApp/Server/ServerScreen.swift`; `Sources/vMLXApp/API/APIScreen.swift` | Canonical Serve implementation; resolve artifacts through repository |
| Metrics | `Sources/vMLXEngine/Metrics/MetricsCollector.swift`, `Sources/vMLXEngine/Lifecycle/ThermalMonitor.swift`, `Sources/vMLXServer/Routes/MetricsRoutes.swift`, `Sources/vMLXApp/Server/PerformancePanel.swift`, `Sources/vMLXApp/Server/BenchmarkPanel.swift` | Keep collector and wrap with `RuntimeMetricsProvider`; remove parallel measurements |
| Settings | `Sources/vMLXEngine/Settings/SettingsStore.swift`, `Sources/vMLXEngine/Settings/SettingsDB.swift`, `Sources/vMLXEngine/Settings/SettingsTypes.swift`; `Sources/vMLXApp/Locale/SettingsScreen.swift` | Preserve physical store; UI may move but no new settings system |
| Diagnostics/logs | `Sources/vMLXEngine/DebugBundle.swift`, `Sources/vMLXEngine/Logging/LogStore.swift`; diagnostics services/screens in `Sources/vMLXApp/MLXStudio/MLXStudioServices.swift` and `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift` | Consolidate around LogStore/DebugBundle and job diagnostic exports |
| JANG conversion | `jang-tools/jang_tools/convert.py`, `jang-tools/jang_tools/allocate.py`, `jang-tools/jang_tools/quantize.py`, `jang-tools/jang_tools/calibrate.py`; `jang-tools/jang_tools/format/` and architecture-specific `jang-tools/jang_tools/convert_*.py`/subpackages | Wrap with `PythonJANGWorker`; retain specialization |
| JANGTQ conversion | `jang-tools/jang_tools/convert_qwen35_jangtq.py`, `jang-tools/jang_tools/convert_minimax_jangtq.py`, `jang-tools/jang_tools/kimi_prune/convert_kimi_jangtq.py`, `jang-tools/jang_tools/convert_gemma4_jang.py`, `jang-tools/jang_tools/convert_gemma4_mxfp.py`, `jang-tools/jang_tools/mimo_v2/convert_jang.py` | Worker capability registry; no universal command assumption |
| Expert tracing | `jang-runtime/Sources/JANG/ExpertTracing.swift`, `jang-runtime/Sources/JANGKit/Model.swift`, `jang-tools/jang_tools/expert_lab_vmlx.py`, and architecture router/layer-forward modules in `jang-tools/jang_tools/` | vMLX provider must become authority; preserve trace schema/evidence |
| Expert Atlas | `jang-runtime/Sources/JANGExpertLab/JANGExpertLab.swift`; `JANGStudio/JANGStudio/Wizard/ExpertLabSheet.swift` | Split domain/builders/store from UI; move to `JANGExpertLab` target |
| Prompt suites | `jang-runtime/Sources/JANGExpertLab/JANGExpertLab.swift` (`ExpertPrompt`, suite, evaluators, runner); `JANGStudio/JANGStudio/Wizard/ExpertLabSheet.swift`; `jang-tools/jang_tools/expert_lab_vmlx.py` | Generalize into `MLXStudioEvaluation`; retain JSONL compatibility |
| Reviewed pruning | `jang-runtime/Sources/JANGExpertLab/JANGExpertLab.swift` plan builder/validation; `JANGStudio/JANGStudio/Wizard/PrequantPruneSheet.swift`; `jang-tools/jang_tools/prequant_prune_qwen_moe.py` | Common plan validator plus worker operation |
| REAP | `jang-tools/jang_tools/kimi_prune/jangreap.py`, `jang-tools/jang_tools/minimax_m3/reap_profile.py`, `jang-tools/jang_tools/minimax_m3/reap_select.py`, and DSV4 calibration forward/ops under `jang-tools/jang_tools/dsv4/` | Canonical capability-gated adapter: `Sources/MLXStudioOptimization/REAPPruningStrategy.swift`; Kimi uses routed-token mean, MiniMax preserves summed-saliency selection, and DSV4 remains explicitly analysis-only because its pinned converter applies no REAP plan |
| MAN | No implementation at the three Phase 0 source SHAs; literature/reference provenance is Liu et al. arXiv:2606.15716v1 and `ZongfangLiu/unified-expert-pruning@0482ca78349ad2804c70a78526b055bfd9259dc4` | Canonical production implementation: `Sources/MLXStudioOptimization/ActivationNormPruningStrategies.swift` (`MANPruningStrategy`) |
| MSAN | No implementation at the three Phase 0 source SHAs; literature/reference provenance is Liu et al. arXiv:2606.15716v1 and `ZongfangLiu/unified-expert-pruning@0482ca78349ad2804c70a78526b055bfd9259dc4` | Canonical production implementation: `Sources/MLXStudioOptimization/ActivationNormPruningStrategies.swift` (`MSANPruningStrategy`) |
| MAESTRO | No implementation found | New experimental adapter required in PR 12; never default |
| Verification | `Sources/vMLXEngine/ModelInstallReadinessVerifier.swift`, `Sources/vMLXEngine/ImageModelInstallVerifier.swift`; `JANGStudio/JANGStudio/Verify/PreflightRunner.swift`, `JANGStudio/JANGStudio/Verify/PostConvertVerifier.swift`, `JANGStudio/JANGStudio/Verify/VerifyCheck.swift`; `jang-tools/jang_tools/capabilities.py` and `jang-tools/jang_tools/verify_*.py` files | Define shared verification report; worker/native checks contribute evidence |
| Test inference | `JANGStudio/JANGStudio/Runner/InferenceRunner.swift`, `JANGStudio/JANGStudio/Wizard/TestInferenceViewModel.swift`, `JANGStudio/JANGStudio/Wizard/TestInferenceSheet.swift`; `jang-tools/jang_tools/inference.py` | Retire after all validation and comparison run through vMLX provider |
| Evaluation/comparison | `Sources/vMLXLMCommon/Evaluate.swift`, `Sources/vMLXApp/Server/BenchmarkPanel.swift`; masked comparison in `jang-runtime/Sources/JANGExpertLab/JANGExpertLab.swift` and `JANGStudio/JANGStudio/Wizard/ExpertLabSheet.swift` | Build one `MLXStudioEvaluation` runner; existing pieces are inputs |
| Publishing | `jang-tools/jang_tools/publish.py`, `jang-tools/jang_tools/modelcard.py`, `jang-tools/jang_tools/examples.py`; `JANGStudio/JANGStudio/Runner/PublishService.swift`, `JANGStudio/JANGStudio/Runner/ModelCardService.swift`, `JANGStudio/JANGStudio/Wizard/PublishToHuggingFaceSheet.swift`, `JANGStudio/JANGStudio/Wizard/GenerateModelCardSheet.swift` | Worker-backed publishing job with token redaction and manifest lineage |
| Jobs | `Sources/vMLXEngine/DownloadManager.swift` (`Job`), `Sources/vMLXApp/MLXStudio/MLXStudioServices.swift` (`ModelJob`/`StudioJobService`), `JANGStudio/JANGStudio/Models/ProgressEvent.swift`, `JANGStudio/JANGStudio/Runner/PythonRunner.swift` | Replace application-facing duplicates with `MLXStudioJobs`; adapters preserve engines |

## Findings that constrain implementation

- The Swift packages have a tools/platform mismatch: MLX Studio is Swift 5.12/macOS 14; JANG runtime is Swift 6/macOS 15.
- At the pinned source SHA, `jang-runtime/Sources/JANGExpertLab/JANGExpertLab.swift` is a large combined domain/store/runner file and directly imports `JANG` and `JANGKit`. The canonical PR 7 adaptation preserves its Atlas/plan/evidence behavior in `Sources/JANGExpertLab/` while replacing the runner's `JANGKit.Model` ownership with injected `ModelInferenceProvider`.
- The canonical PR 8 worker consolidates `PythonRunner`, `PythonCLIInvoker`, `CLIArgsBuilder`, and `JSONLProgressParser` behavior in `MLXStudioOptimization`. It supports only declared operations; specialized Python commands remain unavailable until their command adapters and parity fixtures land.
- The canonical PR 9 planning boundary keeps topology, constraints, Auto/Keep/Remove directives, normalized masks, estimates, and strategy contracts in Foundation-only `MLXStudioDomain`. `Sources/MLXStudioOptimization/OptimizationPlanValidator.swift` is the common executable-plan gate; it resolves strategy-proposed automatic removals, applies user overrides, and emits no structural mask when architecture, range, protected-expert, survivor, trained-top-k, removal-fraction, or estimate validation fails.
- The canonical PR 10 `MANPruningStrategy` and `MSANPruningStrategy` implementations use the gate-free, routed-token-average formulas from Liu et al., arXiv:2606.15716v1, cross-checked against `ZongfangLiu/unified-expert-pruning@0482ca78349ad2804c70a78526b055bfd9259dc4`. Raw scores remain separate; within-layer midrank percentiles are display/ranking evidence only. Production support is limited to the paper's `qwen3_moe`, `olmoe`, `ernie4_5_moe`, and `deepseek_v2` architecture matrix.
- The canonical PR 11 REAP boundary admits only exact `kimi_k25`, `minimax_m3_vl`, and `deepseek_v4` capabilities from `jangq-private@5d5487c27fa81d9f51da27264ae855964e334070`. It preserves Kimi's routed-token mean and MiniMax's accumulated-saliency ranking as separate adapter semantics. DSV4 can produce analysis candidates from its calibration-forward contract, but the adapter warns that build application is unavailable because `convert_dsv4_jangtq.py` explicitly retains all experts.
- JANG Studio verification and Expert Lab screens contain substantial orchestration logic that must move behind services before UI reuse.
- The existing vMLX tree already carries JANG/JANGTQ loader and kernel work, so copying JANG runtime wholesale would create a third runtime rather than consolidating one.
- Cross-database artifact references cannot use native SQLite foreign keys; repository-level validation and repair are required while stores remain split.
