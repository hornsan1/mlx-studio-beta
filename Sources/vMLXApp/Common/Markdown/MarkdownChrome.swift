import SwiftUI
import vMLXTheme
#if canImport(AppKit)
import AppKit
#endif

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

    /// Summary label for the table container (full row count, even when collapsed).
    static func tableAccessibilitySummary(columnCount: Int, rowCount: Int) -> String {
        "Markdown table with \(columnCount) columns and \(rowCount) rows"
    }

    /// VoiceOver label for one cell: column header + value + row index where practical.
    static func cellAccessibilityLabel(
        text: String,
        isHeader: Bool,
        columnHeader: String?,
        rowNumber: Int?,
        columnNumber: Int
    ) -> String {
        let value = MarkdownPlainText.stripInlineMarkers(text)
        let valuePart = value.isEmpty ? "empty" : value
        if isHeader {
            return "Column \(columnNumber), \(valuePart)"
        }
        let headerRaw = columnHeader.map { MarkdownPlainText.stripInlineMarkers($0) } ?? ""
        let headerPart = headerRaw.isEmpty ? "Column \(columnNumber)" : headerRaw
        if let rowNumber {
            return "\(headerPart), \(valuePart), row \(rowNumber)"
        }
        return "\(headerPart), \(valuePart)"
    }

    /// Combined row label for rotor / combined-row navigation.
    static func rowAccessibilityLabel(
        headers: [String],
        row: [String],
        rowNumber: Int
    ) -> String {
        var parts: [String] = []
        for index in headers.indices {
            let header = MarkdownPlainText.stripInlineMarkers(headers[index])
            let cell = index < row.count
                ? MarkdownPlainText.stripInlineMarkers(row[index])
                : ""
            let valuePart = cell.isEmpty ? "empty" : cell
            if header.isEmpty {
                parts.append(valuePart)
            } else {
                parts.append("\(header) \(valuePart)")
            }
        }
        let body = parts.isEmpty ? "empty" : parts.joined(separator: ", ")
        return "Row \(rowNumber): \(body)"
    }

    /// Safe cell text for sparse rows shorter than the header width.
    static func cellText(row: [String], columnIndex: Int) -> String {
        columnIndex < row.count ? row[columnIndex] : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    // Header row — cells expose column labels + isHeader trait.
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            MarkdownTableCell(
                                text: headers[index],
                                alignment: alignment(at: index),
                                isHeader: true,
                                columnHeader: nil,
                                rowNumber: nil,
                                columnNumber: index + 1
                            )
                        }
                    }

                    ForEach(visibleRows.indices, id: \.self) { rowIndex in
                        let row = visibleRows[rowIndex]
                        // Cell labels carry column header + row index (GridRow must stay a bare Grid child).
                        GridRow {
                            ForEach(headers.indices, id: \.self) { columnIndex in
                                MarkdownTableCell(
                                    text: Self.cellText(row: row, columnIndex: columnIndex),
                                    alignment: alignment(at: columnIndex),
                                    isHeader: false,
                                    columnHeader: headers[columnIndex],
                                    rowNumber: rowIndex + 1,
                                    columnNumber: columnIndex + 1
                                )
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            Self.rowAccessibilityLabel(
                                headers: headers,
                                row: row,
                                rowNumber: rowIndex + 1
                            )
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                // Prefer contained children so VoiceOver can move header/rows/cells.
                .accessibilityElement(children: .contain)
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
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(
            Self.tableAccessibilitySummary(
                columnCount: headers.count,
                rowCount: rows.count
            )
        )
    }

    private func alignment(at index: Int) -> MarkdownTableAlignment {
        index < alignments.count ? alignments[index] : .leading
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
    /// Column header text for body-cell VoiceOver labels (nil on header cells).
    var columnHeader: String? = nil
    /// 1-based row number for body cells; nil for header row.
    var rowNumber: Int? = nil
    /// 1-based column number.
    var columnNumber: Int = 1

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

    private var accessibilityLabel: String {
        MarkdownTableBlockView.cellAccessibilityLabel(
            text: text,
            isHeader: isHeader,
            columnHeader: columnHeader,
            rowNumber: rowNumber,
            columnNumber: columnNumber
        )
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
        // Theme body scales when Dynamic Type / text-size preferences change via Theme tokens.
        .font(Theme.Typography.body)
        .fontWeight(isHeader ? .semibold : .regular)
        // Semantic Theme colors (high-contrast dynamic provider aware).
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isHeader ? .isHeader : [])
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
        // Prefer Theme mono token (semantic text/colors) over hardcoded system sizes.
        if showLineNumbers {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text(lineNumberGutter)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.textLow)
                    .multilineTextAlignment(.trailing)
                    .accessibilityHidden(true)
                Text(displayCode)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .textSelection(.enabled)
            }
        } else {
            Text(displayCode)
                .font(Theme.Typography.mono)
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
