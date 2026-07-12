import Foundation

/// Structure-aware plain-text rendering of a `MarkdownDocument` for copy/paste.
///
/// One linear walk over blocks. Inline markers use system
/// `AttributedString(markdown:)` (same engine as prose display) so we do not
/// maintain a second CommonMark-ish grammar for the clipboard.
enum MarkdownPlainText {
    static func render(_ document: MarkdownDocument) -> String {
        var chunks: [String] = []
        var previousWasListLike = false
        for block in document.blocks {
            let piece = render(block)
            let trimmed = trimBlockEdges(piece)
            if trimmed.isEmpty { continue }
            let listLike = isListLike(block)
            if !chunks.isEmpty {
                chunks.append(previousWasListLike && listLike ? "\n" : "\n\n")
            }
            chunks.append(trimmed)
            previousWasListLike = listLike
        }
        return chunks.joined()
    }

    static func render(source: String) -> String {
        render(LightweightMarkdownParser.shared.parse(source))
    }

    // MARK: - Blocks

    private static func isListLike(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .listItem, .taskItem: return true
        default: return false
        }
    }

    private static func render(_ block: MarkdownBlock) -> String {
        switch block {
        case let .prose(text, _), let .fallback(text, _):
            return stripInlineMarkers(text)
        case let .heading(_, text, _):
            return stripInlineMarkers(text)
        case let .listItem(ordered, index, indentLevel, text, _):
            let indent = String(repeating: "  ", count: max(indentLevel, 0))
            let marker = ordered ? "\(index ?? 1). " : "- "
            return indent + marker + stripInlineMarkers(text)
        case let .taskItem(checked, indentLevel, text, _):
            let indent = String(repeating: "  ", count: max(indentLevel, 0))
            let box = checked ? "[x]" : "[ ]"
            return indent + "- \(box) " + stripInlineMarkers(text)
        case let .blockquote(text, _, _):
            return stripInlineMarkers(text)
        case .thematicBreak:
            return "---"
        case let .table(headers, _, rows, _):
            let plainHeaders = headers.map(stripInlineMarkers)
            let plainRows = rows.map { $0.map(stripInlineMarkers) }
            return MarkdownTableClipboard.asTSV(headers: plainHeaders, rows: plainRows)
        case let .code(_, body, _, _):
            return body
        }
    }

    private static func trimBlockEdges(_ text: String) -> String {
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

    // MARK: - Inline

    /// Best-effort plain conversion of inline Markdown.
    ///
    /// Uses the same system Markdown engine as prose rendering, then walks
    /// attributed runs so allowed links keep a visible destination and
    /// disallowed schemes keep label only.
    static func stripInlineMarkers(_ text: String) -> String {
        guard let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return text
        }

        var out = ""
        for run in attr.runs {
            let piece = String(attr[run.range].characters)
            if let url = run.link {
                if MarkdownLinkPolicy.isAllowed(url) {
                    let dest = url.absoluteString
                    // Autolinks often surface the URL as the visible characters —
                    // don't double-append the destination.
                    if piece.isEmpty {
                        out += dest
                    } else if piece == dest
                        || piece.caseInsensitiveCompare(dest) == .orderedSame
                    {
                        out += piece
                    } else {
                        out += "\(piece) (\(dest))"
                    }
                } else {
                    out += piece
                }
            } else {
                out += piece
            }
        }
        return out
    }
}
