import XCTest
@testable import vMLXApp

final class MarkdownRenderModelTests: XCTestCase {
    func testSyncCacheReturnsSameDocumentForSameRevision() {
        SyncMarkdownRenderCache.shared.removeAll()
        let source = "**hi**\n\n```\nx\n```"
        let messageID = UUID()
        let first = MarkdownParserSupport.parseSync(source, messageID: messageID)
        let second = MarkdownParserSupport.parseSync(source, messageID: messageID)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.blocks.count, 2)
    }

    func testCacheMissOnDifferentSource() {
        SyncMarkdownRenderCache.shared.removeAll()
        let a = MarkdownParserSupport.parseSync("alpha")
        let b = MarkdownParserSupport.parseSync("beta")
        XCTAssertNotEqual(a.source, b.source)
    }

    func testLegacyOrdinalIdentifierStillAvailable() {
        XCTAssertEqual(CodeBlockView.copyAccessibilityLabel, "Copy code")
        XCTAssertEqual(
            CodeBlockView.copyAccessibilityIdentifier(for: 3),
            "markdown.copy-code.3"
        )
    }

    func testCompatibilityMarkdownViewParseStillWorks() {
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
}
