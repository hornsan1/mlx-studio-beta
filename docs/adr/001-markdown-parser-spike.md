# ADR 001b — Parser spike notes (Week 1)

**Status:** Interim recommendation  
**Date:** 2026-07-12  
**Parent:** [001-markdown-profile.md](./001-markdown-profile.md)

## Options evaluated

| Option | Pros | Cons |
| --- | --- | --- |
| **A. Lightweight in-tree splitter** (current) | Zero deps, full control, already ships tables + fences, offline-safe | Incomplete GFM grammar; no full AST; weak headings/lists/task lists |
| **B. MarkdownUI** ([gonzalezreal/MarkdownUI](https://github.com/gonzalezreal/MarkdownUI)) | Mature SwiftUI theming, CommonMark | Extra package size; GFM tables/task lists depend on version; less control over block IDs/source ranges |
| **C. cmark-gfm / swift-cmark bindings** | Spec-faithful GFM AST | C dependency packaging, SBOM review, harder source-range mapping |
| **D. WebKit HTML** | Fast feature surface | Rejected: XSS surface, remote content risk, non-native AX |

## Decision for this slice

**Ship A behind `MarkdownParser`.** Block views, `MarkdownLinkPolicy`, and `MarkdownOpenURL` are independent of the parser so B/C can replace A after a packaging gate without rewriting UI.

## Already shipped (parser surface)

- Backtick **and tilde** fenced code (` ``` ` / `~~~`)
- Unclosed fences → provisional code blocks (`isClosed: false`), not plain tail
- GFM pipe tables with alignment
- Progressive stream split (`StreamingMarkdownSplit`) with open-fence-as-stable-code
- Flat structural blocks (ATX headings, lists/tasks, blockquotes, thematic breaks) — see PR2a
- Render cache capacity **128**; warm on stream finalize / import

## Identity & security prerequisites (landed before grammar expansion)

- **Provisional block IDs (K13):** open fence **or** streaming terminal-growing block → end-invariant `…-open` accessibility / ForEach keys via `MarkdownBlockID`.
- **Link open path (K7):** `MarkdownOpenURL.sanitizeLinks` + `OpenURLAction` on all AttributedString markdown surfaces (`MarkdownProseView`, `MarkdownTableCell`).

These are correctness/security gates for expanding structural GFM (headings, lists, quotes, tasks).

## Packaging gate (before adopting B or C)

- [ ] Clean checkout builds offline
- [ ] License + SBOM reviewed
- [ ] macOS 14 deployment target OK
- [ ] Golden corpus (`tests/e2e/fixtures/markdown-golden.json`) green
- [ ] Installed-app Markdown smoke still passes
- [ ] No network required to render imported conversations

## Baseline measurements

**Reference host class:** Apple Silicon Mac (M1 or newer), optimized debug or release, app idle.  
**Harness:** `tests/vMLXAppTests/MarkdownPerformanceTests.swift` (`swift test --filter MarkdownPerformance`).  
**Cache:** `SyncMarkdownRenderCache` / `MarkdownRenderCache` default capacity **128** (eviction = re-parse cost).

### Soft-fail policy

| Rule | Behavior |
| --- | --- |
| Soft budgets (table below) | **Guidelines only.** Misses are printed / attached; they do **not** fail CI. |
| Hard sanity ceilings | Fail only if cold parse exceeds ~50–100× soft guideline (pathological hang / deadlock). |
| When to harden | After **N ≥ 3** local runs on a **named host class** stabilize absolute numbers, optional 2×-baseline hard fail may be added. |
| First-paint | Unit harness measures **parse + block construction** as a first-paint proxy; full layout FPS remains manual / Instruments. |

### Soft budgets (guidelines)

| Fixture | Budget (guideline) | Notes |
| --- | --- | --- |
| 20 KB GFM mix | Parse &lt; 5 ms cached / &lt; 30 ms cold | Typical assistant reply |
| 100 KB GFM mix | Parse &lt; 50 ms cold | Stress path |
| 1,000-line code fence | Parse proxy; first paint without multi-frame hitch | Collapse UI for code ≥80 lines (separate milestone) |

### Recorded runs

Fill rows when you re-run the harness. Do not leave numbers only in chat logs.

| Date | Hardware | Fixture | Cold ms | Cached ms | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-07-12 | Apple M4 Max (arm64), macOS 26.5, `swift test` debug | 20 KB GFM mix | 3.2 | 0.18 | Within soft budgets (&lt;30 / &lt;5) |
| 2026-07-12 | same | 100 KB GFM mix | 15.1 | 0.88 | Within soft cold &lt;50 ms |
| 2026-07-12 | same | 1,000-line code fence | 9.0 | 0.47 | Parse proxy for first paint; 1 closed code block |

Re-run:

```bash
swift test --filter MarkdownPerformance
```

Copy cold/cached ms from the `[20KB-gfm-mix]` / `[100KB-gfm-mix]` / `[1000-line-code]` log lines into the table above for the host under test.
