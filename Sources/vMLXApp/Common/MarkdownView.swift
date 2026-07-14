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
    @State private var pendingParse: PendingMarkdownParse?
    @State private var lastParseAt: Date = .distantPast
    @State private var parseTaskGeneration = 0

    var body: some View {
        let split = StreamingMarkdownSplit.split(document: document, fullSource: text)
        let lastIndex = split.stableBlocks.indices.last
        let terminalBlockMatchesCurrentSource = StreamingMarkdownSplit
            .terminalBlockMatchesCurrentSource(split.stableBlocks.last, fullSource: text)
        Group {
            if StreamingMarkdownSplit.needsCompletedFallback(
                document: document,
                fullSource: text,
                isStreaming: isStreaming
            ) {
                // Never mount a completed message as a blank bubble while its
                // first background parse is pending. This is deliberately raw
                // Text: it cannot resolve untrusted Markdown URLs.
                Text(text)
                    .font(Theme.Typography.markdownBody)
                    .foregroundStyle(Theme.Colors.markdownText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(
                        "markdown.parse-pending.\(messageID?.uuidString.lowercased() ?? "orphan")"
                    )
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(
                        Array(split.stableBlocks.enumerated()).map { index, block in
                            IdentifiedMarkdownBlock(
                                id: MarkdownBlockID.id(
                                    messageID: messageID,
                                    block: block,
                                    isStreaming: isStreaming,
                                    // A stale document can have an old closed terminal
                                    // block followed by unparsed tail text. Only the
                                    // block ending at current source is mutable.
                                    isLastBlock: isStreaming
                                        && index == lastIndex
                                        && terminalBlockMatchesCurrentSource
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { scheduleParse(force: true) }
        .onChange(of: text) { _, _ in scheduleParse(force: false) }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                // Preserve the last streamed document while the final parse runs.
                // Parsing here used to run synchronously on the main actor, which
                // could leave a visible blank/hitch on a large final chunk.
                scheduleParse(force: true)
            }
        }
        .onDisappear {
            parseTask?.cancel()
            parseTask = nil
            pendingParse = nil
        }
    }

    private func scheduleParse(force: Bool) {
        let now = Date()
        let request = PendingMarkdownParse(
            source: text,
            messageID: messageID,
            firstQueuedAt: force ? now : (pendingParse?.firstQueuedAt ?? now),
            lastUpdatedAt: now
        )
        pendingParse = request

        // A trailing debounce that cancels itself for every token can be
        // postponed forever by a fast stream. Keep one task alive instead; it
        // reads the newest pending request and the schedule caps its wait.
        if force || parseTask == nil {
            beginParseTask(parseImmediately: force)
        }
    }

    private func beginParseTask(parseImmediately: Bool) {
        parseTask?.cancel()
        parseTaskGeneration &+= 1
        let generation = parseTaskGeneration
        parseTask = Task { @MainActor in
            await runPendingParses(
                generation: generation,
                parseImmediately: parseImmediately
            )
        }
    }

    /// Serially parses the newest pending source. New tokens update
    /// `pendingParse` but intentionally do not cancel this task, so a stream
    /// always receives a structured refresh within the coalescing limit.
    @MainActor
    private func runPendingParses(
        generation: Int,
        parseImmediately: Bool
    ) async {
        var shouldParseImmediately = parseImmediately

        while !Task.isCancelled, parseTaskGeneration == generation {
            guard let request = pendingParse else { break }

            if !shouldParseImmediately {
                let deadline = MarkdownParseSchedule.deadline(
                    firstQueuedAt: request.firstQueuedAt,
                    lastUpdatedAt: request.lastUpdatedAt,
                    lastParseAt: lastParseAt
                )
                let delay = deadline.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                    continue
                }
            }
            shouldParseImmediately = false

            // Clear before awaiting so tokens received during parsing become
            // the next coalesced request rather than being overwritten.
            pendingParse = nil
            let source = request.source
            let msgID = request.messageID
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownParserSupport.parseSync(source, messageID: msgID)
            }.value

            guard !Task.isCancelled, parseTaskGeneration == generation else {
                return
            }
            document = parsed
            lastParseAt = Date()
        }

        if parseTaskGeneration == generation {
            parseTask = nil
        }
    }
}

/// Latest Markdown payload waiting for a coalesced parse.
private struct PendingMarkdownParse {
    let source: String
    let messageID: UUID?
    let firstQueuedAt: Date
    let lastUpdatedAt: Date
}

/// Pure timing policy for Markdown stream reparses.
///
/// We retain a short trailing debounce so individual tokens coalesce, but cap
/// its extension so a continuously active stream cannot starve structured
/// Markdown rendering. The minimum interval avoids reparsing immediately
/// after a large parse completes.
struct MarkdownParseSchedule {
    static let trailingDebounce: TimeInterval = 0.04
    static let maximumCoalescingWait: TimeInterval = 0.12
    static let minimumReparseInterval: TimeInterval = 0.08

    static func deadline(
        firstQueuedAt: Date,
        lastUpdatedAt: Date,
        lastParseAt: Date
    ) -> Date {
        let trailing = lastUpdatedAt.addingTimeInterval(trailingDebounce)
        let capped = firstQueuedAt.addingTimeInterval(maximumCoalescingWait)
        let requested = min(trailing, capped)
        let earliestAfterPriorParse = lastParseAt.addingTimeInterval(
            minimumReparseInterval
        )
        return max(requested, earliestAfterPriorParse)
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

    static func terminalBlockMatchesCurrentSource(
        _ block: MarkdownBlock?,
        fullSource: String
    ) -> Bool {
        guard let block else { return false }
        let source = MarkdownParserSupport.normalizeNewlines(fullSource)
        return block.range.end == source.utf16.count
    }

    static func needsCompletedFallback(
        document: MarkdownDocument,
        fullSource: String,
        isStreaming: Bool
    ) -> Bool {
        !isStreaming
            && document.source != MarkdownParserSupport.normalizeNewlines(fullSource)
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
                .font(Theme.Typography.markdownBody)
                .foregroundStyle(Theme.Colors.markdownText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, MarkdownOpenURL.action)
        } else {
            Text(text)
                .font(Theme.Typography.markdownBody)
                .foregroundStyle(Theme.Colors.markdownText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
