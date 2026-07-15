# JANG Studio retirement record

Status: accepted. The coordinated [migration-source freeze](https://github.com/hornsan1/jangq-private/pull/1) and [public-host redirect](https://github.com/hornsan1/jang-studio-beta/pull/1) are merged.

## Scope and pinned evidence

JANG Studio is retired as an independently developed application shell. JANG remains the optimization and artifact brand inside MLX Studio, and the specialized Python implementations remain behind the structured worker where native parity has not been established. This retirement does not delete historical releases, conversion code, architecture-specific tools, fixtures, or provenance.

| Repository / evidence | Revision | Role after retirement |
| --- | --- | --- |
| `hornsan1/mlx-studio-beta` | PR 20 base `7d6f7b36c2187a815d4d6addbcc631194a81f1ab` | Canonical product and application source |
| `hornsan1/jangq-private` | migration baseline `5d5487c27fa81d9f51da27264ae855964e334070`; retirement notice `cd2595dcc7249ec418a5b802c80724f0670b3779` | Frozen migration source and specialized JANG implementation repository; no active JANG Studio product development |
| `hornsan1/jang-studio-beta` | redirect baseline `cfcc8f058065ec25371c45ad035eea2ca2399ab5`; redirect `f92c0aa9856e06c2af07abb430bf77552305b42a` | Public redirect plus immutable historical release assets |
| Installed/package proof | MLX Studio `0.2.5` build `2026071508` | Ad-hoc signed application built with the embedded Python 3.11 worker and `jang-tools 2.5.31` |

## Exit-gate evidence

| Gate | Canonical evidence | Result |
| --- | --- | --- |
| Product identity | [ADR-001](ADR-001-product-identity.md); one `vMLXApp` product shell | Pass |
| Runtime authority | `VMLXInferenceProvider` is the sole `ModelInferenceProvider` conformance; no production `JANGKit` import or `InferenceRunner` | Pass |
| Artifact and job ownership | `MLXStudioPersistence`, durable job repositories, canonical artifact IDs and compatibility bridges | Pass |
| Expert Lab decoupling | `JANGExpertLab` depends on `MLXStudioDomain` and `MLXStudioEvaluation`, not `JANGKit.Model` | Pass |
| Optimization strategies | Production MAN/MSAN, capability-gated REAP, and explicitly experimental MAESTRO are represented under `MLXStudioOptimization` | Pass |
| Evaluation parity | Quick Compare, Blind A/B, prompt-suite scorecards, and Loss Attribution use `MLXStudioEvaluation` and the vMLX provider | Pass |
| Conversion and verification boundary | `PythonJANGWorker` owns declared commands, JSONL progress, durable state, redaction, cancellation and partial-output policy | Pass |
| Model card and publishing | Structured model-card/publish operations, Keychain token injection, mandatory matching dry run, progress and cancellation landed in PR #23 | Pass |
| Navigation and duplicate services | PR #22 leaves Home, Chat, Models, Optimize and Evaluate as primary surfaces; retired selector/chat/job/comparison symbols are absent | Pass |
| Package proof | `swift test` passed 499 tests with four environment-dependent skips; the bundled worker completed model-card and publish dry runs without an upload; deep strict code-sign verification passed | Pass |
| Public transition | Release-host PR [`jang-studio-beta#1`](https://github.com/hornsan1/jang-studio-beta/pull/1) redirects to MLX Studio and keeps old release tags/assets available; source PR [`jangq-private#1`](https://github.com/hornsan1/jangq-private/pull/1) marks JANG Studio frozen | Pass |

Run the executable boundary check from the repository root:

```bash
scripts/verify-jang-studio-retirement.sh

# Full three-repository audit when the coordinated checkouts are available:
scripts/verify-jang-studio-retirement.sh \
  --jang-source /path/to/jangq-private \
  --release-host /path/to/jang-studio-beta
```

## User migration

1. Keep an existing JANG Studio installation until the desired MLX Studio build has been installed and opened successfully. The retirement does not uninstall or mutate the old application.
2. Install MLX Studio from the canonical [`hornsan1/mlx-studio-beta`](https://github.com/hornsan1/mlx-studio-beta) repository. Historical JANG Studio downloads remain available only for rollback and reproduction.
3. In **Models**, add existing JANG or JANGTQ model directories. Model data is not copied or re-quantized merely to adopt it into the canonical artifact repository.
4. Use **Optimize** for conversion, pruning, Atlas evidence and build/verification jobs. Use **Evaluate** for Quick Compare, Blind A/B, prompt suites and Loss Attribution.
5. Use **Model Tools > Model Card** and **Model Tools > Publish** for structured publishing. Re-enter the Hugging Face token in **Settings > API & Accounts** so it is stored by MLX Studio in Keychain; JANG Studio tokens or preferences are not silently copied.
6. Review former wizard preferences manually. Profile, method, output path and expert controls are explicit per-plan inputs in MLX Studio; partial conversion output follows the canonical quarantine policy rather than an imported app-global toggle. Python overrides remain opt-in deployment configuration (`MLX_STUDIO_JANG_PYTHON` and `MLX_STUDIO_JANG_PYTHONPATH`) rather than an imported JANG Studio setting.
7. Verify one representative artifact through load, generation, trace/evaluation and, if applicable, Serve before removing the old app from the machine.

## Intentional survivors

These are not duplicate product authorities and must not be removed by a broad cleanup:

- vMLX JANG/JANGTQ loaders, kernels and model adapters: the canonical runtime implementation.
- `PythonJANGWorker` plus pinned `jang_tools`: the structured conversion, specialized pruning, verification, model-card and publishing boundary.
- `StudioChatHistoryStore` and `StudioChatHistoryMigration`: compatibility-only readers retained for the documented two-release bridge; they do not own the active Chat UI.
- Source-only `JANGKit.Model`, Python test inference and old JANG Studio UI code in `jangq-private`: frozen reference material until named native parity and fixture-retention gates allow deletion.
- Golden fixtures, validation rules, architecture-specific converters, release checksums and historical JANG Studio releases.

## Rollback

- The public host keeps the `v2026.07.05` and `v0.2.0-beta-2026-07-14` releases and their checksums. No release asset or tag is deleted by PR 20.
- The migration-source revision remains available, including the former shell and its build instructions, for regression diagnosis. Its retirement notice changes support status, not git history.
- Existing model directories remain path-compatible. If a consolidated workflow fails, stop the MLX Studio job, retain/quarantine partial output according to the job policy, and reopen the historical JANG Studio build against a copy or untouched source directory.
- Database rollback follows [database-migration.md](database-migration.md); PR 20 itself performs no schema migration.

## Deletion boundary

PR 20 removes JANG Studio from active development and public “latest app” guidance; it does not bulk-delete source. Any later deletion requires a narrow PR that names the superseding fixtures, verifies historical reproduction remains possible, and satisfies the candidate-specific gate in [risks-and-retirement.md](risks-and-retirement.md).

## Known source-repository CI defect

The documentation-only source-freeze PR ran the existing **JANG Studio / Build + test on macOS 15** workflow. It failed during Python test collection because 16 tracked tests import missing `jang_tools.turboquant.*` modules. The same errors are present in the default-branch run for the pinned `5d5487c…` revision ([baseline run](https://github.com/hornsan1/jangq-private/actions/runs/28559677833); [freeze-PR run](https://github.com/hornsan1/jangq-private/actions/runs/29402349491)). PR 20 does not repair or hide that unrelated migration-source defect; the canonical MLX Studio suite and retirement verifier are green.
