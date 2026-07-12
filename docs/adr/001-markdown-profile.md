# ADR 001 — MLX Studio Markdown profile

**Status:** Accepted  
**Date:** 2026-07-12  
**Context:** Next-level Markdown plan for `ChatScreen` / `MessageBubble`

## Decision

MLX Studio ships a **GFM-focused, native SwiftUI** Markdown surface for assistant messages. Raw Markdown is the durable source of truth; parse trees and render caches are derived and never authoritative in SQLite.

### Supported dialect (core profile)

| Construct | Support |
| --- | --- |
| Headings (ATX) | Planned (Milestone 1); prose path may render via `AttributedString` until then |
| Paragraphs, hard/soft breaks | Yes |
| Emphasis / strong / strikethrough | Yes (inline via system Markdown where available) |
| Links | Yes, user-activated only; scheme allowlist |
| Nested lists, task lists | Partial today; full GFM in Milestone 1 |
| Blockquotes, thematic breaks | Partial / planned |
| Inline code | Yes |
| Fenced code (`` ``` `` / `~~~`) | Backtick fences today; tilde + unclosed-as-code in Milestone 1 |
| GFM pipe tables + alignment | Yes |
| Raw HTML | **Inert** — shown as text/code, never interpreted |
| Remote images / media | **Deferred** — no automatic network fetch |
| Math, Mermaid, footnotes | Deferred (P1/P2) |

### Safety

1. **Native views only** — no WebView/HTML renderer for chat Markdown.
2. **Links** — only `https`, `http`, and `mailto`. Block `file:`, custom schemes, and automatic opens.
3. **No execution** — code blocks are copyable/selectable, never runnable from the bubble.
4. **Source of truth** — `ChatMessage.content` (later `displayContent`) stores original Markdown bytes.

### Parser strategy

- Short term: production uses `LightweightMarkdownParser` (existing fence + GFM table splitter) behind `MarkdownParser`.
- Medium term: evaluate MarkdownUI / GFM AST packages behind the same protocol; block views and link policy stay independent of the parser.
- Fallback: keep the lightweight parser as a no-dependency compatibility path.

### Explicit non-goals (this release track)

- Code execution, tools, agent actions from Markdown
- Remote content fetching to render messages
- Treating arbitrary Markdown import as a lossless archive

## Consequences

- Accessibility IDs for code/table actions are stable: `message UUID + source range + block kind`.
- Progressive streaming (Milestone 2) reuses the same document model with a mutable tail.
- Composer preview (Milestone 3) must use the same renderer so preview never diverges from final messages.
