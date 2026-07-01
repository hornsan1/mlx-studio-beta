# MLX Studio Visual Polish Handoff

Date: 2026-06-30

Scope: native SwiftUI MLX Studio redesign in `/Users/hermes/Documents/Codex/2026-06-24/wha/work/mlx-studio-beta`.

This handoff records the visual and interaction work that moved MLX Studio from a sparse local-model console toward a native Mac "studio noir" app. The next phase should treat these surfaces as product commitments: every visual affordance now needs matching behavior, persistence, and usability consistency.

## Product Direction

MLX Studio should feel calm, powerful, local, and honest.

- Beginner mode is the approachable product: Chat, Create, Models, Library.
- Advanced mode is the precise operator workspace: Server, Advanced Models, Diagnostics.
- Create is the visual showpiece.
- Library is the studio memory.
- Chat is a saved workspace, not a disposable prompt box.
- Model and image readiness claims remain proof-gated. Do not show "ready" for a model or image path unless a verifier or runtime proof supports it.

## Visual Foundation

Primary source:

- `Sources/vMLXTheme/Theme.swift`

Current theme direction:

- Graphite/noir background with subtle grid and panel gradients.
- Semantic colors instead of all-cyan: accent, success, warning, danger, creative.
- Small radii for native tool surfaces.
- SF/system typography for normal UI.
- Monospace reserved for paths, model ids, metrics, ports, settings, logs, and technical values.
- Reusable `Theme.ProNoirBackground` and `Theme.ProNoirPanelBackground` establish the visual language.

Design caution:

- Avoid adding decorative blobs, one-note gradients, or marketing-page composition.
- Do not turn dense app surfaces into hero pages. This is a Mac workbench.
- Keep information dense but scannable.

## App Shell And Mode Split

Primary sources:

- `Sources/vMLXApp/vMLXApp.swift`
- `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`
- `tests/e2e/mlx-studio-smoke.sh`

Visual commitments:

- Sidebar presents the core Beginner surface first: Chat, Create, Models, Library.
- Advanced mode unlocks Server, Advanced Models, Diagnostics.
- Beginner nav hiding advanced areas is smoke-covered.
- Mode toggle is visible in the left rail.
- The app now reads as one cohesive Studio surface rather than separate runtime tools.

Smoke anchors:

- `Chat`
- `Create`
- `Models`
- `Library`
- `Beginner nav hides Server`
- `Server`
- `Advanced Models`
- `Diagnostics`

## Onboarding

Primary source:

- `Sources/vMLXApp/Onboarding/SetupScreen.swift`

Visual features:

- First-run starts with "Local AI, ready to make something".
- Beginner/Advanced choice explains the product split.
- Beginner route selector offers Chat, Coding, Images, Research.
- `Goal routes` cards explain where each path lands.
- `First result path` turns setup into an outcome path rather than a settings checklist.
- `Ready handoff` card shows what will be prepared and where Finish lands.
- Recommended starter, local folder scan, and optional Hugging Face token setup are visible in the same flow.

Smoke anchors:

- `Goal routes`
- `Proof-gated canvas`
- `Local coding chat`
- `Prompts and sessions`
- `Ready handoff`
- `Finish lands in Chat`
- `Recommended starter`
- `Already have models?`

Behavior to verify next:

- Each route should land in the matching workflow, not always Chat.
- Starter install and local folder scan should use the same install/readiness vocabulary as Models.
- Hugging Face token entry should persist safely and surface gated-model state consistently.

## Chat

Primary source:

- `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`

Visual features:

- `Conversation runway` summarizes the active session, model readiness, session memory, and next action.
- Follow-up prompt buttons provide immediate continuation actions.
- Transcript and bubbles are framed as a readable session, with copy/regenerate/retry actions.
- `Session trail` summarizes prompt, latest response, and next move.
- Bottom `Keep moving` dock gives action starters: Explain failure, Make practical, Find risk, Branch idea, Save summary.
- Right rail has `Session context` plus `Session brief` with Purpose, Memory, and Handoff ready.
- Session stats remain visible but no longer dominate the panel.

Smoke anchors:

- `Conversation runway`
- `Model readiness`
- `Follow-up prompts`
- `Transcript`
- `Session trail`
- `Prepared in composer`
- `Session context`
- `Session brief`
- `Purpose`
- `Handoff ready`
- `Keep moving`
- `Make practical`
- `Find risk`
- `Save summary`

Behavior to verify next:

- Prompt starters should reliably write into the composer.
- "Save summary" should either perform a real save/export action or be renamed/disabled until it does.
- Session brief state must update when the user pins, retries, switches model, or opens a Library session.
- Failed turns should not trap the user in an incident state after a successful retry.
- New Chat, pin/unpin, Library open, and model switching should preserve session identity correctly.

## Create

Primary sources:

- `Sources/vMLXApp/Image/ImageScreen.swift`
- `Sources/vMLXApp/Image/ImageSettings.swift`
- `Sources/vMLXApp/Image/ImageGallery.swift`
- `Sources/vMLXApp/Image/ImagePromptBar.swift`
- `Sources/vMLXApp/Image/ImageHistory.swift`

