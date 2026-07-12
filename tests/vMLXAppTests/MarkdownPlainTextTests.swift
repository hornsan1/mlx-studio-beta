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

    func testDisallowedSchemesKeepLabelOnly() {
        let cases: [(String, String)] = [
            ("[x](javascript:alert(1))", "x"),
            ("[x](data:text/html,hi)", "x"),
            ("[x](vmlx://local)", "x"),
            ("[x](/relative/path)", "x"),
            ("[x](example.com/path)", "x"),
        ]
        for (source, expected) in cases {
            let plain = MarkdownPlainText.render(source: source)
            XCTAssertEqual(plain, expected, "source: \(source)")
            XCTAssertFalse(plain.contains("javascript:"), "leaked scheme for \(source)")
            XCTAssertFalse(plain.contains("data:"), "leaked scheme for \(source)")
            XCTAssertFalse(plain.contains("vmlx:"), "leaked scheme for \(source)")
        }
    }

    func testJavascriptAlertWithParensKeepsLabelOnly() {
        // Destination contains `)` — must not leave a stray closing paren.
        let plain = MarkdownPlainText.render(source: "Go [x](javascript:alert(1)) now")
        XCTAssertEqual(plain, "Go x now")
        XCTAssertFalse(plain.contains("javascript"))
        XCTAssertFalse(plain.contains("alert"))
    }

    func testLinkDestinationWithParenthesesInURL() {
        let source = "[Foo](https://en.wikipedia.org/wiki/Foo_(bar))"
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(
            plain,
            "Foo (https://en.wikipedia.org/wiki/Foo_(bar))"
        )
    }

    func testLinkWithTitleAttribute() {
        let plain = MarkdownPlainText.render(
            source: #"[docs](https://example.com/path "title text")"#
        )
        XCTAssertEqual(plain, "docs (https://example.com/path)")
    }

    func testImagesBecomeAltText() {
        let plain = MarkdownPlainText.render(source: "Logo ![MLX](https://example.com/logo.png) here")
        XCTAssertEqual(plain, "Logo MLX here")
    }

    func testImageDestinationWithParentheses() {
        let plain = MarkdownPlainText.render(
            source: "Pic ![alt](https://example.com/img_(1).png) end"
        )
        XCTAssertEqual(plain, "Pic alt end")
        XCTAssertFalse(plain.contains("example.com"))
    }

    func testSnakeCaseAndMultiplicationNotCorrupted() {
        let plain = MarkdownPlainText.render(
            source: "use snake_case_identifier and 2*3*4 plus a * b * c"
        )
        XCTAssertEqual(
            plain,
            "use snake_case_identifier and 2*3*4 plus a * b * c"
        )
    }

    func testInlineCodeProtectsUnderscores() {
        let plain = MarkdownPlainText.render(source: "use `file_name_path` here")
        XCTAssertEqual(plain, "use file_name_path here")
    }

    func testInlineCodeProtectsAsterisks() {
        let plain = MarkdownPlainText.render(source: "expr `2*3*4` done")
        XCTAssertEqual(plain, "expr 2*3*4 done")
    }

    func testRealItalicStillStripped() {
        let plain = MarkdownPlainText.render(source: "say *hello* please and _world_ too")
        XCTAssertEqual(plain, "say hello please and world too")
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

    func testTableCellsStripInlineMarkers() {
        let source = #"""
        | Check | Result |
        | --- | --- |
        | **PASS** | `x_y` |
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "Check\tResult\nPASS\tx_y")
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("`"))
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

    func testAutolinkSchemeCaseInsensitive() {
        let plain = MarkdownPlainText.render(source: "Go <HTTPS://example.com>")
        XCTAssertEqual(plain, "Go HTTPS://example.com")
        XCTAssertFalse(plain.contains("<"))
        XCTAssertFalse(plain.contains(">"))
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
