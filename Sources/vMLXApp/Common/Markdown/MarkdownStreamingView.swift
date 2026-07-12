import SwiftUI
import vMLXTheme

/// Progressive Markdown renderer for in-flight assistant streams.
///
/// Completed blocks render immediately via the shared document model.
/// Only the mutable tail stays in typewriter form so layout does not thrash
/// on every token. When `isStreaming` becomes false, the full document is
/// shown without replacing earlier block identities.
struct MarkdownStreamingView: View {
    let text: String
    var messageID: UUID? = nil
    var isStreaming: Bool = true

    /// Throttle reparses during high-token-rate local generation.
    @State private var renderedSource: String = ""
    @State private var document: MarkdownDocument = .empty
    @State private var parseTask: Task<Void, Never>?
    @State private var lastParseAt: Date = .distantPast

    private let minReparseInterval: TimeInterval = 0.08

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if isStreaming {
                streamingBody
            } else {
                MarkdownView(text: text, messageID: messageID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { scheduleParse(force: true) }
        .onChange(of: text) { _, _ in scheduleParse(force: false) }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                parseTask?.cancel()
                document = MarkdownParserSupport.parseSync(text, messageID: messageID)
                renderedSource = text
            }
        }
        .onDisappear { parseTask?.cancel() }
    }

    @ViewBuilder
    private var streamingBody: some View {
        let split = StreamingMarkdownSplit.split(document: document, fullSource: text)
        let source = MarkdownParserSupport.normalizeNewlines(text)
        // Key by end-invariant MarkdownBlockID (not raw range) so provisional
        // blocks keep identity while range.end grows.
        ForEach(
            split.stableBlocks.map { block in
                IdentifiedMarkdownBlock(
                    id: MarkdownBlockID.id(
                        messageID: messageID,
                        block: block,
                        source: source,
                        isStreaming: true
                    ),
                    block: block
                )
            }
        ) { item in
            MarkdownBlockView(
                block: item.block,
                messageID: messageID,
                source: source,
                isStreaming: true
            )
        }
        if !split.tail.isEmpty {
            StreamingTextView(text: split.tail, isStreaming: true)
                .accessibilityIdentifier(
                    "markdown.stream-tail.\(messageID?.uuidString.lowercased() ?? "orphan")"
                )
        }
    }

    private func scheduleParse(force: Bool) {
        parseTask?.cancel()
        let source = text
        let msgID = messageID
        let delay: UInt64 = force ? 0 : 40_000_000
        parseTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            let now = Date()
            if !force, now.timeIntervalSince(lastParseAt) < minReparseInterval {
                try? await Task.sleep(nanoseconds: UInt64(minReparseInterval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            let parsed = await Task.detached(priority: .userInitiated) {
                LightweightMarkdownParser.shared.parse(source)
            }.value
            guard !Task.isCancelled else { return }
            document = parsed
            renderedSource = source
            lastParseAt = Date()
            _ = msgID
        }
    }
}

/// ForEach carrier so block identity is `MarkdownBlockID` (Hashable end-invariant
/// while provisional), not the growing source range alone.
private struct IdentifiedMarkdownBlock: Identifiable {
    let id: MarkdownBlockID
    let block: MarkdownBlock
}

/// Splits a parsed document into finalized blocks plus a mutable tail string.
enum StreamingMarkdownSplit {
    struct Result: Equatable {
        var stableBlocks: [MarkdownBlock]
        var tail: String
    }

    static func split(document: MarkdownDocument, fullSource: String) -> Result {
        let source = MarkdownParserSupport.normalizeNewlines(fullSource)
        guard !document.blocks.isEmpty else {
            return Result(stableBlocks: [], tail: source)
        }

        // If the last block is an open code fence, treat it as provisional
        // code (stable) and keep nothing as plain tail after it.
        if case .code(_, _, _, let isClosed) = document.blocks.last, !isClosed {
            return Result(stableBlocks: document.blocks, tail: "")
        }

        // Prefer all completed blocks; any source after the last block end
        // is the mutable tail (incomplete paragraph / list marker, etc.).
        let lastEnd = document.blocks.last?.range.end ?? 0
        let stable = document.blocks
        if lastEnd >= source.utf16.count {
            return Result(stableBlocks: stable, tail: "")
        }
        let tail = MarkdownSourceIndex.substring(
            source,
            range: MarkdownSourceRange(start: lastEnd, end: source.utf16.count)
        )
        // If the tail is only whitespace and we already have blocks, still
        // show it so the typewriter can grow into the next paragraph.
        return Result(stableBlocks: stable, tail: tail)
    }
}

/// Shared block renderer used by completed and streaming paths.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var messageID: UUID? = nil
    /// Normalized source for provisional ID computation (K13).
    var source: String = ""
    var isStreaming: Bool = false

    var body: some View {
        let blockID = MarkdownBlockID.id(
            messageID: messageID,
            block: block,
            source: source,
            isStreaming: isStreaming
        )
        switch block {
        case .prose(let s, _):
            MarkdownProseView(text: s)
                .accessibilityIdentifier(blockID.accessibilityIdentifier)
        case .table(let headers, let alignments, let rows, _):
            MarkdownTableBlockView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                accessibilityIdentifier: blockID.accessibilityIdentifier
            )
        case .code(let lang, let body, _, let isClosed):
            CodeBlockView(
                language: lang,
                code: body,
                copyButtonAccessibilityIdentifier: blockID.copyCodeAccessibilityIdentifier,
                isProvisional: !isClosed || blockID.isProvisional
            )
        case .fallback(let s, _):
            MarkdownProseView(text: s)
                .accessibilityIdentifier(blockID.accessibilityIdentifier)
        }
    }
}

struct MarkdownProseView: View {
    let text: String

    var body: some View {
        if let attr = MarkdownAttributed.inline(text) {
            Text(attr)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textHigh)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, MarkdownOpenURL.action)
        } else {
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textHigh)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