Visual features:

- Canvas-forward layout with model picker and generation settings in the left rail.
- `Canvas stage` makes the latest output the dominant object.
- `Output canvas` artboard frames generated image output.
- `Prompt provenance` keeps prompt source visible.
- `Result handoff` confirms Prompt, Settings, and File state for reuse.
- `Run details` show model, created time, settings, runtime, and saved asset.
- `Output actions` expose Reveal file, Copy path, Reuse prompt, Delete output.
- Prompt bar contains `Creative brief` starters: Product shot, Portrait light, Concept frame.
- Image history rail shows recent outputs and status.
- Proven-ready image models remain gated by runtime proof.

Smoke anchors:

- `Generation Settings`
- `Canvas stage`
- `Output canvas`
- `Prompt provenance`
- `Ready for reuse`
- `Result handoff`
- `Prompt captured`
- `Settings captured`
- `File captured`
- `Saved asset`
- `Output actions`
- `Reveal file`
- `Copy path`
- `Creative brief`
- `Product shot`
- `Portrait light`
- `Prompt brief`
- `Recent outputs`
- `Ready output`
- optional `Proven ready` / `Z-Image Turbo 6-bit`

Behavior to verify next:

- Reveal file, Copy path, Reuse prompt, Delete output must work from the packaged app.
- Prompt starter buttons should populate the prompt consistently.
- Result handoff should update correctly for failed, cancelled, missing-file, and reused-output states.
- Image output must save sidecars and Library records atomically.
- Every model shown as ready or proven ready needs matching verifier/proof evidence.

## Models

Primary source:

- `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`

Visual features:

- Models page is organized by action and readiness, not just files.
- `Best ready action` highlights the immediately useful selected/local model.
- `Ready Now`, `Recommended Starters`, `Compatible Hub`, and `Local folders` guide user decisions.
- Model rows show modality, size, state, memory fit, route, and primary actions.
- Image-capable models show Create-ready/Canvas route.
- Chat-capable models show Chat route.

Smoke anchors:

- `Ready Now`
- `Best ready action`
- `Local folders`
- `Create-ready`
- `Memory fit`
- `Canvas route`
- `Chat route`
- `Recommended Starters`
- `Compatible Hub`
- `Hub result metadata`
- `supported by vMLX`

Behavior to verify next:

- Select, Load, Chat, Create, Delete, and Hub Download actions must map to consistent install/load state.
- Hugging Face search compatibility claims should be backed by metadata/verifier evidence.
- Memory fit should be tied to actual machine memory and model size assumptions.
- Deleting a model should clearly distinguish record removal from deleting files.

## Library

Primary sources:

- `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`
- `Sources/vMLXApp/Image/ImageLibraryView.swift`

Visual features:

- Library is positioned as `Studio memory`, not a file dump.
- Landing board highlights latest image, resume session, and model archive.
- Filters: All, Chats, Images, Models, Pinned.
- `Visual outputs` filtered view summarizes generated images and provenance count.
- `Reuse lane` makes the latest image prompt/settings/file reusable.
- Image records render as compact `Memory tile` artifacts with thumbnail, prompt, model/settings chips, status strip, and actions.
- Chat filter presents conversation archive and sessions.
- Model filter presents downloaded model archive.
- Search is visible at top and covered by smoke.

Smoke anchors:

- `Search Library`
- `Studio memory`
- `Recent work`
- `Image provenance`
- `Latest image`
- `Resume session`
- `Open Latest Chat`
- `Generated images`
- `Chat sessions`
- `Model archive`
- `Pinned work`
- `Images memory`
- `Visual outputs`
- `Reuse lane`
- `Memory tile`
- `Ready artifact`
- `Prompt packet`
- `Provenance`
- `Conversation archive`

Behavior to verify next:

- Filters and search need behavior tests across prompt, model, message, pinned state, and dates.
- Reuse latest prompt and Open canvas should land in Create with the selected record applied.
- Image card Open, Reveal, Copy prompt, Export metadata, and Delete must behave safely.
- Library should detect missing output files and present repair/remove states.
- Chat cards should support open, pin, rename, export, and delete without losing session state.

## Advanced: Server

Primary source:

- `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`

Visual features:

- Server is an Advanced-only control plane.
- Surface is denser and inspector-like: API State, Binding, Route Surface, Model Context, Control Plane, Operator Checklist.
- `Client Handshake` explains health probe and chat completion paths.
- Copy actions exist for endpoint/cURL style workflows.
- Route coverage and auth mode are visible.

Smoke anchors:

- `API State`
- `Binding`
- `Route Surface`
- `Model Context`
- `Control Plane`
- `Operator Checklist`
- `Runtime Contract`
- `Client Handshake`
- `Copy cURL`
- `Health probe`
- `Chat completion`
- `Auth Mode`
- `Route Coverage`
- `Copy Endpoint`

Behavior to verify next:

- Copy cURL and Copy Endpoint should write exact working strings to clipboard.
- Start/stop state should match the actual server lifecycle.
- Health probe and chat completion examples should reflect the active model and port.

## Advanced Models

