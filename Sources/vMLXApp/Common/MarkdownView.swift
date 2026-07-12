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
    /// Collapse body when row count exceeds this (P0 fixed threshold).
    static let collapseRowThreshold = 100

    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    var accessibilityIdentifier: String = "markdown.table"
    @State private var copiedLabel: String?
    @State private var expanded = false

    /// Whether this table is large enough to offer collapse chrome.
    var isCollapsible: Bool { rows.count > Self.collapseRowThreshold }

    /// Rows rendered in the grid (prefix when collapsed).
    var visibleRows: [[String]] {
        Self.visibleRows(rows: rows, expanded: expanded)
    }

    /// Pure helper for tests and render path.
    static func visibleRows(rows: [[String]], expanded: Bool) -> [[String]] {
        guard rows.count > collapseRowThreshold, !expanded else { return rows }
        return Array(rows.prefix(collapseRowThreshold))
    }

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
                    ForEach(visibleRows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(headers.indices, id: \.self) { columnIndex in
                                MarkdownTableCell(
                                    text: visibleRows[rowIndex][columnIndex],
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

            if isCollapsible {
                Button(expanded ? "Show less" : "Show full table") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityIdentifier("\(accessibilityIdentifier).expand")
                .accessibilityLabel(
                    expanded
                        ? "Show fewer table rows"
                        : "Show full table (\(rows.count) rows)"
                )
            }

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

    /// Always copies the full table (headers + all rows), even when collapsed.
    private func copyMarkdown() {
        let payload = MarkdownTableClipboard.asMarkdown(
            headers: headers,
            alignments: alignments,
            rows: rows
        )
        writePasteboard(payload)
        flash("Copied Markdown")
    }

    /// Always copies the full table as TSV, even when collapsed.
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
///
/// Line numbers (Advanced): off by default via UserDefaults
/// `chat.markdown.showLineNumbers`. Per-block overflow can toggle them for
/// this instance without writing the global preference.
struct CodeBlockView: View {
    static let copyAccessibilityLabel = "Copy code"
    static let longBlockLineThreshold = 80
    /// UserDefaults / AppStorage key for the global line-number preference.
    static let showLineNumbersDefaultsKey = "chat.markdown.showLineNumbers"

    /// Legacy ordinal identifier. Prefer
    /// `MarkdownBlockID.copyCodeAccessibilityIdentifier` for new call sites.
    static func copyAccessibilityIdentifier(for ordinal: Int) -> String {
        "markdown.copy-code.\(ordinal)"
    }

    /// Resolves effective line-number visibility for a block.
    /// - Parameters:
    ///   - preference: Global `UserDefaults` value (default false).
    ///   - localOverride: Per-block `@State` override; `nil` means follow preference.
    static func resolvesShowLineNumbers(preference: Bool, localOverride: Bool?) -> Bool {
        localOverride ?? preference
    }

    let language: String
    let code: String
    let copyButtonAccessibilityIdentifier: String
    var isProvisional: Bool = false

    @AppStorage(CodeBlockView.showLineNumbersDefaultsKey)
    private var preferenceShowLineNumbers = false
    /// `nil` = follow global preference; non-nil = per-block override for this session.
    @State private var localShowLineNumbersOverride: Bool? = nil
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

    private var showLineNumbers: Bool {
        Self.resolvesShowLineNumbers(
            preference: preferenceShowLineNumbers,
            localOverride: localShowLineNumbersOverride
        )
    }

    private var sourceLines: [Substring] {
        code.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private var displayCode: String {
        guard isLong, !expanded else { return code }
        return sourceLines.prefix(Self.longBlockLineThreshold).joined(separator: "\n")
            + "\n… (\(lineCount - Self.longBlockLineThreshold) more lines)"
    }

    /// 1-based source line numbers for currently displayed content (no gutter for the ellipsis row).
    private var displayLineNumbers: [Int] {
        let visibleCount: Int
        if isLong, !expanded {
            visibleCount = Self.longBlockLineThreshold
        } else {
            visibleCount = lineCount
        }
        return Array(1...max(1, visibleCount))
    }

    private var lineNumberGutter: String {
        let width = max(2, String(displayLineNumbers.last ?? 1).count)
        return displayLineNumbers
            .map { String(format: "%\(width)d", $0) }
            .joined(separator: "\n")
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
                // Per-block Advanced overflow: toggle line numbers without writing UserDefaults.
                Button {
                    localShowLineNumbersOverride = !showLineNumbers
                } label: {
                    Text(showLineNumbers ? "Hide #" : "Show #")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("markdown.code.line-numbers")
                .accessibilityLabel(
                    showLineNumbers ? "Hide line numbers" : "Show line numbers"
                )
                .help(
                    showLineNumbers
                        ? "Hide line numbers for this block"
                        : "Show line numbers for this block"
                )
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
                    codeBody
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        codeBody
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

    @ViewBuilder
    private var codeBody: some View {
        if showLineNumbers {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text(lineNumberGutter)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textLow)
                    .multilineTextAlignment(.trailing)
                    .accessibilityHidden(true)
                Text(displayCode)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textHigh)
                    .textSelection(.enabled)
            }
        } else {
            Text(displayCode)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Colors.textHigh)
                .textSelection(.enabled)
        }
    }

    /// Always copies the full code body, even when the block is collapsed.
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
