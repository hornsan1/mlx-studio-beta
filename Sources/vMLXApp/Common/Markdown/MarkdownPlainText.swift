import Foundation

/// Structure-aware plain-text rendering of a `MarkdownDocument` for copy/paste.
///
/// Phase A: `prose`, `table`, `code`, `fallback`.
/// Phase B: `heading`, `listItem`, `taskItem`, `blockquote`, `thematicBreak`
/// as a linear walk (no second grammar). List/task runs join with a single
/// newline; other block boundaries use a blank line.
enum MarkdownPlainText {
    /// Walk document blocks and emit a plain-text pasteboard payload.
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

    /// Parse `source` with the production lightweight parser, then render.
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
        case let .prose(text, _):
            return stripInlineMarkers(text)
        case let .fallback(text, _):
            return stripInlineMarkers(text)
        case let .heading(_, text, _):
            // Plain: heading body only (no ATX hashes). Level is a UI concern.
            return stripInlineMarkers(text)
        case let .listItem(ordered, index, indentLevel, text, _):
            let indent = String(repeating: "  ", count: max(indentLevel, 0))
            let marker: String
            if ordered {
                marker = "\(index ?? 1). "
            } else {
                marker = "- "
            }
            return indent + marker + stripInlineMarkers(text)
        case let .taskItem(checked, indentLevel, text, _):
            let indent = String(repeating: "  ", count: max(indentLevel, 0))
            let box = checked ? "[x]" : "[ ]"
            return indent + "- \(box) " + stripInlineMarkers(text)
        case let .blockquote(text, _, _):
            // Body text only; leading `>` chrome is a UI concern.
            return stripInlineMarkers(text)
        case .thematicBreak:
            return "---"
        case let .table(headers, _, rows, _):
            // Whole-message plain copy strips cell inline markers so TSV matches
            // the prose surface (per-table “Copy TSV” chrome still uses raw cells).
            let plainHeaders = headers.map(stripInlineMarkers)
            let plainRows = rows.map { $0.map(stripInlineMarkers) }
            return MarkdownTableClipboard.asTSV(headers: plainHeaders, rows: plainRows)
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
    ///   otherwise just `label`. Destinations may contain balanced `()`.
    /// - Images: `![alt](url)` → `alt`.
    /// - Code spans are masked before emphasis so `` `a_b_c` `` / snake_case
    ///   outside code are handled safely (code contents restored plain).
    /// - Emphasis uses simplified flanking rules so `snake_case`, `2*3*4`,
    ///   and `a * b * c` are not corrupted.
    ///
    /// **Limitations (Phase A):** nested/triple emphasis and multi-line
    /// emphasis are best-effort only — not a full CommonMark inline parser.
    /// Prefer a later inline AST / AttributedString reverse path if needed.
    static func stripInlineMarkers(_ text: String) -> String {
        // 1. Mask inline code spans so later emphasis passes cannot corrupt them.
        let (masked, codeSlots) = extractInlineCodeSpans(text)
        var result = masked

        // 2. Images / links with balanced-paren destinations.
        result = rewriteImagesAndLinks(result)

        // 3. Autolinks <https://…> / <mailto:…> (scheme case-insensitive).
        result = replaceMatches(
            in: result,
            pattern: #"<((?:https?|mailto):[^>\s]+)>"#,
            options: [.caseInsensitive],
            transform: { groups in groups[1] }
        )

        // 4. Strikethrough (double-tilde only).
        result = stripPairedDelimiter(result, delimiter: "~~", underscoreWordBoundary: false)

        // 5. Strong before emphasis so `**` is not partially eaten by `*`.
        result = stripPairedDelimiter(result, delimiter: "**", underscoreWordBoundary: false)
        result = stripPairedDelimiter(result, delimiter: "__", underscoreWordBoundary: true)

        // 6. Emphasis with flanking + alphanumeric-boundary rules so coding
        //    chat text (`2*3*4`, `snake_case`) is not treated as italic.
        result = stripPairedDelimiter(result, delimiter: "*", underscoreWordBoundary: true)
        result = stripPairedDelimiter(result, delimiter: "_", underscoreWordBoundary: true)

        // 7. Residual unclosed *double* markers only — never bare `*` / `_`
        //    (those would corrupt math and identifiers). Do not globally delete
        //    leftover single backticks after code-span extraction.
        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "```", with: "")

