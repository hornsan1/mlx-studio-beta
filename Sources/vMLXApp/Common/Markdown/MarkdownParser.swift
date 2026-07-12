import Foundation

// MARK: - Protocol

/// Parser-independent entry point. Production block views consume
/// `MarkdownDocument` only — never a package-specific AST.
protocol MarkdownParser: Sendable {
    var name: String { get }
    func parse(_ source: String) -> MarkdownDocument
}

// MARK: - Production default

/// Default production parser: the existing fence + GFM table splitter, now
/// exposed behind `MarkdownParser` and emitting stable source ranges.
///
/// Kept free of third-party packages so clean checkouts stay reproducible.
/// A future GFM AST adapter can replace this without changing render views.
struct LightweightMarkdownParser: MarkdownParser, Sendable {
    static let shared = LightweightMarkdownParser()

    let name = "lightweight-gfm-lite"

    func parse(_ source: String) -> MarkdownDocument {
        let text = MarkdownParserSupport.normalizeNewlines(source)
        let blocks = Self.split(text)
        return MarkdownDocument(
            source: text,
            blocks: blocks,
            incompleteTail: nil,
            parserName: name
        )
    }

    // MARK: Splitter

    private static func split(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var i = text.startIndex
        var proseStart = text.startIndex

        while i < text.endIndex {
            if let fence = detectFence(at: i, in: text) {
                if proseStart < i {
                    appendProseBlocks(
                        text,
                        from: proseStart,
                        to: i,
                        into: &out
                    )
                }

                let fenceStart = i
                let afterFence = text.index(i, offsetBy: fence.marker.count)
                var langEnd = afterFence
                while langEnd < text.endIndex, text[langEnd] != "\n" {
                    langEnd = text.index(after: langEnd)
                }
                let language = String(text[afterFence..<langEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let bodyStart = langEnd < text.endIndex
                    ? text.index(after: langEnd)
                    : langEnd

                var search = bodyStart
                var bodyEnd = text.endIndex
                var closeEnd = text.endIndex
                var isClosed = false
                while search < text.endIndex {
                    if text[search...].hasPrefix(fence.marker) {
                        // Closing fence must be at line start (or start of remaining text).
                        let atLineStart = search == text.startIndex
                            || text[text.index(before: search)] == "\n"
                        if atLineStart {
                            bodyEnd = search
                            closeEnd = text.index(search, offsetBy: fence.marker.count)
                            isClosed = true
                            break
                        }
                    }
                    search = text.index(after: search)
                }

                let body = String(text[bodyStart..<bodyEnd])
                let range = MarkdownSourceIndex.range(
                    in: text,
                    from: fenceStart,
                    to: isClosed ? closeEnd : text.endIndex
                )
                out.append(
                    .code(
                        language: language,
                        body: body,
                        range: range,
                        isClosed: isClosed
                    )
                )
                i = closeEnd
                proseStart = i
            } else {
                i = text.index(after: i)
            }
        }

        if proseStart < text.endIndex {
            appendProseBlocks(
                text,
                from: proseStart,
                to: text.endIndex,
                into: &out
            )
        }
        return out
    }

    /// Max list nesting depth (indentLevel 0…5) — K12.
    private static let maxListIndentLevel = 5

    private static func appendProseBlocks(
        _ text: String,
        from start: String.Index,
        to end: String.Index,
        into output: inout [MarkdownBlock]
    ) {
        guard start < end else { return }
        let region = String(text[start..<end])
        guard !region.isEmpty else { return }

        let lines = region.components(separatedBy: "\n")
        // Map each line to its absolute start index in `text`.
        var lineStarts: [String.Index] = []
        var cursor = start
        for (idx, line) in lines.enumerated() {
            lineStarts.append(cursor)
            if idx + 1 < lines.count {
                cursor = text.index(cursor, offsetBy: line.count)
                if cursor < end, text[cursor] == "\n" {
                    cursor = text.index(after: cursor)
                }
            }
        }

        var proseBufferStart: String.Index?
        var proseBufferEnd: String.Index?
        var index = 0
        // Per-indentLevel ordered counters; -1 means "unset after reset".
        // (0 is a valid source start index for `0.` items.)
        var orderedCounters = Array(repeating: -1, count: maxListIndentLevel + 1)

        func lineEndIndex(at lineIndex: Int) -> String.Index {
            if lineIndex + 1 < lines.count {
                return lineStarts[lineIndex + 1]
            }
            return end
        }

        func flushProse() {
            guard let s = proseBufferStart, let e = proseBufferEnd, s < e else {
                proseBufferStart = nil
                proseBufferEnd = nil
                return
            }
            let value = String(text[s..<e])
            proseBufferStart = nil
            proseBufferEnd = nil
            // Never emit whitespace-only prose (trailing `\n` after headings/
            // lists, blank gaps between structural blocks, etc.).
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Gap still interrupts ordered-list sequences.
                orderedCounters = Array(repeating: -1, count: maxListIndentLevel + 1)
                return
            }
            output.append(
                .prose(
                    text: value,
                    range: MarkdownSourceIndex.range(in: text, from: s, to: e)
                )
            )
            // Non-list interruption → reset ordered counters.
            orderedCounters = Array(repeating: -1, count: maxListIndentLevel + 1)
        }

        func resetOrderedCounters() {
            orderedCounters = Array(repeating: -1, count: maxListIndentLevel + 1)
        }

        func emitStructural(_ block: MarkdownBlock) {
            flushProse()
            output.append(block)
        }

        func nextNonBlankIndex(from lineIndex: Int) -> Int? {
            var i = lineIndex
            while i < lines.count {
                if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    return i
                }
                i += 1
            }
            return nil
        }

        while index < lines.count {
            let line = lines[index]

            // Blank line handling:
            // - Loose lists: blanks between list/task items are skipped (no reset).
            // - Standalone blanks (not mid-prose) are skipped — no whitespace-only
            //   prose blocks between headings/structural runs or trailing `\n`.
            // - Blanks mid-prose are kept so multi-paragraph prose stays one block.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let next = nextNonBlankIndex(from: index + 1),
                   parseListOrTaskLine(lines[next]) != nil
                {
                    index += 1
                    continue
                }
                if proseBufferStart != nil {
                    proseBufferEnd = lineEndIndex(at: index)
                }
                index += 1
                continue
            }

            // 1. GFM table (header + delimiter)
            if index + 1 < lines.count,
               let headers = parseTableRow(lines[index]),
               let alignments = parseTableDelimiter(
                lines[index + 1],
                expectedColumns: headers.count
               )
            {
                flushProse()
                resetOrderedCounters()
                let tableStart = lineStarts[index]
                index += 2

                var rows: [[String]] = []
                while index < lines.count, let cells = parseTableRow(lines[index]) {
                    // Blank lines end the table.
                    if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        break
                    }
                    rows.append(normalizeTableRow(cells, columnCount: headers.count))
                    index += 1
                }

                let tableEnd: String.Index
                if index < lines.count {
                    tableEnd = lineStarts[index]
                } else {
                    tableEnd = end
                }

                output.append(
                    .table(
                        headers: headers,
                        alignments: alignments,
                        rows: rows,
                        range: MarkdownSourceIndex.range(
                            in: text,
                            from: tableStart,
                            to: tableEnd
                        )
                    )
                )
                continue
            }

