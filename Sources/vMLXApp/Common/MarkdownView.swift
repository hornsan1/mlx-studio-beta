import SwiftUI
import vMLXTheme

/// Native Markdown renderer for chat messages (streaming and completed).
///
/// One view for both modes: while `isStreaming`, completed blocks render
/// immediately and only the mutable tail uses the typewriter. When the stream
/// ends, the same block list finalizes without swapping to a different view.
struct MarkdownView: View {
    let text: String
    var messageID: UUID? = nil
    var isStreaming: Bool = false

    @State private var document: MarkdownDocument = .empty
    @State private var parseTask: Task<Void, Never>?
    @State private var lastParseAt: Date = .distantPast

    private let minReparseInterval: TimeInterval = 0.08

    var body: some View {
        let split = StreamingMarkdownSplit.split(document: document, fullSource: text)
        let lastIndex = split.stableBlocks.indices.last
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(
                Array(split.stableBlocks.enumerated()).map { index, block in
                    IdentifiedMarkdownBlock(
                        id: MarkdownBlockID.id(
                            messageID: messageID,
                            block: block,
                            isStreaming: isStreaming,
                            isLastBlock: isStreaming && index == lastIndex
                        ),
                        block: block
                    )
                }
            ) { item in
                MarkdownBlockView(
                    block: item.block,
                    messageID: messageID,
                    isStreaming: isStreaming,
                    isLastBlock: item.id.isProvisional && isStreaming
                )
            }
            if isStreaming, !split.tail.isEmpty {
                StreamingTextView(text: split.tail, isStreaming: true)
                    .accessibilityIdentifier(
                        "markdown.stream-tail.\(messageID?.uuidString.lowercased() ?? "orphan")"
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { scheduleParse(force: true) }
        .onChange(of: text) { _, _ in scheduleParse(force: false) }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                parseTask?.cancel()
                document = MarkdownParserSupport.parseSync(text, messageID: messageID)
            }
        }
        .onDisappear { parseTask?.cancel() }
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
            // Parse (and seed the sync cache) off the main actor.
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownParserSupport.parseSync(source, messageID: msgID)
            }.value
            guard !Task.isCancelled else { return }
            document = parsed
            lastParseAt = Date()
        }
    }
}

/// ForEach carrier — identity is `MarkdownBlockID`.
struct IdentifiedMarkdownBlock: Identifiable {
    let id: MarkdownBlockID
    let block: MarkdownBlock
}

/// Progressive alias kept for existing call sites (`MessageBubble`, Studio).
struct MarkdownStreamingView: View {
    let text: String
    var messageID: UUID? = nil
    var isStreaming: Bool = true

    var body: some View {
        MarkdownView(text: text, messageID: messageID, isStreaming: isStreaming)
    }
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

        if case .code(_, _, _, let isClosed) = document.blocks.last, !isClosed {
            return Result(stableBlocks: document.blocks, tail: "")
        }

        let lastEnd = document.blocks.last?.range.end ?? 0
        if lastEnd >= source.utf16.count {
            return Result(stableBlocks: document.blocks, tail: "")
        }
        let tail = MarkdownSourceIndex.substring(
            source,
            range: MarkdownSourceRange(start: lastEnd, end: source.utf16.count)
        )
        return Result(stableBlocks: document.blocks, tail: tail)
    }
}

/// Shared block renderer used by streaming and completed paths.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var messageID: UUID? = nil
    var isStreaming: Bool = false
    var isLastBlock: Bool = false

    var body: some View {
        let blockID = MarkdownBlockID.id(
            messageID: messageID,
            block: block,
            isStreaming: isStreaming,
            isLastBlock: isLastBlock
        )
        switch block {
        case .prose(let s, _), .fallback(let s, _):
            MarkdownProseView(text: s)
                .accessibilityIdentifier(blockID.accessibilityIdentifier)
        case .heading(let level, let text, _):
            MarkdownHeadingView(level: level, text: text)
                .accessibilityIdentifier(blockID.accessibilityIdentifier)
        case .listItem(let ordered, let index, let indentLevel, let text, _):
            MarkdownListItemView(
                ordered: ordered,
                index: index,
                indentLevel: indentLevel,
                text: text
            )
            .accessibilityIdentifier(blockID.accessibilityIdentifier)
        case .taskItem(let checked, let indentLevel, let text, _):
            MarkdownTaskItemView(
                checked: checked,
                indentLevel: indentLevel,
                text: text
            )
            .accessibilityIdentifier(blockID.accessibilityIdentifier)
        case .blockquote(let text, let quoteDepth, _):
            MarkdownBlockquoteView(text: text, quoteDepth: quoteDepth)
                .accessibilityIdentifier(blockID.accessibilityIdentifier)
        case .thematicBreak:
            MarkdownThematicBreakView()
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
                isProvisional: !isClosed
            )
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
