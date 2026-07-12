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

    // MARK: - Provisional block IDs

    func testOpenFenceCopyIDIsEndInvariantWhileGrowing() throws {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let early = "Intro\n\n```python\nprint(1)\n"
        let grown = "Intro\n\n```python\nprint(1)\nprint(2)\n"

        let earlyDoc = LightweightMarkdownParser.shared.parse(early)
        let grownDoc = LightweightMarkdownParser.shared.parse(grown)

        let earlyID = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(earlyDoc.blocks.last),
            isStreaming: true
        )
        let grownID = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(grownDoc.blocks.last),
            isStreaming: true
        )

        XCTAssertTrue(earlyID.isProvisional)
        XCTAssertTrue(grownID.isProvisional)
        XCTAssertEqual(earlyID, grownID)
        XCTAssertTrue(earlyID.copyCodeAccessibilityIdentifier.hasSuffix("-open"))
        XCTAssertNotEqual(earlyID.range.end, grownID.range.end)
    }

    func testClosedFenceFreezesFullRangeID() throws {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let source = "Intro\n\n```python\nprint(1)\n```\n"
        let doc = LightweightMarkdownParser.shared.parse(source)
        let id = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(doc.blocks.last),
            isStreaming: false
        )
        XCTAssertFalse(id.isProvisional)
        XCTAssertTrue(id.copyCodeAccessibilityIdentifier.hasSuffix("-\(id.range.end)"))
    }

    func testTerminalGrowingProseIDIsEndInvariantWhileStreaming() {
        let messageID = UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let early = "Hello world"
        let grown = "Hello world, more tokens arrive"

        let earlyDoc = LightweightMarkdownParser.shared.parse(early)
        let grownDoc = LightweightMarkdownParser.shared.parse(grown)

        let earlyID = MarkdownBlockID.id(
            messageID: messageID,
            block: earlyDoc.blocks[0],
            isStreaming: true,
            isLastBlock: true
        )
        let grownID = MarkdownBlockID.id(
            messageID: messageID,
            block: grownDoc.blocks[0],
            isStreaming: true,
            isLastBlock: true
        )

        XCTAssertTrue(earlyID.isProvisional)
        XCTAssertTrue(grownID.isProvisional)
        XCTAssertEqual(earlyID, grownID)
        XCTAssertTrue(earlyID.accessibilityIdentifier.hasSuffix("-open"))

        let finalID = MarkdownBlockID.id(
            messageID: messageID,
            block: grownDoc.blocks[0],
            isStreaming: false
        )
        XCTAssertFalse(finalID.isProvisional)
        XCTAssertNotEqual(finalID, earlyID)
    }

    func testLastBlockWhileStreamingIsProvisionalEvenIfClosed() throws {
        let messageID = UUID()
        let source = "```\nx\n```"
        let doc = LightweightMarkdownParser.shared.parse(source)
        let block = try XCTUnwrap(doc.blocks.last)
        let streaming = MarkdownBlockID.id(
            messageID: messageID,
            block: block,
            isStreaming: true,
            isLastBlock: true
        )
        let done = MarkdownBlockID.id(
            messageID: messageID,
            block: block,
            isStreaming: false
        )
        XCTAssertTrue(streaming.isProvisional)
        XCTAssertFalse(done.isProvisional)
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
        let imported = try ChatImporter.decode(try XCTUnwrap(json.data(using: String.Encoding.utf8)))
        XCTAssertEqual(imported.messages.first?.content, "hi")
        XCTAssertEqual(imported.messages.first?.requestContext, "DOC")
        XCTAssertEqual(imported.messages.last?.generationState, .complete)
    }
}