            // 2. Thematic break
            if isThematicBreak(line) {
                let range = MarkdownSourceIndex.range(
                    in: text,
                    from: lineStarts[index],
                    to: lineEndIndex(at: index)
                )
                emitStructural(.thematicBreak(range: range))
                resetOrderedCounters()
                index += 1
                continue
            }

            // 3. ATX heading
            if let heading = parseATXHeading(line) {
                let range = MarkdownSourceIndex.range(
                    in: text,
                    from: lineStarts[index],
                    to: lineEndIndex(at: index)
                )
                emitStructural(
                    .heading(level: heading.level, text: heading.text, range: range)
                )
                resetOrderedCounters()
                index += 1
                continue
            }

            // 4. Blockquote run
            if blockquoteDepth(line) != nil {
                flushProse()
                resetOrderedCounters()
                let quoteStart = lineStarts[index]
                var quoteSourceLines: [String] = []
                var depths: [Int] = []
                while index < lines.count, let d = blockquoteDepth(lines[index]) {
                    quoteSourceLines.append(lines[index])
                    depths.append(d)
                    index += 1
                }
                let minDepth = depths.min() ?? 1
                // Strip minDepth `>` markers; deeper nesting remains as text prefixes.
                let bodies = quoteSourceLines.map {
                    stripBlockquotePrefix($0, depth: minDepth)
                }
                let quoteText = bodies.joined(separator: "\n")
                let quoteEnd: String.Index
                if index < lines.count {
                    quoteEnd = lineStarts[index]
                } else {
                    quoteEnd = end
                }
                output.append(
                    .blockquote(
                        text: quoteText,
                        quoteDepth: minDepth,
                        range: MarkdownSourceIndex.range(
                            in: text,
                            from: quoteStart,
                            to: quoteEnd
                        )
                    )
                )
                continue
            }

