import XCTest
@testable import vMLXApp

final class MarkdownPlainTextTests: XCTestCase {
    func testProseStripsEmphasisAndKeepsText() {
        let source = "Hello **bold** and *italic* plus __strong__ and _em_ plus `code` and ~~strike~~."
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertTrue(plain.contains("bold"))
        XCTAssertTrue(plain.contains("italic") || plain.contains("code"))
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("```"))
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

    func testSnakeCasePreserved() {
        // System AttributedString may treat `2*3*4` as emphasis; snake_case must stay.
        let plain = MarkdownPlainText.render(
            source: "use snake_case_identifier and code"
        )
        XCTAssertTrue(plain.contains("snake_case_identifier"))
        XCTAssertFalse(plain.contains("**"))
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
            parserName: "test"
        )
        let plain = MarkdownPlainText.render(document)
        XCTAssertTrue(plain.contains("x"))
        XCTAssertTrue(plain.contains("y"))
        XCTAssertFalse(plain.contains("**"))
    }

    // MARK: - Phase B structural blocks

    func testHeadingIsPlainBodyWithoutHashes() {
        let plain = MarkdownPlainText.render(source: "# Hello **World**\n\n## Sub")
        XCTAssertEqual(plain, "Hello World\n\nSub")
        XCTAssertFalse(plain.contains("#"))
    }

    func testUnorderedListItemsJoinTightly() {
        let source = #"""
        - **alpha**
        - beta
        - gamma
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "- alpha\n- beta\n- gamma")
    }

    func testOrderedListShowsIndex() {
        let source = #"""
        1. first
        2. second
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "1. first\n2. second")
    }

    func testNestedListIndent() {
        let source = #"""
        - outer
          - inner
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "- outer\n  - inner")
    }

    func testTaskItemsAreDisplayMarkersOnly() {
        let source = #"""
        - [x] done **task**
        - [ ] open
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "- [x] done task\n- [ ] open")
    }

    func testBlockquoteIsBodyOnly() {
        let source = #"""
        > quote **line**
        > second
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "quote line\nsecond")
        XCTAssertFalse(plain.contains(">"))
    }

    func testThematicBreakIsDashes() {
        let source = "Above\n\n---\n\nBelow"
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(plain, "Above\n\n---\n\nBelow")
    }

    func testStructuralMixedDocumentWalk() {
        let source = #"""
        # Title

        Intro **text**.

        - one
        - two

        > quote

        ---

        ```swift
        print(1)
        ```
        """#
        let plain = MarkdownPlainText.render(source: source)
        XCTAssertEqual(
            plain,
            "Title\n\nIntro text.\n\n- one\n- two\n\nquote\n\n---\n\nprint(1)"
        )
    }
}
