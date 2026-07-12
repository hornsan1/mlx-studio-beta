import Foundation

// MARK: - Source range

/// UTF-16 unit offsets into the normalized Markdown source (`\r\n` → `\n`).
struct MarkdownSourceRange: Hashable, Sendable, Codable {
    var start: Int
    var end: Int

    var isEmpty: Bool { start >= end }
}

// MARK: - Block kind & identity

enum MarkdownBlockKind: String, Hashable, Sendable, Codable {
    case prose
    case heading
    case listItem
    case taskItem
    case blockquote
    case thematicBreak
    case table
    case code
    case fallback
}

/// Stable identity for a rendered block.
///
/// While provisional (open fence, or last block during streaming), only
/// `(messageID, kind, range.start)` participates in equality so token growth
/// does not remount views or rotate AX IDs. When finalized, `range.end` is
/// included.
struct MarkdownBlockID: Hashable, Sendable {
    var messageID: UUID?
    var range: MarkdownSourceRange
    var kind: MarkdownBlockKind
    var isProvisional: Bool

    private var endMarker: String {
        isProvisional ? "open" : "\(range.end)"
    }

    var accessibilityIdentifier: String {
        let messageKey = messageID?.uuidString.lowercased() ?? "orphan"
        return "markdown.\(kind.rawValue).\(messageKey).\(range.start)-\(endMarker)"
    }

    var copyCodeAccessibilityIdentifier: String {
        let messageKey = messageID?.uuidString.lowercased() ?? "orphan"
        return "markdown.copy-code.\(messageKey).\(range.start)-\(endMarker)"
    }

    static func == (lhs: MarkdownBlockID, rhs: MarkdownBlockID) -> Bool {
        lhs.messageID == rhs.messageID
            && lhs.kind == rhs.kind
            && lhs.range.start == rhs.range.start
            && lhs.isProvisional == rhs.isProvisional
            && (lhs.isProvisional || lhs.range.end == rhs.range.end)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(messageID)
        hasher.combine(kind)
        hasher.combine(range.start)
        hasher.combine(isProvisional)
        if !isProvisional {
            hasher.combine(range.end)
        }
    }

    /// Open fence always provisional; while streaming the last block is too.
    static func id(
        messageID: UUID?,
        block: MarkdownBlock,
        isStreaming: Bool,
        isLastBlock: Bool = false
    ) -> MarkdownBlockID {
        let provisional: Bool = {
            if case .code(_, _, _, let closed) = block, !closed { return true }
            return isStreaming && isLastBlock
        }()
        return MarkdownBlockID(
            messageID: messageID,
            range: block.range,
            kind: block.kind,
            isProvisional: provisional
        )
    }
}

// MARK: - Table alignment

enum MarkdownTableAlignment: String, Hashable, Sendable, Codable {
    case leading
    case center
    case trailing
}

// MARK: - Blocks

enum MarkdownBlock: Hashable, Sendable {
    case prose(text: String, range: MarkdownSourceRange)
    case heading(level: Int, text: String, range: MarkdownSourceRange)
    case listItem(
        ordered: Bool,
        index: Int?,
        indentLevel: Int,
        text: String,
        range: MarkdownSourceRange
    )
    case taskItem(
        checked: Bool,
        indentLevel: Int,
        text: String,
        range: MarkdownSourceRange
    )
    case blockquote(text: String, quoteDepth: Int, range: MarkdownSourceRange)
    case thematicBreak(range: MarkdownSourceRange)
    case table(
        headers: [String],
        alignments: [MarkdownTableAlignment],
        rows: [[String]],
        range: MarkdownSourceRange
    )
    case code(
        language: String,
        body: String,
        range: MarkdownSourceRange,
        isClosed: Bool
    )
    case fallback(text: String, range: MarkdownSourceRange)

    var kind: MarkdownBlockKind {
        switch self {
        case .prose: return .prose
        case .heading: return .heading
        case .listItem: return .listItem
        case .taskItem: return .taskItem
        case .blockquote: return .blockquote
        case .thematicBreak: return .thematicBreak
        case .table: return .table
        case .code: return .code
        case .fallback: return .fallback
        }
    }

    var range: MarkdownSourceRange {
        switch self {
        case .prose(_, let range),
             .heading(_, _, let range),
             .listItem(_, _, _, _, let range),
             .taskItem(_, _, _, let range),
             .blockquote(_, _, let range),
             .thematicBreak(let range),
             .table(_, _, _, let range),
             .code(_, _, let range, _),
             .fallback(_, let range):
            return range
        }
    }
}

// MARK: - Document

/// Immutable parse result. Raw Markdown remains the durable source of truth.
struct MarkdownDocument: Hashable, Sendable {
    var source: String
    var blocks: [MarkdownBlock]
    var parserName: String

    static let empty = MarkdownDocument(source: "", blocks: [], parserName: "none")

    func blockIDs(messageID: UUID?, isStreaming: Bool = false) -> [MarkdownBlockID] {
        let last = blocks.indices.last
        return blocks.enumerated().map { index, block in
            MarkdownBlockID.id(
                messageID: messageID,
                block: block,
                isStreaming: isStreaming,
                isLastBlock: index == last
            )
        }
    }
}

// MARK: - UTF-16 helpers

enum MarkdownSourceIndex {
    static func utf16Offset(in string: String, of index: String.Index) -> Int {
        string.utf16.distance(from: string.startIndex, to: index)
    }

    static func range(
        in string: String,
        from start: String.Index,
        to end: String.Index
    ) -> MarkdownSourceRange {
        MarkdownSourceRange(
            start: utf16Offset(in: string, of: start),
            end: utf16Offset(in: string, of: end)
        )
    }

    static func substring(_ string: String, range: MarkdownSourceRange) -> String {
        let utf16 = string.utf16
        guard range.start >= 0,
              range.end <= utf16.count,
              range.start <= range.end
        else {
            return ""
        }
        let start = utf16.index(utf16.startIndex, offsetBy: range.start)
        let end = utf16.index(utf16.startIndex, offsetBy: range.end)
        guard let s = String.Index(start, within: string),
              let e = String.Index(end, within: string)
        else {
            return String(decoding: Array(utf16[start..<end]), as: UTF16.self)
        }
        return String(string[s..<e])
    }
}