            // 5. List / task item
            if let item = parseListOrTaskLine(line) {
                flushProse()
                let range = MarkdownSourceIndex.range(
                    in: text,
                    from: lineStarts[index],
                    to: lineEndIndex(at: index)
                )
                let level = item.indentLevel
                // Child levels restart when returning to a shallower sibling.
                if level < maxListIndentLevel {
                    for i in (level + 1)...maxListIndentLevel {
                        orderedCounters[i] = -1
                    }
                }

                switch item.kind {
                case .task(let checked):
                    output.append(
                        .taskItem(
                            checked: checked,
                            indentLevel: level,
                            text: item.text,
                            range: range
                        )
                    )
                case .unordered:
                    output.append(
                        .listItem(
                            ordered: false,
                            index: nil,
                            indentLevel: level,
                            text: item.text,
                            range: range
                        )
                    )
                case .ordered(let sourceIndex):
                    // First item after reset uses the source integer as-is
                    // (including `0.`); subsequent items at this level +1.
                    let assigned: Int
                    if orderedCounters[level] < 0 {
                        assigned = sourceIndex
                    } else {
                        assigned = orderedCounters[level] + 1
                    }
                    orderedCounters[level] = assigned
                    output.append(
                        .listItem(
                            ordered: true,
                            index: assigned,
                            indentLevel: level,
                            text: item.text,
                            range: range
                        )
                    )
                }
                index += 1
                continue
            }