Primary source:

- `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`

Visual features:

- Advanced Models reads as an operator inspector.
- `Operator sequence` explains Inspect files, Validation gate, Benchmark path, Report handoff.
- `Preflight inspector`, Artifact Ledger, Evidence, Operator signal, Tokenizer, Weights, and Next operation frame the model audit path.

Smoke anchors:

- `Model Inspector`
- `Job Queue`
- `Run Inspect`
- `Copy Path`
- `Operator sequence`
- `Inspect files`
- `Validation gate`
- `Benchmark path`
- `Report handoff`
- `Preflight inspector`
- `Artifact Ledger`
- `Evidence`
- `Operator signal`
- `Tokenizer`
- `Weights`
- `Next operation`

Behavior to verify next:

- Run Inspect should create/refresh real jobs with deterministic result state.
- Copy Path should copy the selected local path.
- Benchmark and report handoff actions should either work or be explicitly disabled with a reason.

## Diagnostics

Primary source:

- `Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift`

Visual features:

- Diagnostics is framed as triage: Engine State, Issue Triage, Runtime Pulse, Recent Errors, Inspector Logs.
- `Incident Brief` and `Copy Brief` make support handoff visible.
- `Recovery Path` gives Confirm impact and Execute move steps.
- Impact, Evidence, Next Move, Workflow blocked, Retry or inspect logs are visible.

Smoke anchors:

- `Engine State`
- `Issue Triage`
- `Runtime Pulse`
- `Recent Errors`
- `Inspector Logs`
- `Incident Brief`
- `Copy Brief`
- `Recovery Path`
- `Confirm impact`
- `Execute move`
- `Impact`
- `Evidence`
- `Next Move`
- `Workflow blocked`
- `Retry or inspect logs`

Behavior to verify next:

- Copy Brief should produce a useful redacted diagnostics payload.
- Recovery actions should map to actual commands or safe no-op explanations.
- Errors should be sourced from real download/load/chat/image/server paths, not just fixture text.

## Current Verification Evidence

Latest known lightweight packaged smoke command pattern:

```bash
swift build --product MLXStudio
CONFIGURATION=debug BUNDLE_MFLUX=0 DIST_DIR=/tmp/mlx-studio-design-pass scripts/package-mlx-studio-app.sh 0.1.0 <revision>
MLX_STUDIO_APP_PATH='/tmp/mlx-studio-design-pass/MLX Studio.app' MLX_STUDIO_REQUIRE_AX=0 MLX_STUDIO_HUB_SETTLE_SECONDS=2 tests/e2e/mlx-studio-smoke.sh
```

Important caveat:

- `BUNDLE_MFLUX=0` proves packaged app/UI flow, accessibility coverage, fixture-backed navigation, and visible surface consistency.
- It does not prove full bundled image generation runtime readiness.
- Do not use this smoke alone to claim image generation support.

Useful screenshot families under `Tests/e2e/reports/`:

- `mlx-studio-smoke-*-onboarding-1.png`
- `mlx-studio-smoke-*-onboarding-2.png`
- `mlx-studio-smoke-*-onboarding-3.png`
- `mlx-studio-smoke-*-beginner-chat.png`
- `mlx-studio-smoke-*-chat-after-hub-install.png`
- `mlx-studio-smoke-*-models.png`
- `mlx-studio-smoke-*-models-hf-search.png`
- `mlx-studio-smoke-*-create-settings.png`
- `mlx-studio-smoke-*-library.png`
- `mlx-studio-smoke-*-library-images-filter.png`
- `mlx-studio-smoke-*-library-chats-filter.png`
- `mlx-studio-smoke-*-advanced.png`
- `mlx-studio-smoke-*-server.png`
- `mlx-studio-smoke-*-advanced-models.png`
- `mlx-studio-smoke-*-diagnostics.png`

Static screenshot set under `outputs/screenshots/`:

- `mlx-studio-chat.png`
- `mlx-studio-create.png`
- `mlx-studio-models.png`
- `mlx-studio-library.png`
- `mlx-studio-server.png`
- `mlx-studio-advanced-models.png`
- `mlx-studio-diagnostics.png`

## Risks And Consistency Debt

The visual system now implies several product promises. These are the areas most likely to drift:

- Buttons that look actionable but only set text or route partially.
- Visual "ready" states not backed by verifier or runtime proof.
- Library cards showing provenance while export/reveal/delete behavior is incomplete.
- Chat session state diverging between right rail, runway, Library, and persisted JSON.
- Models page actions using different state language than onboarding and Create.
- Advanced copy/report actions not producing useful artifacts.
- Smoke assertions proving labels exist but not proving behaviors behind them.

## Recommended Next Phase

Move from visual polish to functionality consistency.

The next agent should:

1. Read this handoff first.
2. Run the lightweight packaged smoke to refresh screenshots.
3. Pick one visible affordance cluster per loop.
4. Verify the behavior behind every visible label/action in that cluster.
5. Add unit, integration, or AX smoke coverage for the behavior, not only the label.
6. Preserve proof-gated honesty around image support.
7. Keep visual polish stable while making the app more reliable and usable.

