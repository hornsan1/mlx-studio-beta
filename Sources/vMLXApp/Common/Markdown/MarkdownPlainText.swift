import Foundation

/// Structure-aware plain-text rendering of a `MarkdownDocument` for copy/paste.
///
/// Phase A covers existing block kinds only (`prose`, `table`, `code`, `fallback`).
/// Heading / list / quote / task / break rules land in a later phase after the
/// structural document model expands.
enum MarkdownPlainText {
    /// Walk document blocks and emit a plain-text pasteboard payload.
    static func render(_ document: MarkdownDocument) -> String {
        var chunks: [String] = []
        for block in document.blocks {
            let piece = render(block)
            let trimmed = trimBlockEdges(piece)
            if trimmed.isEmpty { continue }
            chunks.append(trimmed)
        }
        return chunks.joined(separator: "\n\n")
    }

    /// Parse `source` with the production lightweight parser, then render.
    static func render(source: String) -> String {
        render(LightweightMarkdownParser.shared.parse(source))
    }

    // MARK: - Blocks

    private static func render(_ block: MarkdownBlock) -> String {
        switch block {
        case let .prose(text, _):
            return stripInlineMarkers(text)
        case let .fallback(text, _):
            return stripInlineMarkers(text)
        case let .table(headers, _, rows, _):
            return MarkdownTableClipboard.asTSV(headers: headers, rows: rows)
        case let .code(_, body, _, _):
            // Raw body only — no fence markers or language tag.
            return body
        }
    }

    private static func trimBlockEdges(_ text: String) -> String {
        // Drop leading/trailing newlines so block joins stay consistent, but
        // keep internal newlines and trailing spaces inside code/TSV cells.
        var start = text.startIndex
        var end = text.endIndex
        while start < end, text[start] == "\n" || text[start] == "\r" {
            start = text.index(after: start)
        }
        while end > start {
            let prev = text.index(before: end)
            if text[prev] == "\n" || text[prev] == "\r" {
                end = prev
            } else {
                break
            }
        }
        return String(text[start..<end])
    }

    // MARK: - Inline strip

    /// Strip common Markdown inline markers while keeping readable text.
    ///
    /// - Links: `[label](url)` → `label (url)` when the scheme is allowed,
    ///   otherwise just `label`.
    /// - Images: `![alt](url)` → `alt`.
    /// - Emphasis / code spans: drop `**` / `__` / `*` / `_` / `~~` / `` ` `` wrappers.
    static func stripInlineMarkers(_ text: String) -> String {
        var result = text

        // Images first so `![alt](url)` is not treated as a link.
        result = replaceMatches(
            in: result,
            pattern: #"!\[([^\]]*)\]\([^)]*\)"#,
            transform: { groups in groups[1] }
        )

        // Explicit links: keep label; append allowed absolute destinations.
        result = replaceMatches(
            in: result,
            pattern: #"\[([^\]]+)\]\(([^)]*)\)"#,
            transform: { groups in
                let label = groups[1]
                let destination = firstURLToken(in: groups[2])
                if let url = MarkdownLinkPolicy.sanitizedURL(from: destination) {
                    return "\(label) (\(url.absoluteString))"
                }
                return label
            }
        )

        // Autolinks <https://…> / <mailto:…>
        result = replaceMatches(
            in: result,
            pattern: #"<((?:https?|mailto):[^>\s]+)>"#,
            transform: { groups in groups[1] }
        )

        // Inline code spans (non-greedy single backticks).
        result = replaceMatches(
            in: result,
            pattern: #"`([^`\n]+)`"#,
            transform: { groups in groups[1] }
        )

        // Strikethrough.
        result = replaceMatches(
            in: result,
            pattern: #"~~([^~\n]+)~~"#,
            transform: { groups in groups[1] }
        )

        // Bold before italic so `**` is not partially eaten by `*`.
        result = replaceMatches(
            in: result,
            pattern: #"\*\*([^*\n]+)\*\*"#,
            transform: { groups in groups[1] }
        )
        result = replaceMatches(
            in: result,
            pattern: #"__([^_\n]+)__"#,
            transform: { groups in groups[1] }
        )

        // Italic.
        result = replaceMatches(
            in: result,
            pattern: #"\*([^*\n]+)\*"#,
            transform: { groups in groups[1] }
        )
        result = replaceMatches(
            in: result,
            pattern: #"_([^_\n]+)_"#,
            transform: { groups in groups[1] }
        )

        // Residual unclosed markers that the naive strip above leaves behind.
        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "`", with: "")

        return result
    }

    /// Destination side of `[label](dest "title")` — first whitespace-delimited token.
    private static func firstURLToken(in raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(
            whereSeparator: { $0.isWhitespace }
        ).first else {
            return ""
        }
        return String(token)
    }

    /// Replace every match of `pattern` by transforming capture groups
    /// (`groups[0]` = full match, `groups[1…]` = captures). Right-to-left so
    /// UTF-16 `NSRange` offsets stay valid.
    private static func replaceMatches(
        in text: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                if r.location == NSNotFound {
                    groups.append("")
                } else if let swiftRange = Range(r, in: result) {
                    groups.append(String(result[swiftRange]))
                } else {
                    groups.append("")
                }
            }
            result.replaceSubrange(fullRange, with: transform(groups))
        }
        return result
    }
}
