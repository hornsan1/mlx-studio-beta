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
///
/// While **provisional** (open fence or streaming terminal-growing block),
/// identity is **end-invariant**: only `range.start` participates in equality
/// and the accessibility string uses a fixed `…-open` suffix so token appends
/// do not remount views or rotate AX IDs.
struct MarkdownBlockID: Hashable, Sendable {
    var messageID: UUID?
    var range: MarkdownSourceRange
    var kind: MarkdownBlockKind
    /// `true` when the block is still growing (open code fence or streaming
    /// terminal block). Accessibility / ForEach identity ignores `range.end`.
    var isProvisional: Bool

    init(
        messageID: UUID?,
        range: MarkdownSourceRange,
        kind: MarkdownBlockKind,
        isProvisional: Bool = false
    ) {
        self.messageID = messageID
        self.range = range
        self.kind = kind
        self.isProvisional = isProvisional
    }

    /// End marker used in accessibility / copy identifiers.
    /// Provisional → `"open"`; finalized → decimal `range.end`.
    private var endMarker: String {
        isProvisional ? "open" : "\(range.end)"
    }

    /// Deterministic accessibility / test identifier.
    ///
    /// Format:
    /// - Provisional: `markdown.<kind>.<messageUUID|orphan>.<start>-open`
    /// - Finalized:   `markdown.<kind>.<messageUUID|orphan>.<start>-<end>`
    var accessibilityIdentifier: String {
        let messageKey = messageID?.uuidString.lowercased() ?? "orphan"
        return "markdown.\(kind.rawValue).\(messageKey).\(range.start)-\(endMarker)"
    }

    /// Copy-control identifier for code blocks (keeps the historical prefix
    /// so e2e scripts can match either legacy ordinal or stable IDs).
    var copyCodeAccessibilityIdentifier: String {
        let messageKey = messageID?.uuidString.lowercased() ?? "orphan"
        return "markdown.copy-code.\(messageKey).\(range.start)-\(endMarker)"
    }

    // MARK: Hashable (end-invariant while provisional)

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

    // MARK: Factory

    /// Normative provisional predicate (K13):
    /// open code fence **or** streaming terminal-growing block.
    ///
    /// - Parameter source: **Must** be the parse that produced `block.range`
    ///   (typically `document.source`), never live stream text ahead of reparse.
    /// - Parameter isLastStableBlock: when `true` while streaming, treat the
    ///   last rendered stable block as provisional even if a mismatched source
    ///   string would fail the `range.end == source.count` check.
    static func isProvisional(
        block: MarkdownBlock,
        source: String,
        isStreaming: Bool,
        isLastStableBlock: Bool = false
    ) -> Bool {
        if case .code(_, _, _, let isClosed) = block, !isClosed {
            return true
        }
        if isStreaming {
            // Terminal-growing against the parse basis, or last stable block
            // while the stream is still live (defense against source mismatch).
            if isLastStableBlock || block.range.end == source.utf16.count {
                return true
            }
        }
        return false
    }

    /// Build a block ID with the correct provisional flag for streaming.
    ///
    /// - Parameters:
    ///   - source: normalized **document** source that owns `block.range`
    ///     (UTF-16 length basis). Do not pass live text that outruns the parse.
    ///   - isStreaming: true for in-flight assistant bubbles / MarkdownStreamingView.
    ///   - isLastStableBlock: true when this is the last entry in the streaming
    ///     stable-blocks list (keeps terminal identity provisional across throttle).
    static func id(
        messageID: UUID?,
        block: MarkdownBlock,
        source: String,
        isStreaming: Bool,
        isLastStableBlock: Bool = false
    ) -> MarkdownBlockID {
        MarkdownBlockID(
            messageID: messageID,
            range: block.range,
            kind: block.kind,
            isProvisional: isProvisional(
                block: block,
                source: source,
                isStreaming: isStreaming,
                isLastStableBlock: isLastStableBlock
            )
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

    /// Convenience ID for completed (non-streaming) renders.
    /// Open fences still mark provisional so copy IDs stay end-invariant.
    ///
    /// - Parameter source: parse basis for ranges (`MarkdownDocument.source`).
    ///   Required so terminal-growing checks are not accidentally evaluated
    ///   against an empty string.
    func blockID(messageID: UUID?, source: String, isStreaming: Bool = false) -> MarkdownBlockID {
        MarkdownBlockID.id(
            messageID: messageID,
            block: self,
            source: source,
            isStreaming: isStreaming
        )
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

    func blockIDs(messageID: UUID?, isStreaming: Bool = false) -> [MarkdownBlockID] {
        blocks.map {
            MarkdownBlockID.id(
                messageID: messageID,
                block: $0,
                source: source,
                isStreaming: isStreaming
            )
        }
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
