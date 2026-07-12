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
}
