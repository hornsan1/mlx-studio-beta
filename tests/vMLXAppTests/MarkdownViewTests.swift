import XCTest
@testable import vMLXApp

final class MarkdownViewTests: XCTestCase {
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

        let segments = MarkdownView.parse(source)
        var table: (headers: [String], alignments: [MarkdownView.TableAlignment], rows: [[String]])?
        var code: (language: String, body: String)?

        for segment in segments {
            switch segment {
            case let .table(headers, alignments, rows):
                table = (headers, alignments, rows)
            case let .code(language, body):
                code = (language, body)
            case .prose:
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

        let segments = MarkdownView.parse(source)
        guard case let .table(headers, alignments, rows) = try? XCTUnwrap(segments.first) else {
            return XCTFail("Expected a GFM table")
        }

        XCTAssertEqual(headers, ["Expression", "Value", "Notes"])
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
        XCTAssertEqual(rows, [["`a|b`", "x | y", "right"]])
    }

    func testPipeProseWithoutDelimiterRemainsProse() {
        let source = "This | remains ordinary prose.\nIt has no GFM delimiter row."

        XCTAssertEqual(MarkdownView.parse(source), [.prose(source)])
    }

    func testCodeCopyControlHasStableAccessibilityPath() {
        XCTAssertEqual(CodeBlockView.copyAccessibilityLabel, "Copy code")
        XCTAssertEqual(
            CodeBlockView.copyAccessibilityIdentifier(for: 3),
            "markdown.copy-code.3"
        )
    }

    // MARK: - Line numbers (PR-5)

    func testShowLineNumbersDefaultsKeyAndDefaultResolution() {
        XCTAssertEqual(
            CodeBlockView.showLineNumbersDefaultsKey,
            "chat.markdown.showLineNumbers"
        )
        // Beginner default: preference false + no override → off
        XCTAssertFalse(
            CodeBlockView.resolvesShowLineNumbers(preference: false, localOverride: nil)
        )
        // Global Advanced preference on
        XCTAssertTrue(
            CodeBlockView.resolvesShowLineNumbers(preference: true, localOverride: nil)
        )
        // Per-block overflow can turn on without preference
        XCTAssertTrue(
            CodeBlockView.resolvesShowLineNumbers(preference: false, localOverride: true)
        )
        // Per-block overflow can turn off without clearing preference
        XCTAssertFalse(
            CodeBlockView.resolvesShowLineNumbers(preference: true, localOverride: false)
        )
    }

    // MARK: - Table collapse (PR-5)

    func testTableCollapseThresholdAndVisibleRows() {
        XCTAssertEqual(MarkdownTableBlockView.collapseRowThreshold, 100)

        let small = (0..<100).map { ["r\($0)"] }
        XCTAssertEqual(
            MarkdownTableBlockView.visibleRows(rows: small, expanded: false).count,
            100,
            "Exactly 100 rows must not collapse"
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
        // Collapse is a render concern; clipboard helpers always receive full rows.
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
        // Visible prefix is shorter than full row set when collapsed.
        XCTAssertEqual(
            MarkdownTableBlockView.visibleRows(rows: rows, expanded: false).count,
            100
        )
        XCTAssertEqual(rows.count, 120)
    }
}
