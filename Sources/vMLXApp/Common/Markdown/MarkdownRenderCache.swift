import Foundation

/// Source-keyed, bounded cache of parsed Markdown documents.
///
/// Parses are pure and can run off the main actor; the cache itself is an
/// actor so concurrent stream finalizations stay race-free.
///
/// Default capacity is **128** so long chat sessions retain more completed
/// message parses. Eviction costs a re-parse on next body evaluation.
actor MarkdownRenderCache {
    /// Default entry budget for long sessions (was 64).
    static let defaultCapacity = 128

    struct Key: Hashable, Sendable {
        var messageID: UUID?
        /// Normalized source participates in equality, so a hash collision can
        /// never return a document parsed from different Markdown bytes.
        var source: String
        var parserName: String
    }

    static let shared = MarkdownRenderCache()

    private var storage: [Key: MarkdownDocument] = [:]
    private var insertionOrder: [Key] = []
    private let capacity: Int

    init(capacity: Int = MarkdownRenderCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func document(for key: Key) -> MarkdownDocument? {
        storage[key]
    }

    func store(_ document: MarkdownDocument, for key: Key) {
        if storage[key] == nil {
            insertionOrder.append(key)
        }
        storage[key] = document
        evictIfNeeded()
    }

    /// Parse (or return cached) using the provided parser.
    func document(
        source: String,
        messageID: UUID?,
        parser: any MarkdownParser
    ) -> MarkdownDocument {
        let normalized = MarkdownParserSupport.normalizeNewlines(source)
        let key = Key(
            messageID: messageID,
            source: normalized,
            parserName: parser.name
        )
        if let cached = storage[key] {
            return cached
        }
        let parsed = parser.parse(normalized)
        store(parsed, for: key)
        return parsed
    }

    func removeAll() {
        storage.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }

    private func evictIfNeeded() {
        while storage.count > capacity, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}

enum MarkdownParserSupport {
    static func normalizeNewlines(_ input: String) -> String {
        input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Synchronous helper for SwiftUI views: parse with the production parser
    /// without requiring `await` on the main actor. Uses a process-wide
    /// non-actor cache for completed messages; streaming can switch to the
    /// actor later without changing call sites.
    static func parseSync(
        _ source: String,
        messageID: UUID? = nil,
        parser: any MarkdownParser = LightweightMarkdownParser.shared
    ) -> MarkdownDocument {
        SyncMarkdownRenderCache.shared.document(
            source: source,
            messageID: messageID,
            parser: parser
        )
    }

}

/// Main-thread-friendly bounded cache (SwiftUI body).
final class SyncMarkdownRenderCache: @unchecked Sendable {
    static let shared = SyncMarkdownRenderCache()

    private let lock = NSLock()
    private var storage: [MarkdownRenderCache.Key: MarkdownDocument] = [:]
    private var insertionOrder: [MarkdownRenderCache.Key] = []
    private let capacity: Int

    init(capacity: Int = MarkdownRenderCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func document(
        source: String,
        messageID: UUID?,
        parser: any MarkdownParser
    ) -> MarkdownDocument {
        let normalized = MarkdownParserSupport.normalizeNewlines(source)
        let key = MarkdownRenderCache.Key(
            messageID: messageID,
            source: normalized,
            parserName: parser.name
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[key] {
            return cached
        }
        let parsed = parser.parse(normalized)
        if storage[key] == nil {
            insertionOrder.append(key)
        }
        storage[key] = parsed
        while storage.count > capacity, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        return parsed
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        insertionOrder.removeAll()
    }
}
