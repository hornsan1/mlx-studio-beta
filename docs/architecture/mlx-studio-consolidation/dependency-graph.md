# Dependency graphs

The current graphs are derived from the pinned manifests, not inferred from folder names.

## Current MLX Studio targets

```mermaid
flowchart LR
    Cmlx --> MLX
    MLX --> MLXRandom
    MLX --> MLXFast
    Cmlx --> MLXFast
    MLX --> MLXNN
    MLX --> MLXFFT
    MLX --> MLXLinalg
    MLXRandom --> MLXNN
    MLX --> MLXOptimizers
    MLXNN --> MLXOptimizers
    MLX --> Common["vMLXLMCommon"]
    MLXRandom --> Common
    MLXNN --> Common
    MLXOptimizers --> Common
    MLXFast --> Common
    Common --> LLM["vMLXLLM"]
    MLX --> LLM
    MLXNN --> LLM
    MLXOptimizers --> LLM
    Common --> VLM["vMLXVLM"]
    LLM --> VLM
    MLX --> VLM
    MLXNN --> VLM
    MLXOptimizers --> VLM
    Common --> Embedders["vMLXEmbedders"]
    MLX --> Embedders
    MLXNN --> Embedders
    MLX --> Whisper["vMLXWhisper"]
    MLXNN --> Whisper
    MLXFast --> Whisper
    TTS["vMLXTTS"]
    MLX --> FluxKit["vMLXFluxKit"]
    MLXNN --> FluxKit
    MLXRandom --> FluxKit
    Common --> FluxKit
    FluxKit --> FluxModels["vMLXFluxModels"]
    MLX --> FluxModels
    MLXNN --> FluxModels
    FluxKit --> FluxVideo["vMLXFluxVideo"]
    MLX --> FluxVideo
    FluxKit --> Flux["vMLXFlux"]
    FluxModels --> Flux
    FluxVideo --> Flux
    Domain["MLXStudioDomain"] --> Persistence["MLXStudioPersistence"]
    Domain --> Evaluation["MLXStudioEvaluation"]
    Persistence --> Evaluation
    Domain --> ExpertLabProduct["JANGExpertLab"]
    Evaluation --> ExpertLabProduct
    Domain --> OptimizationProduct["MLXStudioOptimization"]
    Persistence --> OptimizationProduct
    Evaluation --> OptimizationProduct
    Domain --> DomainTests["MLXStudioDomainTests"]
    Persistence --> PersistenceTests["MLXStudioPersistenceTests"]
    Domain --> EvaluationTests["MLXStudioEvaluationTests"]
    Persistence --> EvaluationTests
    Evaluation --> EvaluationTests
    Domain --> ExpertLabProductTests["JANGExpertLabTests"]
    ExpertLabProduct --> ExpertLabProductTests
    Domain --> OptimizationProductTests["MLXStudioOptimizationTests"]
    Persistence --> OptimizationProductTests
    OptimizationProduct --> OptimizationProductTests
    Domain --> Engine
    Persistence --> Engine
    MLX --> Engine["vMLXEngine"]
    LLM --> Engine
    VLM --> Engine
    Common --> Engine
    Embedders --> Engine
    Whisper --> Engine
    Flux --> Engine
    FluxKit --> Engine
    TTS --> Engine
    Engine --> Server["vMLXServer"]
    TTS --> Server
    Common --> Server
    Engine --> App["vMLXApp / MLXStudio"]
    Server --> App
    Theme["vMLXTheme"] --> App
    Domain --> App
    Engine --> CLI["vMLXCLI / vmlxctl"]
    Server --> CLI
    Engine --> Regression["RegressionCheck"]
    Server --> Regression
    Theme --> Regression
    FluxKit --> Regression
    MLX --> Regression
    App --> AppTests["vMLXAppTests"]
    Engine --> AppTests
    Domain --> AppTests
    MLX --> ParserTests["vMLXParserTests"]
    MLXNN --> ParserTests
    Domain --> ParserTests
    Persistence --> ParserTests
    Engine --> ParserTests
    Flux --> ParserTests
    FluxKit --> ParserTests
    FluxModels --> ParserTests
    Common --> ParserTests
    Server --> ParserTests
    VLM --> ParserTests
```

Arrows run from an internal dependency to its consumer. External package products (`Numerics`, `Transformers`, `Hummingbird`, `ArgumentParser`, and TLS/NIO products) are omitted so every node represents a current local SwiftPM target.

## Current JANG Swift targets

```mermaid
flowchart LR
    JANGCore --> JANGCoreMetal
    JANGMetal --> JANG
    JANGCoreMetal --> JANG
    JANG --> JANGKit
    JANG --> ExpertLab["JANGExpertLab"]
    JANGKit --> ExpertLab
    JANG --> JANGCLI
    JANGCoreMetal --> JANGCLI
    JANGCore --> CoreCLI["jang-core"]
    IOBench["jang-spec-iobench"]
    JANG --> JANGTests
    JANGCoreMetal --> JANGTests
    JANGKit --> JANGKitTests
    ExpertLab --> JANGExpertLabTests
    JANGCore --> JANGCoreTests
    JANGCoreMetal --> JANGCoreMetalTests
```

Arrows again run from dependency to consumer. `jang-spec-iobench` has no target dependency; external `ArgumentParser` edges are omitted.

At the pinned JANG source SHA, the problematic edge is `JANGKit → JANGExpertLab`: `ExpertPromptSuiteRunner` owns a `JANGKit.Model`, making Expert Lab depend on a second production inference runtime. In the canonical product package after PR 7, the adapted `JANGExpertLab` target instead depends on `MLXStudioDomain` and `MLXStudioEvaluation`; its suite runner accepts `ModelInferenceProvider` and has no `JANGKit` dependency.

