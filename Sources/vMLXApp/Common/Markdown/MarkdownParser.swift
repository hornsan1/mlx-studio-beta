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

    private static func appendProseBlocks(
        _ text: String,
        from start: String.Index,
        to end: String.Index,
        into output: inout [MarkdownBlock]
    ) {
        guard start < end else { return }
        let prose = String(text[start..<end])
        guard !prose.isEmpty else { return }

        let lines = prose.components(separatedBy: "\n")
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

        func flushProse() {
            guard let s = proseBufferStart, let e = proseBufferEnd, s < e else {
                proseBufferStart = nil
                proseBufferEnd = nil
                return
            }
            let value = String(text[s..<e])
            if !value.isEmpty {
                output.append(
                    .prose(
                        text: value,
                        range: MarkdownSourceIndex.range(in: text, from: s, to: e)
                    )
                )
            }
            proseBufferStart = nil
            proseBufferEnd = nil
        }

        while index < lines.count {
            if index + 1 < lines.count,
               let headers = parseTableRow(lines[index]),
               let alignments = parseTableDelimiter(
                lines[index + 1],
                expectedColumns: headers.count
               )
            {
                flushProse()
                let tableStart = lineStarts[index]
                index += 2

                var rows: [[String]] = []
                while index < lines.count, let cells = parseTableRow(lines[index]) {
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

            let lineStart = lineStarts[index]
            let lineEnd: String.Index
            if index + 1 < lines.count {
                lineEnd = lineStarts[index + 1]
            } else {
                lineEnd = end
            }
            if proseBufferStart == nil {
                proseBufferStart = lineStart
            }
            proseBufferEnd = lineEnd
            index += 1
        }
        flushProse()
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
