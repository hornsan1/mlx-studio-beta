# Goal Prompt - MLX Studio Functionality And Consistency Pass

Use this prompt to continue after the visual polish phase.

````text
Continue working in the real SwiftUI app:
/Users/hermes/Documents/Codex/2026-06-24/wha/work/mlx-studio-beta

Primary reference:
/Users/hermes/Documents/Codex/2026-06-24/wha/work/mlx-studio-beta/docs/Handoffs/mlx-studio-visual-polish-handoff-2026-06-30.md

Objective:
Now that MLX Studio has a stronger native "studio noir" visual system, make the app's functionality, state consistency, and usability match the visual promises. The goal is not more decorative polish. The goal is to make every visible affordance behave consistently, persist correctly, and stay honest about what the local runtime can actually do.

Operating rules:
1. Read the visual handoff document first.
2. Inspect the current code and latest screenshots before editing.
3. Treat the current worktree as authoritative and dirty; do not revert unrelated changes.
4. Work in small verified passes.
5. Prefer behavior fixes, state consistency, and usability proof over new visual features.
6. Keep proof-gated image/model readiness honest. Do not claim support from a green build or label-only smoke.
7. Use existing SwiftUI/vMLX patterns and existing smoke harnesses before inventing new architecture.

Core verification loop:
1. Pick one visible affordance cluster from the handoff.
2. List the user-visible promise it makes.
3. Trace the code path behind that promise.
4. Fix any mismatch between label, state, action, persistence, and runtime behavior.
5. Add focused coverage: unit tests when state logic is local, packaged smoke/AX checks when behavior is UI-visible, and manual screenshot inspection when layout matters.
6. Build, package, smoke, and inspect the relevant screenshot.
7. Document exactly what is proven and what is still caveated.

Required first pass:
Start with Chat or Library, because they now imply saved workspaces:
- Chat: verify New, Pin/Unpin, prompt starters, retry/regenerate/copy, Session brief, Session trail, Library open, persistence after relaunch, and failed-turn recovery.
- Library: verify filters/search, image reuse, Open canvas, Open/Reveal/Copy/Export/Delete image actions, chat open/pin/export/delete, and missing-file behavior.

Then continue through:
- Create: verify prompt starters, Generate/Edit enabling, model readiness, result handoff, reveal/copy/reuse/delete, sidecar writes, and Library propagation.
- Models: verify Select, Load, Chat, Create, compatible Hub search, download-to-ready state, memory fit, proof-gated image rows, and delete semantics.
- Onboarding: verify Chat/Coding/Images/Research route landing, starter download, local scan, HF token handling, and Beginner/Advanced gating.
- Advanced Server: verify start/stop, Copy Endpoint, Copy cURL, health probe, route coverage, auth mode, active model/port consistency.
- Advanced Models: verify Run Inspect, Copy Path, operator sequence state, report handoff, benchmark gating, artifact evidence.
- Diagnostics: verify Copy Brief, Recovery Path actions, issue sourcing, redaction, and recent error freshness.

Definition of done for this goal:
- The visual affordances listed in the handoff have matching behavior or are clearly disabled with an honest reason.
- Beginner mode remains approachable and hides advanced concepts by default.
- Advanced mode remains dense and precise, with copyable operational state.
- Chat, Create, Models, and Library maintain consistent state when navigating between them.
- Library reflects real saved chats/images/models and does not silently lose artifacts.
- Model/image readiness labels are backed by verifier/runtime evidence.
- Packaged smoke passes, and any remaining caveats are concrete and path-specific.
- The app feels usable, not just polished.

Standard verification commands:
```bash
swift build --product MLXStudio
CONFIGURATION=debug BUNDLE_MFLUX=0 DIST_DIR=/tmp/mlx-studio-design-pass scripts/package-mlx-studio-app.sh 0.1.0 <revision>
MLX_STUDIO_APP_PATH='/tmp/mlx-studio-design-pass/MLX Studio.app' MLX_STUDIO_REQUIRE_AX=0 MLX_STUDIO_HUB_SETTLE_SECONDS=2 tests/e2e/mlx-studio-smoke.sh
```

Important caveat:
The standard `BUNDLE_MFLUX=0` smoke proves packaged app/UI flow and accessibility coverage. It does not prove full bundled image generation runtime readiness. Any claim that an image model is supported must be backed by a normal packaged runtime proof that produces a nonblank PNG and records proof state.

Expected final report:
- Files changed.
- Behavior promises verified.
- Commands run.
- Screenshots inspected.
- Any caveats or blockers with exact paths/errors.
- Explicitly state whether the broader goal remains active or is fully complete.
````
