import Foundation

// MARK: - Source range

/// UTF-16 unit offsets into the normalized Markdown source (`\r\n` → `\n`).
/// Used for stable block identity and future streaming tail tracking.
struct MarkdownSourceRange: Hashable, Sendable, Codable {
    var start: Int
    var end: Int

    var isEmpty: Bool { start >= end }

    func contains(_ other: MarkdownSourceRange) -> Bool {
        start <= other.start && end >= other.end
    }
}

// MARK: - Block kind & identity

enum MarkdownBlockKind: String, Hashable, Sendable, Codable {
    case prose
    case table
    case code
    case fallback
}

/// Stable identity for a rendered block.
///
/// Replaces transient segment ordinals such as `markdown.copy-code.3` so
/// accessibility IDs do not shift after a stream completes or when a message
/// is reopened from storage.
struct MarkdownBlockID: Hashable, Sendable {
    var messageID: UUID?
    var range: MarkdownSourceRange
    var kind: MarkdownBlockKind

    /// Deterministic accessibility / test identifier.
    ///
    /// Format: `markdown.<kind>.<messageUUID|orphan>.<start>-<end>`
    var accessibilityIdentifier: String {
        let messageKey = messageID?.uuidString.lowercased() ?? "orphan"
        return "markdown.\(kind.rawValue).\(messageKey).\(range.start)-\(range.end)"
    }

    /// Copy-control identifier for code blocks (keeps the historical prefix
    /// so e2e scripts can match either legacy ordinal or stable IDs).
    var copyCodeAccessibilityIdentifier: String {
        "markdown.copy-code.\(messageID?.uuidString.lowercased() ?? "orphan").\(range.start)-\(range.end)"
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
        /// `false` when the fence was never closed (streaming / truncated).
        isClosed: Bool
    )
    case fallback(text: String, range: MarkdownSourceRange)

    var kind: MarkdownBlockKind {
        switch self {
        case .prose: return .prose
        case .table: return .table
        case .code: return .code
        case .fallback: return .fallback
        }
    }

    var range: MarkdownSourceRange {
        switch self {
        case .prose(_, let range),
             .table(_, _, _, let range),
             .code(_, _, let range, _),
             .fallback(_, let range):
            return range
        }
    }

    func blockID(messageID: UUID?) -> MarkdownBlockID {
        MarkdownBlockID(messageID: messageID, range: range, kind: kind)
    }
}

// MARK: - Document

/// Immutable parse result. Raw Markdown remains the durable source of truth;
/// this document is derived, cacheable, and never persisted as authoritative.
struct MarkdownDocument: Hashable, Sendable {
    /// Normalized source (CRLF → LF).
    var source: String
    var blocks: [MarkdownBlock]
    /// When streaming, the unfinished suffix that is not yet a completed block.
    /// Production completed-message parses leave this `nil`.
    var incompleteTail: MarkdownSourceRange?
    var parserName: String

    static let empty = MarkdownDocument(
        source: "",
        blocks: [],
        incompleteTail: nil,
        parserName: "none"
    )

    func blockIDs(messageID: UUID?) -> [MarkdownBlockID] {
        blocks.map { $0.blockID(messageID: messageID) }
    }
}

// MARK: - UTF-16 helpers

enum MarkdownSourceIndex {
    /// UTF-16 offset of `index` in `string`.
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
