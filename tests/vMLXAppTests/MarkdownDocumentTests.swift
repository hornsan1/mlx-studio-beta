import XCTest
@testable import vMLXApp

final class MarkdownDocumentTests: XCTestCase {
    private let parser = LightweightMarkdownParser.shared

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
        XCTAssertEqual(document.parserName, "lightweight-gfm-lite")

        var table: (
            headers: [String],
            alignments: [MarkdownTableAlignment],
            rows: [[String]]
        )?
        var code: (language: String, body: String, isClosed: Bool)?

        for block in document.blocks {
            switch block {
            case let .table(headers, alignments, rows, _):
                table = (headers, alignments, rows)
            case let .code(language, body, _, isClosed):
                code = (language, body, isClosed)
            case .prose, .heading, .listItem, .taskItem, .blockquote, .thematicBreak, .fallback:
                break
            }
        }

        XCTAssertEqual(table?.headers, ["Check", "Result"])
        XCTAssertEqual(table?.alignments, [.leading, .leading])
        XCTAssertEqual(table?.rows, [["Table", "PASS"]])
        XCTAssertEqual(code?.language, "swift")
        XCTAssertEqual(code?.body, "print(\"MARKDOWN_E2E\")\n")
        XCTAssertEqual(code?.isClosed, true)
    }

    func testStableBlockIDsUseMessageAndRange() {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let source = #"""
        Hello

        ```swift
        print(1)
        ```
        """#
        let document = parser.parse(source)
        let ids = document.blockIDs(messageID: messageID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0].kind, .prose)
        XCTAssertEqual(ids[1].kind, .code)

        let copyID = ids[1].copyCodeAccessibilityIdentifier
        XCTAssertTrue(copyID.hasPrefix("markdown.copy-code.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee."))
        XCTAssertTrue(copyID.contains("-\(ids[1].range.end)"))

        // Same source + same message → identical IDs (stable across reloads).
        let again = parser.parse(source).blockIDs(messageID: messageID)
        XCTAssertEqual(ids, again)
    }

    func testUnclosedFenceBecomesCode() {
        let source = "Intro\n\n```python\nprint(1)\n"
        let document = parser.parse(source)
        guard case let .code(language, body, _, isClosed) = document.blocks.last else {
            return XCTFail("Expected trailing code block for unclosed fence")
        }
        XCTAssertEqual(language, "python")
        XCTAssertEqual(body, "print(1)\n")
        XCTAssertFalse(isClosed)
    }

    func testSourceRangesCoverNormalizedSource() {
        let source = "A\r\n\r\n```\nB\n```"
        let document = parser.parse(source)
        XCTAssertFalse(document.source.contains("\r"))
        for block in document.blocks {
            XCTAssertGreaterThanOrEqual(block.range.start, 0)
            XCTAssertLessThanOrEqual(block.range.end, document.source.utf16.count)
            XCTAssertLessThanOrEqual(block.range.start, block.range.end)
        }
    }

    func testCompatibilityParseMatchesDocument() {
        let source = #"""
        | Expression | Value | Notes |
        | :--- | :---: | ---: |
        | `a|b` | x \| y | right |
        """#
        let segments = MarkdownView.parse(source)
        let document = parser.parse(source)
        XCTAssertEqual(segments.count, document.blocks.count)
        guard case let .table(headers, alignments, rows) = segments.first,
              case let .table(dHeaders, dAlignments, dRows, _) = document.blocks.first
        else {
            return XCTFail("Expected table in both paths")
        }
        XCTAssertEqual(headers, dHeaders)
        XCTAssertEqual(alignments.map { MarkdownTableAlignment(legacy: $0) }, dAlignments)
        XCTAssertEqual(rows, dRows)
    }

    func testGoldenCorpusFixture() throws {
        let url = goldenCorpusURL()
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cases = try XCTUnwrap(root?["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty, "Golden corpus must contain cases")

        for entry in cases {
            let id = try XCTUnwrap(entry["id"] as? String)
            let source = try XCTUnwrap(entry["source"] as? String)
            let expect = try XCTUnwrap(entry["expect"] as? [String: Any])
            let document = parser.parse(source)
            let kinds = document.blocks.map(\.kind.rawValue)
            if let expectedKinds = expect["blockKinds"] as? [String] {
                XCTAssertEqual(kinds, expectedKinds, "case \(id) block kinds")
            }
            if let expectedTable = expect["table"] as? [String: Any] {
                guard case let .table(headers, alignments, rows, _) = document.blocks.first(where: {
                    if case .table = $0 { return true }
                    return false
                }) else {
                    XCTFail("case \(id): missing table")
                    continue
                }
                XCTAssertEqual(headers, expectedTable["headers"] as? [String], "case \(id) headers")
                let expectedAlign = expectedTable["alignments"] as? [String] ?? []
                XCTAssertEqual(alignments.map(\.rawValue), expectedAlign, "case \(id) alignments")
                XCTAssertEqual(rows, expectedTable["rows"] as? [[String]], "case \(id) rows")
            }
            if let expectedCode = expect["code"] as? [String: Any] {
                guard case let .code(language, body, _, isClosed) = document.blocks.first(where: {
                    if case .code = $0 { return true }
                    return false
                }) else {
                    XCTFail("case \(id): missing code")
                    continue
                }
                XCTAssertEqual(language, expectedCode["language"] as? String ?? "", "case \(id) language")
                XCTAssertEqual(body, expectedCode["body"] as? String ?? "", "case \(id) body")
                if let closed = expectedCode["isClosed"] as? Bool {
                    XCTAssertEqual(isClosed, closed, "case \(id) isClosed")
                }
            }
            if let literal = expect["containsLiteral"] as? String {
                XCTAssertTrue(document.source.contains(literal), "case \(id) containsLiteral")
            }
            if let expectedListItems = expect["listItems"] as? [[String: Any]] {
                let actual = document.blocks.compactMap { block -> [String: Any]? in
                    guard case let .listItem(ordered, index, indentLevel, text, _) = block else {
                        return nil
                    }
                    var dict: [String: Any] = [
                        "ordered": ordered,
                        "indentLevel": indentLevel,
                        "text": text
                    ]
                    if let index { dict["index"] = index }
                    return dict
                }
                XCTAssertEqual(actual.count, expectedListItems.count, "case \(id) listItems count")
                for (idx, expected) in expectedListItems.enumerated() where idx < actual.count {
                    let got = actual[idx]
                    XCTAssertEqual(got["ordered"] as? Bool, expected["ordered"] as? Bool, "case \(id) listItems[\(idx)].ordered")
                    XCTAssertEqual(got["indentLevel"] as? Int, expected["indentLevel"] as? Int, "case \(id) listItems[\(idx)].indentLevel")
                    XCTAssertEqual(got["text"] as? String, expected["text"] as? String, "case \(id) listItems[\(idx)].text")
                    if let expectedIndex = expected["index"] as? Int {
                        XCTAssertEqual(got["index"] as? Int, expectedIndex, "case \(id) listItems[\(idx)].index")
                    }
                }
            }
            if let expectedTasks = expect["taskItems"] as? [[String: Any]] {
                let actual = document.blocks.compactMap { block -> [String: Any]? in
                    guard case let .taskItem(checked, indentLevel, text, _) = block else {
                        return nil
                    }
                    return [
                        "checked": checked,
                        "indentLevel": indentLevel,
                        "text": text
                    ]
                }
                XCTAssertEqual(actual.count, expectedTasks.count, "case \(id) taskItems count")
                for (idx, expected) in expectedTasks.enumerated() where idx < actual.count {
                    let got = actual[idx]
                    XCTAssertEqual(got["checked"] as? Bool, expected["checked"] as? Bool, "case \(id) taskItems[\(idx)].checked")
                    XCTAssertEqual(got["indentLevel"] as? Int, expected["indentLevel"] as? Int, "case \(id) taskItems[\(idx)].indentLevel")
                    XCTAssertEqual(got["text"] as? String, expected["text"] as? String, "case \(id) taskItems[\(idx)].text")
                }
            }
            if let expectedHeadings = expect["headings"] as? [[String: Any]] {
                let actual = document.blocks.compactMap { block -> [String: Any]? in
                    guard case let .heading(level, text, _) = block else { return nil }
                    return ["level": level, "text": text]
                }
                XCTAssertEqual(actual.count, expectedHeadings.count, "case \(id) headings count")
                for (idx, expected) in expectedHeadings.enumerated() where idx < actual.count {
                    let got = actual[idx]
                    XCTAssertEqual(got["level"] as? Int, expected["level"] as? Int, "case \(id) headings[\(idx)].level")
                    XCTAssertEqual(got["text"] as? String, expected["text"] as? String, "case \(id) headings[\(idx)].text")
                }
            }
            if let expectedQuote = expect["blockquote"] as? [String: Any] {
                guard case let .blockquote(text, quoteDepth, _) = document.blocks.first(where: {
                    if case .blockquote = $0 { return true }
                    return false
                }) else {
                    XCTFail("case \(id): missing blockquote")
                    continue
                }
                if let depth = expectedQuote["quoteDepth"] as? Int {
                    XCTAssertEqual(quoteDepth, depth, "case \(id) quoteDepth")
                }
                if let expectedText = expectedQuote["text"] as? String {
                    XCTAssertEqual(text, expectedText, "case \(id) blockquote text")
                }
            }
        }
    }

    func testStructuralListOrderedNestedContinue() {
        let source = "1. parent a\n   1. nested\n2. parent b"
        let document = parser.parse(source)
        XCTAssertEqual(document.blocks.map(\.kind), [.listItem, .listItem, .listItem])
        guard case let .listItem(o0, i0, l0, t0, _) = document.blocks[0],
              case let .listItem(o1, i1, l1, t1, _) = document.blocks[1],
              case let .listItem(o2, i2, l2, t2, _) = document.blocks[2]
        else {
            return XCTFail("expected three list items")
        }
        XCTAssertTrue(o0 && o1 && o2)
        XCTAssertEqual(i0, 1)
        XCTAssertEqual(l0, 0)
        XCTAssertEqual(t0, "parent a")
        XCTAssertEqual(i1, 1)
        XCTAssertEqual(l1, 1)
        XCTAssertEqual(t1, "nested")
        XCTAssertEqual(i2, 2)
        XCTAssertEqual(l2, 0)
        XCTAssertEqual(t2, "parent b")
    }

    func testLooseOrderedListDoesNotResetOnBlankLine() {
        let document = parser.parse("1. a\n\n2. b")
        XCTAssertEqual(document.blocks.map(\.kind), [.listItem, .listItem])
        guard case let .listItem(_, i0, _, _, _) = document.blocks[0],
              case let .listItem(_, i1, _, _, _) = document.blocks[1]
        else {
            return XCTFail("expected list items")
        }
        XCTAssertEqual(i0, 1)
        XCTAssertEqual(i1, 2)
    }

    private func goldenCorpusURL() -> URL {
        // tests/vMLXAppTests → tests/e2e/fixtures/markdown-golden.json
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("e2e/fixtures/markdown-golden.json")
    }
}

private extension MarkdownTableAlignment {
    init(legacy: MarkdownView.TableAlignment) {
        switch legacy {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        }
    }
}