## Current JANG Studio process graph

```mermaid
flowchart LR
    Wizard["JANG Studio wizard/screens"] --> Services["Recommendation / Profiles / Capabilities / ModelCard / Publish"]
    Wizard --> InferenceRunner
    Wizard --> PythonRunner
    Services --> PythonCLIInvoker
    PythonRunner --> Python["bundled Python + jang_tools"]
    PythonCLIInvoker --> Python
    InferenceRunner --> Python
    Wizard --> SwiftRuntime["JANGKit / JANGExpertLab"]
    Python --> Artifacts["JANG/JANGTQ folders + sidecars"]
    SwiftRuntime --> Artifacts
```

This process graph is migrated as one worker boundary; screens must not retain direct `Process` ownership.

## Proposed architecture flow

```mermaid
flowchart LR
    Domain["MLXStudioDomain\nFoundation only"] --> Persistence["MLXStudioPersistence"]
    Domain --> Jobs["MLXStudioJobs"]
    Persistence --> Evaluation["MLXStudioEvaluation"]
    Jobs --> Evaluation
    Evaluation --> Optimization["MLXStudioOptimization"]

    JCore["JANGCore"] --> JMetal["JANGMetal"]
    JCore --> JOptimize["JANGOptimize"]
    JMetal --> JOptimize
    JOptimize --> JLab["JANGExpertLab"]
    JOptimize --> Optimization
    JLab --> Optimization

    Engine["vMLXEngine + ModelInferenceProvider"] --> Domain

    App["vMLXApp / MLX Studio"] --> Domain
    App --> Persistence
    App --> Jobs
    App --> Evaluation
    App --> Optimization
    App --> Engine
    App --> Server["vMLXServer"]
    App --> JLab
```

This is the decision-level flow requested by the consolidation brief: `MLXStudioDomain → Persistence/Jobs → Evaluation → Optimization`, `JANGCore/JANGMetal → JANGOptimize → JANGExpertLab`, `vMLXEngine → MLXStudioDomain`, and `vMLXApp →` every application-facing target. It is not an import graph.

## Proposed compile-time dependencies

```mermaid
flowchart LR
    Persistence["MLXStudioPersistence"] --> Domain["MLXStudioDomain\nFoundation only"]
    Jobs["MLXStudioJobs"] --> Domain
    Jobs --> Persistence
    Evaluation["MLXStudioEvaluation"] --> Domain
    Evaluation --> Jobs
    Optimization["MLXStudioOptimization"] --> Domain
    Optimization --> Jobs
    Optimization --> Evaluation

    JMetal["JANGMetal"] --> JCore["JANGCore"]
    JOptimize["JANGOptimize"] --> JCore
    JOptimize --> JMetal
    JOptimize --> Domain
    JLab["JANGExpertLab"] --> JOptimize
    JLab --> Evaluation
    JLab --> Domain

    Engine["vMLXEngine"] --> Domain
    Server["vMLXServer"] --> Engine
    Server --> Domain
    Optimization --> JOptimize
    Optimization --> JLab

    App["vMLXApp / MLX Studio"] --> Domain
    App --> Persistence
    App --> Jobs
    App --> Evaluation
    App --> Optimization
    App --> Engine
    App --> Server
    App --> JLab

    Optimization -. "structured process protocol" .-> Worker["Workers/jang-tools"]
    Engine -. "provider injection; no import" .-> Evaluation
```

In this graph, solid arrows mean “imports/depends on.” Dashed arrows are runtime composition boundaries, not target imports. `MLXStudioDomain` imports Foundation only and cannot import SQLite, SwiftUI, MLX, Metal, JANG, or Python/process code. Provider protocols use domain-owned request/result types. Concrete vMLX adapters live with `vMLXEngine`; worker adapters live with `MLXStudioOptimization`.

## Proposed target responsibilities

| Target | Owns | Must not own |
| --- | --- | --- |
| `MLXStudioDomain` | IDs, projects, sources, artifacts, manifests, plans, suites, requests/results, provider/strategy/worker protocols | SQLite, MLX tensors, SwiftUI, subprocesses |
| `MLXStudioPersistence` | repositories, migrations, transactions, repair/backfill | runtime loading or UI state |
| `MLXStudioJobs` | job state machine, durable events/log references, recovery | algorithm or download implementation |
| `MLXStudioEvaluation` | suite runner, scorers, manifests, comparison, blind assignment, scorecards | concrete model loading |
| `MLXStudioOptimization` | plan validation, estimates, build orchestration, worker adapter | screen state or alternate inference |
| `JANGCore` | portable formats, indices, manifests | UI and full production inference |
| `JANGMetal` | audited JANG-specific kernels not already owned by vMLX | duplicate device/runtime lifecycle |
| `JANGOptimize` | pruning strategy adapters, mask application, JANG/JANGTQ native operations as ported | evaluation policy or UI |
| `JANGExpertLab` | Atlas/evidence builders and expert-domain services | `JANGKit.Model`, SwiftUI, subprocesses |

## Import rules

1. No application target may bypass a repository with raw artifact paths for identity.
2. No evaluation or optimization target may instantiate `JANGKit.Model` or Python inference.
3. SwiftUI screens depend on service protocols, not worker/process actors.
4. `vMLXEngine` is the only target that adapts domain generation requests to loaded MLX models.
5. `vMLXServer` resolves artifact IDs through the repository and serves through vMLX; it does not become a second inference provider.
