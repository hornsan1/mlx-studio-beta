import XCTest
@testable import vMLXApp

final class MarkdownPlainTextTests: XCTestCase {
    func testProseStripsEmphasisAndKeepsText() {
        let source = "Hello **bold** and *italic* plus __strong__ and _em_ plus `code` and ~~strike~~."
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(
            plain,
            "Hello bold and italic plus strong and em plus code and strike."
        )
    }

    func testLinksKeepLabelAndAllowedURL() {
        let source = "See [docs](https://example.com/path) and [local](file:///tmp/x) plus [empty]()."
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertTrue(plain.contains("docs (https://example.com/path)"))
        // Disallowed scheme → label only.
        XCTAssertTrue(plain.contains("local"))
        XCTAssertFalse(plain.contains("file:///tmp/x"))
        XCTAssertTrue(plain.contains("empty"))
        XCTAssertFalse(plain.contains("]("))
    }

    func testImagesBecomeAltText() {
        let plain = MarkdownPlainText.render(source: "Logo ![MLX](https://example.com/logo.png) here")
        XCTAssertEqual(plain, "Logo MLX here")
    }

    func testCodeBlockIsRawBodyOnly() {
        let source = #"""
        Intro

        ```swift
        print("hi")
        ```

        Outro
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(
            plain,
            "Intro\n\nprint(\"hi\")\n\nOutro"
        )
        XCTAssertFalse(plain.contains("```"))
        XCTAssertFalse(plain.contains("swift"))
    }

    func testTableRendersAsTSV() {
        let source = #"""
        | Check | Result |
        | --- | --- |
        | Table | PASS |
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "Check\tResult\nTable\tPASS")
    }

    func testMixedDocumentWalkOrder() {
        let source = #"""
        **Markdown works.**

        | Check | Result |
        | --- | --- |
        | Table | PASS |

        ```swift
        print("MARKDOWN_E2E")
        ```
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(
            plain,
            "Markdown works.\n\nCheck\tResult\nTable\tPASS\n\nprint(\"MARKDOWN_E2E\")"
        )
    }

    func testRenderDocumentMatchesSourceEntryPoint() {
        let source = "A **B** C"
        let document = LightweightMarkdownParser.shared.parse(source)
        XCTAssertEqual(
            MarkdownPlainText.render(document),
            MarkdownPlainText.render(source: source)
        )
    }

    func testUnclosedFenceBodyStillCopied() {
        let source = "Intro\n\n```python\nprint(1)\n"
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertTrue(plain.contains("Intro"))
        XCTAssertTrue(plain.contains("print(1)"))
        XCTAssertFalse(plain.contains("```"))
    }

    func testMailtoLinkAllowed() {
        let plain = MarkdownPlainText.render(source: "Write [us](mailto:hi@example.com)")
        XCTAssertEqual(plain, "Write us (mailto:hi@example.com)")
    }

    func testAutolinkAngleBrackets() {
        let plain = MarkdownPlainText.render(source: "Go <https://example.com>")
        XCTAssertEqual(plain, "Go https://example.com")
    }

    func testFallbackStripsMarkers() {
        // fallback is same strip path as prose; exercise via direct document.
        let document = MarkdownDocument(
            source: "**x**",
            blocks: [
                .fallback(text: "**x** and `y`", range: MarkdownSourceRange(start: 0, end: 4)),
            ],
            incompleteTail: nil,
            parserName: "test"
        )
        XCTAssertEqual(MarkdownPlainText.render(document), "x and y")
    }
}
