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

    // MARK: - Provisional block IDs (K13)

    func testOpenFenceCopyIDIsEndInvariantWhileGrowing() throws {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let early = "Intro\n\n```python\nprint(1)\n"
        let grown = "Intro\n\n```python\nprint(1)\nprint(2)\n"

        let earlyDoc = LightweightMarkdownParser.shared.parse(early)
        let grownDoc = LightweightMarkdownParser.shared.parse(grown)

        let earlyID = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(earlyDoc.blocks.last),
            source: earlyDoc.source,
            isStreaming: true
        )
        let grownID = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(grownDoc.blocks.last),
            source: grownDoc.source,
            isStreaming: true
        )

        XCTAssertTrue(earlyID.isProvisional)
        XCTAssertTrue(grownID.isProvisional)
        XCTAssertEqual(earlyID, grownID)
        XCTAssertEqual(
            earlyID.copyCodeAccessibilityIdentifier,
            grownID.copyCodeAccessibilityIdentifier
        )
        XCTAssertTrue(earlyID.copyCodeAccessibilityIdentifier.hasSuffix("-open"))
        XCTAssertTrue(
            earlyID.copyCodeAccessibilityIdentifier
                .hasPrefix("markdown.copy-code.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.")
        )
        // range.end may differ; identity must not.
        XCTAssertNotEqual(earlyID.range.end, grownID.range.end)
    }

    func testClosedFenceFreezesFullRangeID() throws {
        let messageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let source = "Intro\n\n```python\nprint(1)\n```\n"
        let doc = LightweightMarkdownParser.shared.parse(source)
        let id = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(doc.blocks.last),
            source: doc.source,
            isStreaming: false
        )
        XCTAssertFalse(id.isProvisional)
        XCTAssertTrue(id.copyCodeAccessibilityIdentifier.hasSuffix("-\(id.range.end)"))
        XCTAssertFalse(id.copyCodeAccessibilityIdentifier.hasSuffix("-open"))

        // Same frozen source → identical IDs on reparse.
        let again = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(LightweightMarkdownParser.shared.parse(source).blocks.last),
            source: source,
            isStreaming: false
        )
        XCTAssertEqual(id, again)
    }

    func testTerminalGrowingProseIDIsEndInvariantWhileStreaming() {
        let messageID = UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let early = "Hello world"
        let grown = "Hello world, more tokens arrive"

        let earlyDoc = LightweightMarkdownParser.shared.parse(early)
        let grownDoc = LightweightMarkdownParser.shared.parse(grown)

        XCTAssertEqual(earlyDoc.blocks.count, 1)
        XCTAssertEqual(grownDoc.blocks.count, 1)

        let earlyID = MarkdownBlockID.id(
            messageID: messageID,
            block: earlyDoc.blocks[0],
            source: earlyDoc.source,
            isStreaming: true
        )
        let grownID = MarkdownBlockID.id(
            messageID: messageID,
            block: grownDoc.blocks[0],
            source: grownDoc.source,
            isStreaming: true
        )

        XCTAssertTrue(earlyID.isProvisional)
        XCTAssertTrue(grownID.isProvisional)
        XCTAssertEqual(earlyID.accessibilityIdentifier, grownID.accessibilityIdentifier)
        XCTAssertTrue(earlyID.accessibilityIdentifier.hasSuffix("-open"))
        XCTAssertEqual(earlyID, grownID)

        // When streaming ends, identity freezes to full range.
        let finalID = MarkdownBlockID.id(
            messageID: messageID,
            block: grownDoc.blocks[0],
            source: grownDoc.source,
            isStreaming: false
        )
        XCTAssertFalse(finalID.isProvisional)
        XCTAssertTrue(finalID.accessibilityIdentifier.hasSuffix("-\(finalID.range.end)"))
        XCTAssertNotEqual(finalID, grownID)
    }

    func testOpenFenceIsProvisionalEvenWhenNotStreaming() throws {
        // Truncated / interrupted content keeps open-fence provisional so
        // copy IDs stay start-stable if the user reopens the message.
        let source = "```\npartial\n"
        let doc = LightweightMarkdownParser.shared.parse(source)
        let id = MarkdownBlockID.id(
            messageID: nil,
            block: try XCTUnwrap(doc.blocks.first),
            source: doc.source,
            isStreaming: false
        )
        XCTAssertTrue(id.isProvisional)
        XCTAssertTrue(id.accessibilityIdentifier.hasSuffix("-open"))
    }

    /// Regression: throttled `document` lags live stream text. IDs must be
    /// computed against `document.source` (and last-stable hardening), never
    /// live text length — otherwise terminal prose flips provisional→frozen→open
    /// between reparses and remounts ForEach.
    func testStaleDocumentVsLiveTextKeepsTerminalIDProvisional() throws {
        let messageID = UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let early = "Hello"
        let grown = "Hello!"

        let staleDoc = LightweightMarkdownParser.shared.parse(early)
        XCTAssertEqual(staleDoc.blocks.count, 1)
        let last = try XCTUnwrap(staleDoc.blocks.last)

        // Correct call site: parse-basis source + last stable while streaming.
        let idFromDocument = MarkdownBlockID.id(
            messageID: messageID,
            block: last,
            source: staleDoc.source,
            isStreaming: true,
            isLastStableBlock: true
        )
        XCTAssertTrue(idFromDocument.isProvisional)
        XCTAssertTrue(idFromDocument.accessibilityIdentifier.hasSuffix("-open"))

        // Bug pattern (live text ahead of reparse) without last-stable flag:
        // range.end (5) != grown.utf16.count (6) → incorrectly non-provisional.
        let buggyLive = MarkdownBlockID.id(
            messageID: messageID,
            block: last,
            source: grown,
            isStreaming: true,
            isLastStableBlock: false
        )
        XCTAssertFalse(
            buggyLive.isProvisional,
            "documents the thrash: live source without last-stable de-provisionalises"
        )
        XCTAssertNotEqual(buggyLive, idFromDocument)

        // Hardening: even if a caller passes live grown source, last-stable
        // keeps identity provisional and equal to the document-source ID.
        let hardenedLive = MarkdownBlockID.id(
            messageID: messageID,
            block: last,
            source: grown,
            isStreaming: true,
            isLastStableBlock: true
        )
        XCTAssertTrue(hardenedLive.isProvisional)
        XCTAssertEqual(hardenedLive, idFromDocument)
        XCTAssertEqual(
            hardenedLive.accessibilityIdentifier,
            idFromDocument.accessibilityIdentifier
        )

        // Streaming split peels live growth into tail; stable last block is
        // still the stale parse — ID must match document-source provisional ID.
        let split = StreamingMarkdownSplit.split(document: staleDoc, fullSource: grown)
        XCTAssertEqual(split.stableBlocks.count, 1)
        XCTAssertFalse(split.tail.isEmpty)
        let splitLast = try XCTUnwrap(split.stableBlocks.last)
        let splitID = MarkdownBlockID.id(
            messageID: messageID,
            block: splitLast,
            source: staleDoc.source,
            isStreaming: true,
            isLastStableBlock: true
        )
        XCTAssertEqual(splitID, idFromDocument)

        // After reparse of grown text, same start + streaming → still equal.
        let grownDoc = LightweightMarkdownParser.shared.parse(grown)
        let reparsedID = MarkdownBlockID.id(
            messageID: messageID,
            block: try XCTUnwrap(grownDoc.blocks.last),
            source: grownDoc.source,
            isStreaming: true,
            isLastStableBlock: true
        )
        XCTAssertTrue(reparsedID.isProvisional)
        XCTAssertEqual(reparsedID, idFromDocument)
    }

    func testOpenFenceIDStableWhenLiveSourceGrowsBeforeReparse() throws {
        let messageID = UUID(uuidString: "DDDDDDDD-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let early = "```swift\nprint(1)\n"
        let grown = "```swift\nprint(1)\nprint(2)\n"
        let staleDoc = LightweightMarkdownParser.shared.parse(early)
        let last = try XCTUnwrap(staleDoc.blocks.last)
        guard case .code(_, _, _, let closed) = last else {
            return XCTFail("expected open fence")
        }
        XCTAssertFalse(closed)

        let withDoc = MarkdownBlockID.id(
            messageID: messageID,
            block: last,
            source: staleDoc.source,
            isStreaming: true
        )
        // Open fence stays provisional via !isClosed even against live grown source.
        let withLive = MarkdownBlockID.id(
            messageID: messageID,
            block: last,
            source: grown,
            isStreaming: true
        )
        XCTAssertTrue(withDoc.isProvisional)
        XCTAssertTrue(withLive.isProvisional)
        XCTAssertEqual(withDoc, withLive)
        XCTAssertTrue(withDoc.copyCodeAccessibilityIdentifier.hasSuffix("-open"))
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
