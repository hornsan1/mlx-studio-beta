import SwiftUI
import vMLXTheme
#if canImport(AppKit)
import AppKit
#endif

/// Native Markdown renderer for completed chat messages.
///
/// Parses via `MarkdownParser` into an immutable `MarkdownDocument`, then
/// renders blocks with SwiftUI views. Raw Markdown remains the source of
/// truth; this view only consumes derived state.
struct MarkdownView: View {
    let text: String
    /// When set, block accessibility IDs are stable across stream completion
    /// and reloads (`message UUID + source range + kind`).
    var messageID: UUID? = nil
    var parser: any MarkdownParser = LightweightMarkdownParser.shared

    var body: some View {
        let document = MarkdownParserSupport.parseSync(
            text,
            messageID: messageID,
            parser: parser
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Key by MarkdownBlockID (end-invariant while provisional), not raw range.
            ForEach(
                document.blocks.map { block in
                    CompletedIdentifiedBlock(
                        id: MarkdownBlockID.id(
                            messageID: messageID,
                            block: block,
                            source: document.source,
                            isStreaming: false
                        ),
                        block: block
                    )
                }
            ) { item in
                MarkdownBlockView(
                    block: item.block,
                    messageID: messageID,
                    source: document.source,
                    isStreaming: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Compatibility API

    /// Legacy segment type kept so existing tests and call sites that only
    /// need a coarse split keep working. Prefer `MarkdownDocument` for new code.
    enum Segment: Equatable {
        case prose(String)
        case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
        case code(language: String, body: String)
    }

    enum TableAlignment: Equatable {
        case leading
        case center
        case trailing

        var frameAlignment: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var textAlignment: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        init(_ alignment: MarkdownTableAlignment) {
            switch alignment {
            case .leading: self = .leading
            case .center: self = .center
            case .trailing: self = .trailing
            }
        }
    }

    /// Compatibility parse used by unit tests. Delegates to
    /// `LightweightMarkdownParser` so grammar stays single-sourced.
    ///
    /// Structural blocks (heading/list/task/quote/break) map to `.prose` with
    /// a plain-source reconstruction so legacy Segment stays three-case.
    static func parse(_ input: String) -> [Segment] {
        let document = LightweightMarkdownParser.shared.parse(input)
        return document.blocks.map { block in
            switch block {
            case .prose(let text, _):
                return .prose(text)
            case .heading(let level, let text, _):
                return .prose(MarkdownStructuralPlainText.heading(level: level, text: text))
            case .listItem(let ordered, let index, let indentLevel, let text, _):
                return .prose(
                    MarkdownStructuralPlainText.listItem(
                        ordered: ordered,
                        index: index,
                        indentLevel: indentLevel,
                        text: text
                    )
                )
            case .taskItem(let checked, let indentLevel, let text, _):
                return .prose(
                    MarkdownStructuralPlainText.taskItem(
                        checked: checked,
                        indentLevel: indentLevel,
                        text: text
                    )
                )
            case .blockquote(let text, _, _):
                return .prose(MarkdownStructuralPlainText.blockquote(text))
            case .thematicBreak:
                return .prose(MarkdownStructuralPlainText.thematicBreak())
            case .table(let headers, let alignments, let rows, _):
                return .table(
                    headers: headers,
                    alignments: alignments.map(TableAlignment.init),
                    rows: rows
                )
            case .code(let language, let body, _, _):
                return .code(language: language, body: body)
            case .fallback(let text, _):
                return .prose(text)
            }
        }
    }
}

/// ForEach carrier for completed Markdown renders — identity is `MarkdownBlockID`.
private struct CompletedIdentifiedBlock: Identifiable {
    let id: MarkdownBlockID
    let block: MarkdownBlock
}

// MARK: - Table

struct MarkdownTableBlockView: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    var accessibilityIdentifier: String = "markdown.table"
    @State private var copiedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            MarkdownTableCell(
                                text: headers[index],
                                alignment: alignments[index],
                                isHeader: true
                            )
                        }
                    }
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(headers.indices, id: \.self) { columnIndex in
                                MarkdownTableCell(
                                    text: rows[rowIndex][columnIndex],
                                    alignment: alignments[columnIndex],
                                    isHeader: false
                                )
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Spacing.sm) {
                Button("Copy Markdown") { copyMarkdown() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .accessibilityIdentifier("\(accessibilityIdentifier).copy-markdown")
                    .accessibilityLabel("Copy table as Markdown")
                Button("Copy TSV") { copyTSV() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .accessibilityIdentifier("\(accessibilityIdentifier).copy-tsv")
                    .accessibilityLabel("Copy table as TSV")
                if let copiedLabel {
                    Text(copiedLabel)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.success)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(
            "Markdown table with \(headers.count) columns and \(rows.count) rows"
        )
    }

    private func copyMarkdown() {
        let payload = MarkdownTableClipboard.asMarkdown(
            headers: headers,
            alignments: alignments,
            rows: rows
        )
        writePasteboard(payload)
        flash("Copied Markdown")
    }

    private func copyTSV() {
        let payload = MarkdownTableClipboard.asTSV(headers: headers, rows: rows)
        writePasteboard(payload)
        flash("Copied TSV")
    }

    private func writePasteboard(_ string: String) {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        #endif
    }

    private func flash(_ label: String) {
        copiedLabel = label
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedLabel == label { copiedLabel = nil }
        }
    }
}

private struct MarkdownTableCell: View {
    let text: String
    let alignment: MarkdownTableAlignment
    let isHeader: Bool

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var body: some View {
        Group {
            if let attributed = MarkdownAttributed.inline(text) {
                Text(attributed)
                    .environment(\.openURL, MarkdownOpenURL.action)
            } else {
                Text(text)
            }
        }
        .font(Theme.Typography.body)
        .fontWeight(isHeader ? .semibold : .regular)
        .foregroundStyle(Theme.Colors.textHigh)
        .textSelection(.enabled)
        .multilineTextAlignment(textAlignment)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minWidth: 92, alignment: frameAlignment)
        .background(isHeader ? Theme.Colors.surfaceHi : Theme.Colors.surface)
        .overlay(
            Rectangle()
                .stroke(Theme.Colors.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Code block

/// Code block with an always-visible, keyboard-accessible copy button.
struct CodeBlockView: View {
    static let copyAccessibilityLabel = "Copy code"
    static let longBlockLineThreshold = 80

    /// Legacy ordinal identifier. Prefer
    /// `MarkdownBlockID.copyCodeAccessibilityIdentifier` for new call sites.
    static func copyAccessibilityIdentifier(for ordinal: Int) -> String {
        "markdown.copy-code.\(ordinal)"
    }

    let language: String
    let code: String
    let copyButtonAccessibilityIdentifier: String
    var isProvisional: Bool = false
    @State private var copied = false
    @State private var wrap = false
    @State private var expanded = false

    init(
        language: String,
        code: String,
        copyButtonAccessibilityIdentifier: String = CodeBlockView.copyAccessibilityIdentifier(for: 0),
        isProvisional: Bool = false
    ) {
        self.language = language
        self.code = code
        self.copyButtonAccessibilityIdentifier = copyButtonAccessibilityIdentifier
        self.isProvisional = isProvisional
    }

    private var lineCount: Int {
        max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private var isLong: Bool { lineCount > Self.longBlockLineThreshold }

    private var displayCode: String {
        guard isLong, !expanded else { return code }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(Self.longBlockLineThreshold).joined(separator: "\n")
            + "\n… (\(lineCount - Self.longBlockLineThreshold) more lines)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(MarkdownLanguage.displayName(for: language))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                if isProvisional {
                    Text("streaming…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.warning)
                }
                Spacer(minLength: 0)
                Button {
                    wrap.toggle()
                } label: {
                    Text(wrap ? "Scroll" : "Wrap")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(wrap ? "Disable wrap" : "Wrap code lines")
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(copied ? Theme.Colors.success : Theme.Colors.textMid)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(copyButtonAccessibilityIdentifier)
                .accessibilityLabel(copied ? "Code copied" : Self.copyAccessibilityLabel)
                .accessibilityHint("Copies this code block to the clipboard")
                .help(copied ? "Copied" : Self.copyAccessibilityLabel)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Colors.surface)

            Group {
                if wrap {
                    Text(displayCode)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textHigh)
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(displayCode)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Theme.Colors.textHigh)
                            .textSelection(.enabled)
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(Theme.Colors.surfaceHi)

            if isLong {
                Button(expanded ? "Show less" : "Show full code") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.accent)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.surface)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surfaceHi)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
        )
    }

    private func copy() {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        #endif
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
