import XCTest
@testable import vMLXApp
import vMLXTheme

final class MarkdownViewTests: XCTestCase {
    private let parser = LightweightMarkdownParser.shared

    func testMarkdownAccessibilityThemeTokensAreAvailable() {
        // Compile-time coverage for the Markdown-only semantic token surface.
        // Its use sites live exclusively in Markdown renderers; app-wide
        // body/caption/mono continue to be fixed-density tokens.
        _ = Theme.Typography.markdownBody
        _ = Theme.Typography.markdownBodyEmphasized
        _ = Theme.Typography.markdownCaption
        _ = Theme.Typography.markdownMono
        _ = Theme.Typography.markdownMonoCaption
        _ = Theme.Typography.markdownHeading(level: 6)
        _ = Theme.Colors.markdownText
        _ = Theme.Colors.markdownTextSecondary
        _ = Theme.Colors.markdownTextTertiary
        _ = Theme.Colors.markdownAccent
        _ = Theme.Colors.markdownSurface
        _ = Theme.Colors.markdownSurfaceHi
        _ = Theme.Colors.markdownBorder
    }

    func testParsesGFMTableAndKeepsCodeBlockSeparate() {
        let source = #"""
        **Markdown works.**

        | Check | Result |
        | --- | --- |
        | Table | PASS |

        ```swift
        print("MARKDOWN_E2E")
        ```
        """#

        let document = parser.parse(source)
        var table: (headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])?
        var code: (language: String, body: String)?

        for block in document.blocks {
            switch block {
            case let .table(headers, alignments, rows, _):
                table = (headers, alignments, rows)
            case let .code(language, body, _, _):
                code = (language, body)
            default:
                break
            }
        }

        XCTAssertEqual(table?.headers, ["Check", "Result"])
        XCTAssertEqual(table?.alignments, [.leading, .leading])
        XCTAssertEqual(table?.rows, [["Table", "PASS"]])
        XCTAssertEqual(code?.language, "swift")
        XCTAssertEqual(code?.body, "print(\"MARKDOWN_E2E\")\n")
    }

    func testParsesTableAlignmentAndEscapedOrInlineCodePipes() {
        let source = #"""
        | Expression | Value | Notes |
        | :--- | :---: | ---: |
        | `a|b` | x \| y | right |
        """#

        let document = parser.parse(source)
        guard case let .table(headers, alignments, rows, _) = document.blocks.first else {
            return XCTFail("Expected a GFM table")
        }

        XCTAssertEqual(headers, ["Expression", "Value", "Notes"])
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
        XCTAssertEqual(rows, [["`a|b`", "x | y", "right"]])
    }

    func testPipeProseWithoutDelimiterRemainsProse() {
        let source = "This | remains ordinary prose.\nIt has no GFM delimiter row."
        let document = parser.parse(source)
        XCTAssertEqual(document.blocks.count, 1)
        guard case let .prose(text, _) = document.blocks[0] else {
            return XCTFail("expected prose")
        }
        XCTAssertEqual(text, source)
    }

    func testCodeCopyControlHasStableAccessibilityPath() {
        XCTAssertEqual(CodeBlockView.copyAccessibilityLabel, "Copy code")
        XCTAssertEqual(
            CodeBlockView.copyAccessibilityIdentifier(for: 3),
            "markdown.copy-code.3"
        )
        XCTAssertEqual(
            CodeBlockView.lineNumbersAccessibilityIdentifier(
                for: "markdown.copy-code.message.12-34"
            ),
            "markdown.code.line-numbers.message.12-34"
        )
    }

    func testShowLineNumbersDefaultsKeyAndDefaultResolution() {
        XCTAssertEqual(
            CodeBlockView.showLineNumbersDefaultsKey,
            "chat.markdown.showLineNumbers"
        )
        XCTAssertFalse(
            CodeBlockView.resolvesShowLineNumbers(preference: false, localOverride: nil)
        )
        XCTAssertTrue(
            CodeBlockView.resolvesShowLineNumbers(preference: true, localOverride: nil)
        )
        XCTAssertTrue(
            CodeBlockView.resolvesShowLineNumbers(preference: false, localOverride: true)
        )
        XCTAssertFalse(
            CodeBlockView.resolvesShowLineNumbers(preference: true, localOverride: false)
        )
    }

    func testCodeLineCountingDoesNotAddPhantomTerminalNewline() {
        let eightyLines = (0..<80).map(String.init).joined(separator: "\n") + "\n"
        XCTAssertEqual(CodeBlockView.lineCount(for: eightyLines), 80)
        XCTAssertFalse(CodeBlockView.isLongCode(for: eightyLines))
        XCTAssertEqual(CodeBlockView.lineCount(for: ""), 1)
    }

    func testTableCollapseThresholdAndVisibleRows() {
        XCTAssertEqual(MarkdownTableBlockView.collapseRowThreshold, 100)

        let small = (0..<100).map { ["r\($0)"] }
        XCTAssertEqual(
            MarkdownTableBlockView.visibleRows(rows: small, expanded: false).count,
            100
        )

        let large = (0..<150).map { ["r\($0)"] }
        let collapsed = MarkdownTableBlockView.visibleRows(rows: large, expanded: false)
        XCTAssertEqual(collapsed.count, 100)
        XCTAssertEqual(collapsed.first, ["r0"])
        XCTAssertEqual(collapsed.last, ["r99"])

        let expanded = MarkdownTableBlockView.visibleRows(rows: large, expanded: true)
        XCTAssertEqual(expanded.count, 150)
        XCTAssertEqual(expanded.last, ["r149"])
    }

    func testTableClipboardUsesFullRowsRegardlessOfCollapse() {
        let headers = ["A"]
        let alignments: [MarkdownTableAlignment] = [.leading]
        let rows = (0..<120).map { ["v\($0)"] }

        let md = MarkdownTableClipboard.asMarkdown(
            headers: headers,
            alignments: alignments,
            rows: rows
        )
        let tsv = MarkdownTableClipboard.asTSV(headers: headers, rows: rows)

        XCTAssertTrue(md.contains("v0"))
        XCTAssertTrue(md.contains("v119"))
        XCTAssertTrue(tsv.contains("v0"))
        XCTAssertTrue(tsv.contains("v119"))
        XCTAssertEqual(
            MarkdownTableBlockView.visibleRows(rows: rows, expanded: false).count,
            100
        )
        XCTAssertEqual(rows.count, 120)
    }

    func testTableAccessibilitySummaryAndCellLabels() {
        XCTAssertEqual(
            MarkdownTableBlockView.tableAccessibilitySummary(columnCount: 2, rowCount: 3),
            "Markdown table with 2 columns and 3 rows"
        )

        XCTAssertEqual(
            MarkdownTableBlockView.cellAccessibilityLabel(
                text: "Name",
                isHeader: true,
                columnHeader: nil,
                rowNumber: nil,
                columnNumber: 1
            ),
            "Column 1, Name"
        )

        XCTAssertEqual(
            MarkdownTableBlockView.cellAccessibilityLabel(
                text: "Ada",
                isHeader: false,
                columnHeader: "Name",
                rowNumber: 1,
                columnNumber: 1
            ),
            "Name, Ada, row 1"
        )

        // AttributedString-based strip: emphasis markers gone.
        let stripped = MarkdownTableBlockView.cellAccessibilityLabel(
            text: "**bold**",
            isHeader: false,
            columnHeader: "`col`",
            rowNumber: 2,
            columnNumber: 2
        )
        XCTAssertTrue(stripped.contains("bold"))
        XCTAssertTrue(stripped.contains("col"))
        XCTAssertTrue(stripped.contains("row 2"))

        XCTAssertEqual(
            MarkdownTableBlockView.cellAccessibilityLabel(
                text: "",
                isHeader: false,
                columnHeader: "Notes",
                rowNumber: 3,
                columnNumber: 3
            ),
            "Notes, empty, row 3"
        )
    }

    func testTableRowAccessibilityLabelAndSparseCells() {
        let headers = ["Check", "Result"]
        let row = ["Table"]
        let label = MarkdownTableBlockView.rowAccessibilityLabel(
            headers: headers,
            row: row,
            rowNumber: 1
        )
        XCTAssertTrue(label.hasPrefix("Row 1:"))
        XCTAssertTrue(label.contains("Table"))
        XCTAssertTrue(label.contains("empty") || label.contains("Result"))
        XCTAssertEqual(MarkdownTableBlockView.cellText(row: row, columnIndex: 0), "Table")
        XCTAssertEqual(MarkdownTableBlockView.cellText(row: row, columnIndex: 1), "")
        XCTAssertEqual(MarkdownTableBlockView.cellText(row: row, columnIndex: 5), "")
    }
}