        // 8. Restore code-span contents (without backticks).
        result = restoreCodeSlots(result, codeSlots)
        return result
    }

    // MARK: - Code span mask

    private static let codeSlotOpen: Character = "\u{FFF0}"
    private static let codeSlotClose: Character = "\u{FFF1}"

    /// Extract `` `code` `` spans (single backticks, no newlines) into slots.
    private static func extractInlineCodeSpans(_ text: String) -> (String, [String]) {
        var slots: [String] = []
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "`" {
                let afterOpen = text.index(after: i)
                if let close = text[afterOpen...].firstIndex(of: "`") {
                    let content = String(text[afterOpen..<close])
                    // Reject empty or multi-line for this simple span form.
                    if !content.isEmpty, !content.contains(where: { $0 == "\n" || $0 == "\r" }) {
                        let idx = slots.count
                        slots.append(content)
                        out.append(codeSlotOpen)
                        out.append(contentsOf: String(idx))
                        out.append(codeSlotClose)
                        i = text.index(after: close)
                        continue
                    }
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return (out, slots)
    }

    private static func restoreCodeSlots(_ text: String, _ slots: [String]) -> String {
        guard !slots.isEmpty else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == codeSlotOpen {
                let afterOpen = text.index(after: i)
                if let close = text[afterOpen...].firstIndex(of: codeSlotClose) {
                    let idxStr = String(text[afterOpen..<close])
                    if let idx = Int(idxStr), slots.indices.contains(idx) {
                        out.append(contentsOf: slots[idx])
                        i = text.index(after: close)
                        continue
                    }
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    // MARK: - Links / images (balanced destinations)

    /// Rewrite `![alt](dest)` → `alt` and `[label](dest)` → plain form.
    /// Destinations use a balanced-paren scan so `)` inside the URL is kept.
    private static func rewriteImagesAndLinks(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            // Image: ![
            if text[i] == "!", text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "["
            {
                if let parsed = parseLinkLike(text, from: text.index(after: i), isImage: true) {
                    out.append(contentsOf: parsed.replacement)
                    i = parsed.end
                    continue
                }
            }
            // Link: [
            if text[i] == "[" {
                if let parsed = parseLinkLike(text, from: i, isImage: false) {
                    out.append(contentsOf: parsed.replacement)
                    i = parsed.end
                    continue
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    private struct LinkParse {
        var replacement: String
        var end: String.Index
    }

    /// `from` points at `[` of `[label](dest)` (images pass the `[` after `!`).
    private static func parseLinkLike(
        _ text: String,
        from openBracket: String.Index,
        isImage: Bool
    ) -> LinkParse? {
        guard text[openBracket] == "[" else { return nil }
        let labelStart = text.index(after: openBracket)
        guard let closeBracket = findUnescaped(text, character: "]", from: labelStart) else {
            return nil
        }
        let label = String(text[labelStart..<closeBracket])
        let afterBracket = text.index(after: closeBracket)
        guard afterBracket < text.endIndex, text[afterBracket] == "(" else {
            return nil
        }
        let destOpen = text.index(after: afterBracket)
        guard let (destRaw, afterDest) = scanLinkDestination(text, from: destOpen) else {
            return nil
        }

        if isImage {
            return LinkParse(replacement: label, end: afterDest)
        }

        let destination = firstURLToken(in: destRaw)
        if let url = MarkdownLinkPolicy.sanitizedURL(from: destination) {
            return LinkParse(
                replacement: "\(label) (\(url.absoluteString))",
                end: afterDest
            )
        }
        return LinkParse(replacement: label, end: afterDest)
    }

    /// Scan a Markdown link destination starting after `(`.
    /// Supports `<url>` form and balanced parentheses; ends at the matching `)`.
    private static func scanLinkDestination(
        _ text: String,
        from start: String.Index
    ) -> (String, String.Index)? {
        let i = start
        // Optional angle-bracket destination: <...>
        if i < text.endIndex, text[i] == "<" {
            let innerStart = text.index(after: i)
            guard let closeAngle = text[innerStart...].firstIndex(of: ">") else {
                return nil
            }
            let dest = String(text[innerStart..<closeAngle])
            var after = text.index(after: closeAngle)
            // Optional title + closing )
            while after < text.endIndex, text[after].isWhitespace {
                after = text.index(after: after)
            }
            // Skip optional quoted title.
            if after < text.endIndex, text[after] == "\"" || text[after] == "'" {
                let q = text[after]
                after = text.index(after: after)
                guard let endQ = text[after...].firstIndex(of: q) else { return nil }
                after = text.index(after: endQ)
                while after < text.endIndex, text[after].isWhitespace {
                    after = text.index(after: after)
                }
            }
            guard after < text.endIndex, text[after] == ")" else { return nil }
            return (dest, text.index(after: after))
        }

        // Bare destination with balanced parens.
        var depth = 1
        var destEnd = start
        var j = start
        while j < text.endIndex {
            let c = text[j]
            if c == "\\" {
                // Skip escaped character.
                let next = text.index(after: j)
                if next < text.endIndex {
                    j = text.index(after: next)
                    destEnd = j
                    continue
                }
            }
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 {
                    let dest = String(text[start..<j])
                    return (dest, text.index(after: j))
                }
            }
            j = text.index(after: j)
            destEnd = j
        }
        _ = destEnd
        return nil
    }

    private static func findUnescaped(
        _ text: String,
        character: Character,
        from start: String.Index
    ) -> String.Index? {
        var i = start
        while i < text.endIndex {
            if text[i] == "\\" {
                let next = text.index(after: i)
                if next < text.endIndex {
                    i = text.index(after: next)
                    continue
                }
            }
            if text[i] == character {
                return i
            }
            // Labels are single-line for this Phase A helper.
            if text[i] == "\n" || text[i] == "\r" {
                return nil
            }
            i = text.index(after: i)
        }
        return nil
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

    // MARK: - Emphasis / strong (flanking)

    /// Strip non-overlapping `delimiter…delimiter` pairs using simplified
    /// CommonMark-style flanking. When `underscoreWordBoundary` is true
    /// (single `*` / `_`, and `__`), openers may not sit after an alphanumeric
    /// and closers may not sit before one — preserving `snake_case` and `2*3*4`.
    private static func stripPairedDelimiter(
        _ text: String,
        delimiter: String,
        underscoreWordBoundary: Bool
    ) -> String {
        guard !delimiter.isEmpty else { return text }
        let dChars = Array(delimiter)
        let dLen = dChars.count
        let chars = Array(text)
        guard chars.count >= dLen * 2 else { return text }

        var out = [Character]()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if matchesDelimiter(chars, at: i, delimiter: dChars),
               isLeftFlanking(chars, at: i, length: dLen)
            {
                // Look for a matching closer.
                var j = i + dLen
                var found: Int?
                while j <= chars.count - dLen {
                    if matchesDelimiter(chars, at: j, delimiter: dChars),
                       isRightFlanking(chars, at: j, length: dLen)
                    {
                        if underscoreWordBoundary {
                            // Reject intraword underscore emphasis.
                            let openPrecededByAlnum = i > 0 && isASCIIAlphanumeric(chars[i - 1])
                            let closeFollowedByAlnum =
                                j + dLen < chars.count && isASCIIAlphanumeric(chars[j + dLen])
                            if openPrecededByAlnum || closeFollowedByAlnum {
                                j += 1
                                continue
                            }
                        }
                        // Interior must be non-empty.
                        if j > i + dLen {
                            found = j
                            break
                        }
                    }
                    j += 1
                }
                if let close = found {
                    // Emit interior only.
                    out.append(contentsOf: chars[(i + dLen)..<close])
                    i = close + dLen
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    private static func matchesDelimiter(
        _ chars: [Character],
        at index: Int,
        delimiter: [Character]
    ) -> Bool {
        guard index + delimiter.count <= chars.count else { return false }
        for k in 0..<delimiter.count {
            if chars[index + k] != delimiter[k] { return false }
        }
        // Prefer longer delimiters: when looking for single `*` / `_`, do not
        // treat the start of `**` / `__` as a single-char opener/closer.
        if delimiter.count == 1 {
            let d = delimiter[0]
            if d == "*" || d == "_" {
                if index + 1 < chars.count, chars[index + 1] == d {
                    return false
                }
                // Also avoid matching the second char of a double run as open.
                if index > 0, chars[index - 1] == d {
                    return false
                }
            }
        }
        return true
    }

    /// Simplified CommonMark left-flanking check for a delimiter run at `at`.
    private static func isLeftFlanking(_ chars: [Character], at: Int, length: Int) -> Bool {
        let afterIndex = at + length
        let after: Character? = afterIndex < chars.count ? chars[afterIndex] : nil
        if after == nil || isUnicodeWhitespace(after!) { return false }
        let before: Character? = at > 0 ? chars[at - 1] : nil
        if !isUnicodePunctuation(after!) { return true }
        return before == nil || isUnicodeWhitespace(before!) || isUnicodePunctuation(before!)
    }

    /// Simplified CommonMark right-flanking check for a delimiter run at `at`.
    private static func isRightFlanking(_ chars: [Character], at: Int, length: Int) -> Bool {
        let before: Character? = at > 0 ? chars[at - 1] : nil
        if before == nil || isUnicodeWhitespace(before!) { return false }
        let afterIndex = at + length
        let after: Character? = afterIndex < chars.count ? chars[afterIndex] : nil
        if !isUnicodePunctuation(before!) { return true }
        return after == nil || isUnicodeWhitespace(after!) || isUnicodePunctuation(after!)
    }

    private static func isASCIIAlphanumeric(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func isUnicodeWhitespace(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isUnicodePunctuation(_ c: Character) -> Bool {
        // CommonMark punctuation ≈ Unicode P* + ASCII punctuation set.
        c.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            || "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(c)
    }

    // MARK: - Regex helper

    /// Replace every match of `pattern` by transforming capture groups
    /// (`groups[0]` = full match, `groups[1…]` = captures). Right-to-left so
    /// UTF-16 `NSRange` offsets stay valid.
    private static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
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
