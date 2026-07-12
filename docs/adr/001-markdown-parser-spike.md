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

## Baseline measurements (to capture on target hardware)

| Fixture | Budget (guideline) | Notes |
| --- | --- | --- |
| 20 KB GFM mix | Parse &lt; 5 ms cached / &lt; 30 ms cold | Typical assistant reply |
| 100 KB GFM mix | Parse &lt; 50 ms cold | Stress path |
| 1,000-line code fence | First paint without main-thread hitch | Collapse UI later (Milestone 1) |

Record numbers in CI or local notes before expanding the grammar.
