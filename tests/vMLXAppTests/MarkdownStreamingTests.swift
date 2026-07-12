import XCTest
@testable import vMLXApp

final class MarkdownStreamingTests: XCTestCase {
    func testOpenFenceIsStableCodeNotTail() {
        let source = "Intro\n\n```python\nprint(1)\n"
        let doc = LightweightMarkdownParser.shared.parse(source)
        let split = StreamingMarkdownSplit.split(document: doc, fullSource: source)
        XCTAssertEqual(split.tail, "")
        guard case let .code(lang, body, _, closed) = split.stableBlocks.last else {
            return XCTFail("expected provisional code")
        }
        XCTAssertEqual(lang, "python")
        XCTAssertFalse(closed)
        XCTAssertTrue(body.contains("print(1)"))
    }

    func testCompletedBlocksHaveEmptyTail() {
        let source = "**hi**\n\n```\nx\n```\n"
        let doc = LightweightMarkdownParser.shared.parse(source)
        let split = StreamingMarkdownSplit.split(document: doc, fullSource: source)
        XCTAssertTrue(split.stableBlocks.count >= 2)
        // Trailing newline after closed fence may remain as empty-ish tail
        XCTAssertTrue(split.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || split.tail.hasPrefix("\n"))
    }

    func testTildeFenceParsesAsCode() {
        let source = "~~~\nhello\n~~~"
        let doc = LightweightMarkdownParser.shared.parse(source)
        guard case let .code(_, body, _, closed) = doc.blocks.first else {
            return XCTFail("expected tilde code fence")
        }
        XCTAssertTrue(closed)
        XCTAssertEqual(body, "hello\n")
    }

    func testLanguageNormalization() {
        XCTAssertEqual(MarkdownLanguage.displayName(for: "py"), "Python")
        XCTAssertEqual(MarkdownLanguage.displayName(for: "js"), "JavaScript")
        XCTAssertEqual(MarkdownLanguage.displayName(for: ""), "Code")
    }

    func testTableClipboardMarkdownAndTSV() {
        let md = MarkdownTableClipboard.asMarkdown(
            headers: ["A", "B"],
            alignments: [.leading, .trailing],
            rows: [["1", "2"]]
        )
        XCTAssertTrue(md.contains("| A | B |"))
        XCTAssertTrue(md.contains("| :--- | ---: |"))
        XCTAssertTrue(md.contains("| 1 | 2 |"))

        let tsv = MarkdownTableClipboard.asTSV(headers: ["A", "B"], rows: [["1", "2"]])
        XCTAssertEqual(tsv, "A\tB\n1\t2\n")
    }

    func testDynamicFencesForExport() {
        let body = "code with ``` inside"
        let fenced = ChatExporter.fenced("swift", body)
        XCTAssertTrue(fenced.hasPrefix("````"))
        XCTAssertTrue(fenced.contains("code with ``` inside"))
    }
}

final class ChatMessageContextSplitTests: XCTestCase {
    func testModelPayloadJoinsDisplayAndContext() {
        let m = ChatMessage(
            sessionId: UUID(),
            role: .user,
            content: "Summarize",
            requestContext: "[Document: a.txt]\nhello"
        )
        XCTAssertEqual(m.displayContent, "Summarize")
        XCTAssertTrue(m.modelPayloadContent.contains("Summarize"))
        XCTAssertTrue(m.modelPayloadContent.contains("[Document: a.txt]"))
        XCTAssertFalse(m.content.contains("[Document:"))
    }

    func testExportImportV4PreservesRequestContextAndState() throws {
        let session = ChatSession(
            title: "Ctx",
            modelName: "Local",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let messages = [
            ChatMessage(
                sessionId: session.id,
                role: .user,
                content: "hi",
                requestContext: "DOC",
                createdAt: Date(timeIntervalSince1970: 3)
            ),
            ChatMessage(
                sessionId: session.id,
                role: .assistant,
                content: "**ok**",
                createdAt: Date(timeIntervalSince1970: 4),
                generationState: .complete
            ),
        ]
        let json = ChatExporter.exportToJSON(session, messages: messages)
        XCTAssertTrue(json.contains("\"version\" : 4") || json.contains("\"version\": 4"))
        XCTAssertTrue(json.contains("contentFormat"))
        let imported = try ChatImporter.decode(try XCTUnwrap(json.data(using: String.Encoding.utf8)))
        XCTAssertEqual(imported.messages.first?.content, "hi")
        XCTAssertEqual(imported.messages.first?.requestContext, "DOC")
        XCTAssertEqual(imported.messages.last?.generationState, .complete)
        XCTAssertEqual(imported.messages.last?.content, "**ok**")
    }
}