            // 6. Accumulate prose
            let lineStart = lineStarts[index]
            let lineEnd = lineEndIndex(at: index)
            if proseBufferStart == nil {
                proseBufferStart = lineStart
            }
            proseBufferEnd = lineEnd
            index += 1
        }
        flushProse()
    }

    // MARK: - Structural line detectors

    private static func isThematicBreak(_ line: String) -> Bool {
        // Optional indent (≤3 spaces), then 3+ of -, *, or _ with optional
        // spaces between — and nothing else. Must not be a list marker line.
        var s = line
        var leadingSpaces = 0
        while s.first == " " && leadingSpaces < 3 {
            s.removeFirst()
            leadingSpaces += 1
        }
        // Tabs before a break are uncommon; treat as not a thematic break so
        // tab-indented list markers are preferred.
        guard let first = s.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        let marker = first
        var count = 0
        for ch in s {
            if ch == marker {
                count += 1
            } else if ch == " " || ch == "\t" {
                continue
            } else {
                return false
            }
        }
        return count >= 3
    }

    private static func parseATXHeading(_ line: String) -> (level: Int, text: String)? {
        var s = line
        // Allow up to 3 spaces of indent (GFM).
        var leadingSpaces = 0
        while s.first == " " && leadingSpaces < 3 {
            s.removeFirst()
            leadingSpaces += 1
        }
        guard s.first == "#" else { return nil }
        var level = 0
        while s.first == "#", level < 6 {
            s.removeFirst()
            level += 1
        }
        // Must be 1…6 hashes followed by whitespace (or end → empty heading).
        guard level >= 1, level <= 6 else { return nil }
        if s.isEmpty {
            return (level, "")
        }
        guard s.first == " " || s.first == "\t" else { return nil }
        while s.first == " " || s.first == "\t" {
            s.removeFirst()
        }
        // Strip optional closing sequence of trailing hashes.
        var text = String(s)
        if let hashRange = text.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
            text = String(text[..<hashRange.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func blockquoteDepth(_ line: String) -> Int? {
        var s = line
        // Optional up to 3 leading spaces before first `>`.
        var leadingSpaces = 0
        while s.first == " " && leadingSpaces < 3 {
            s.removeFirst()
            leadingSpaces += 1
        }
        guard s.first == ">" else { return nil }
        var depth = 0
        while s.first == ">" {
            depth += 1
            s.removeFirst()
            // Optional single space after each `>` (GFM).
            if s.first == " " {
                s.removeFirst()
            }
        }
        return depth > 0 ? depth : nil
    }

    /// Strip `depth` levels of `>` markers from a blockquote line for body text.
    private static func stripBlockquotePrefix(_ line: String, depth: Int) -> String {
        var s = line
        var leadingSpaces = 0
        while s.first == " " && leadingSpaces < 3 {
            s.removeFirst()
            leadingSpaces += 1
        }
        var remaining = depth
        while remaining > 0, s.first == ">" {
            s.removeFirst()
            if s.first == " " {
                s.removeFirst()
            }
            remaining -= 1
        }
        return String(s)
    }

    private enum ListItemKind {
        case unordered
        case ordered(sourceIndex: Int)
        case task(checked: Bool)
    }

    private struct ParsedListLine {
        var kind: ListItemKind
        var indentLevel: Int
        var text: String
    }

    private static func parseListOrTaskLine(_ line: String) -> ParsedListLine? {
        let (indentLevel, rest) = splitListIndent(line)
        guard !rest.isEmpty else { return nil }

        // Ordered: digits + `.` or `)` + whitespace + content
        if let ordered = parseOrderedMarker(rest) {
            return ParsedListLine(
                kind: .ordered(sourceIndex: ordered.index),
                indentLevel: indentLevel,
                text: ordered.text
            )
        }

        // Unordered / task: -, *, or + followed by whitespace
        guard let marker = rest.first,
              marker == "-" || marker == "*" || marker == "+"
        else {
            return nil
        }
        var after = rest.dropFirst()
        guard let sp = after.first, sp == " " || sp == "\t" else { return nil }
        after = after.dropFirst()
        // Consume extra spaces after marker.
        while after.first == " " || after.first == "\t" {
            after = after.dropFirst()
        }
        let content = String(after)

        // Task checkbox: [ ] / [x] / [X]
        if content.count >= 3,
           content.first == "[",
           let closeIdx = content.index(content.startIndex, offsetBy: 2, limitedBy: content.endIndex),
           content[closeIdx] == "]"
        {
            let mid = content[content.index(after: content.startIndex)]
            if mid == " " || mid == "x" || mid == "X" {
                var body = content[content.index(after: closeIdx)...]
                if body.first == " " || body.first == "\t" {
                    body = body.dropFirst()
                }
                while body.first == " " || body.first == "\t" {
                    body = body.dropFirst()
                }
                let checked = (mid == "x" || mid == "X")
                return ParsedListLine(
                    kind: .task(checked: checked),
                    indentLevel: indentLevel,
                    text: String(body)
                )
            }
        }

        return ParsedListLine(
            kind: .unordered,
            indentLevel: indentLevel,
            text: content
        )
    }

    /// 2 spaces or 1 tab → +1 indentLevel; depth capped at `maxListIndentLevel`.
    /// Odd leftover spaces are absorbed (model-output tolerant) so markers
    /// still parse after 3-space indents common in LLM output.
    private static func splitListIndent(_ line: String) -> (level: Int, rest: String) {
        var level = 0
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\t" {
                level += 1
                i = line.index(after: i)
            } else if ch == " " {
                var spaces = 0
                var j = i
                while j < line.endIndex, line[j] == " " {
                    spaces += 1
                    j = line.index(after: j)
                }
                level += spaces / 2
                i = j
            } else {
                break
            }
        }
        let capped = min(level, maxListIndentLevel)
        return (capped, String(line[i...]))
    }

    private static func parseOrderedMarker(
        _ rest: String
    ) -> (index: Int, text: String)? {
        var i = rest.startIndex
        var digits = ""
        while i < rest.endIndex, rest[i].isNumber, digits.count < 9 {
            digits.append(rest[i])
            i = rest.index(after: i)
        }
        guard !digits.isEmpty, i < rest.endIndex else { return nil }
        let punct = rest[i]
        guard punct == "." || punct == ")" else { return nil }
        i = rest.index(after: i)
        guard i < rest.endIndex, rest[i] == " " || rest[i] == "\t" else { return nil }
        i = rest.index(after: i)
        while i < rest.endIndex, rest[i] == " " || rest[i] == "\t" {
            i = rest.index(after: i)
        }
        guard let value = Int(digits), value >= 0 else { return nil }
        return (value, String(rest[i...]))
    }

    private struct FenceMarker {
        let marker: String
    }

    /// Detects ``` or ~~~ fences of length ≥ 3.
    private static func detectFence(at index: String.Index, in text: String) -> FenceMarker? {
        guard index < text.endIndex else { return nil }
        let ch = text[index]
        guard ch == "`" || ch == "~" else { return nil }
        var end = index
        var count = 0
        while end < text.endIndex, text[end] == ch {
            count += 1
            end = text.index(after: end)
        }
        guard count >= 3 else { return nil }
        // Only treat as a fence when at line start.
        let atLineStart = index == text.startIndex
            || text[text.index(before: index)] == "\n"
        guard atLineStart else { return nil }
        return FenceMarker(marker: String(repeating: String(ch), count: count))
    }

    // MARK: - Table helpers (unchanged semantics from MarkdownView)

    private static func parseTableDelimiter(
        _ line: String,
        expectedColumns: Int
    ) -> [MarkdownTableAlignment]? {
        guard let cells = parseTableRow(line), cells.count == expectedColumns else {
            return nil
        }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            guard let alignment = parseTableAlignment(cell) else { return nil }
            alignments.append(alignment)
        }
        return alignments
    }

    private static func parseTableAlignment(_ cell: String) -> MarkdownTableAlignment? {
        var marker = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingColon = marker.hasPrefix(":")
        if leadingColon { marker.removeFirst() }
        let trailingColon = marker.hasSuffix(":")
        if trailingColon { marker.removeLast() }
        guard marker.count >= 3, marker.allSatisfy({ $0 == "-" }) else { return nil }

        switch (leadingColon, trailingColon) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        var row = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.contains("|") else { return nil }
        if row.first == "|" { row.removeFirst() }
        if row.last == "|" { row.removeLast() }
        guard !row.isEmpty else { return nil }

        var cells: [String] = []
        var cell = ""
        var escaping = false
        var inCodeSpan = false

        for character in row {
            if escaping {
                if character == "|" || character == "\\" {
                    cell.append(character)
                } else {
                    cell.append("\\")
                    cell.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "`" {
                inCodeSpan.toggle()
                cell.append(character)
            } else if character == "|" && !inCodeSpan {
                cells.append(cell.trimmingCharacters(in: .whitespacesAndNewlines))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaping { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespacesAndNewlines))
        return cells
    }

    private static func normalizeTableRow(_ cells: [String], columnCount: Int) -> [String] {
        var normalized = Array(cells.prefix(columnCount))
        if normalized.count < columnCount {
            normalized.append(
                contentsOf: Array(repeating: "", count: columnCount - normalized.count)
            )
        }
        return normalized
    }
}
