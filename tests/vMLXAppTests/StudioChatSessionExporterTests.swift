import Foundation
import XCTest
@testable import vMLXApp

final class StudioChatSessionExporterTests: XCTestCase {
    func testDefaultFilenamesAreSafeAndFormatSpecific() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let session = StudioChatSession(
            id: sessionID,
            title: "Ski slope / catgirl: test?",
            turns: [ChatTurn(role: .user, content: "Hello")]
        )

        XCTAssertEqual(
            StudioChatSessionExporter.defaultFilename(for: session, format: .markdown),
            "Ski slope - catgirl- test-.md"
        )
        XCTAssertEqual(
            StudioChatSessionExporter.defaultFilename(for: session, format: .json),
            "Ski slope - catgirl- test-.json"
        )
        XCTAssertEqual(
            StudioChatSessionExporter.defaultSummaryFilename(for: session),
            "Ski slope - catgirl- test--summary-AAAAAAAA.md"
        )
    }

    func testMarkdownExportIncludesMetadataAndCleanedTurns() throws {
        let created = Date(timeIntervalSince1970: 803_000_000)
        let updated = Date(timeIntervalSince1970: 803_000_010)
        let session = StudioChatSession(
            title: "Smoke chat session",
            modelName: "Qwen3-0.6B-8bit",
            turns: [
                ChatTurn(role: .user, content: "<|user|>Say pong", createdAt: created),
                ChatTurn(
                    role: .assistant,
                    content: "<|assistant|>pong<|im_end|>",
                    createdAt: updated,
                    streamState: .complete
                ),
            ],
            createdAt: created,
            updatedAt: updated,
            isPinned: true
        )

        let data = try StudioChatSessionExporter.data(for: session, format: .markdown)
        let markdown = String(decoding: data, as: UTF8.self)

        // Bridged ChatExporter transcript header + cleaned turn bodies.
        XCTAssertTrue(markdown.contains("# Smoke chat session"))
        XCTAssertTrue(markdown.contains("MLX Studio Markdown transcript"))
        XCTAssertTrue(markdown.contains("Model: Qwen3-0.6B-8bit"))
        XCTAssertTrue(markdown.contains("Messages: 2"))
        XCTAssertTrue(markdown.contains("## User"))
        XCTAssertTrue(markdown.contains("Say pong"))
        XCTAssertTrue(markdown.contains("## Assistant"))
        XCTAssertTrue(markdown.contains("_Generation: complete_"))
        XCTAssertTrue(markdown.contains("pong"))
        XCTAssertFalse(markdown.contains("<|assistant|>"))
        XCTAssertFalse(markdown.contains("<|im_end|>"))
    }

    func testMarkdownExportPreservesNonCompleteTurnState() throws {
        let session = StudioChatSession(
            title: "Recovery export",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "Retry this"),
                ChatTurn(role: .assistant, content: "Load failed", streamState: .failed),
                ChatTurn(role: .assistant, content: "Stopped before completion.", streamState: .cancelled),
            ]
        )

        let data = try StudioChatSessionExporter.data(for: session, format: .markdown)
        let markdown = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(markdown.contains("## User"))
        XCTAssertTrue(markdown.contains("## Assistant"))
        XCTAssertTrue(markdown.contains("_Generation: failed_"))
        XCTAssertTrue(markdown.contains("Load failed"))
        XCTAssertTrue(markdown.contains("_Generation: stopped_"))
        XCTAssertTrue(markdown.contains("Stopped before completion."))
    }

    func testMarkdownExportSurvivesEmbeddedTripleBackticks() throws {
        let bodyWithFence = """
        Here is a sample:
        ```swift
        let x = 1
        ```
        trailing prose
        """
        let session = StudioChatSession(
            title: "Fence safety",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "Show code"),
                ChatTurn(role: .assistant, content: bodyWithFence),
            ]
        )

        let data = try StudioChatSessionExporter.data(for: session, format: .markdown)
        let markdown = String(decoding: data, as: UTF8.self)

        // Content is preserved intact (ChatExporter dumps body; no fixed outer ``` wrapper).
        XCTAssertTrue(markdown.contains("```swift"))
        XCTAssertTrue(markdown.contains("let x = 1"))
        XCTAssertTrue(markdown.contains("trailing prose"))
        XCTAssertTrue(markdown.contains("MLX Studio Markdown transcript"))

        // Dynamic fence helper itself upgrades past embedded triple-backticks.
        let fenced = ChatExporter.fenced("text", bodyWithFence)
        XCTAssertTrue(fenced.hasPrefix("````"))
        XCTAssertTrue(fenced.contains("```swift"))
        XCTAssertTrue(fenced.hasSuffix("````\n") || fenced.contains("\n````\n"))
    }

    func testSummaryExportUsesDynamicFencesForEmbeddedBackticks() {
        let response = """
        Use this snippet:
        ```python
        print("hi")
        ```
        """
        let session = StudioChatSession(
            title: "Summary fence",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "Write python"),
                ChatTurn(role: .assistant, content: response),
            ]
        )

        let summary = StudioChatSessionExporter.summaryMarkdown(for: session)

        // Summary embeds Latest Response via ChatExporter.fenced → 4+ ticks.
        XCTAssertTrue(summary.contains("````text"))
        XCTAssertTrue(summary.contains("```python"))
        XCTAssertTrue(summary.contains("print(\"hi\")"))
        // Closing fence is longer than 3 so the inner ```python fence stays open until close.
        XCTAssertTrue(summary.contains("````"))
        XCTAssertTrue(summary.contains("## Latest Response"))
        XCTAssertTrue(summary.contains("## Purpose"))
        XCTAssertTrue(summary.contains("Write python"))
    }

    func testSummaryExportFencesMultilinePlainBodiesWithoutBackticks() {
        let response = """
        # Not a summary heading
        ---
        second line
        """
        let session = StudioChatSession(
            title: "Multiline summary",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "Explain"),
                ChatTurn(role: .assistant, content: response),
            ]
        )

        let summary = StudioChatSessionExporter.summaryMarkdown(for: session)

        // Multi-line plain text is fenced so # / --- cannot break section structure.
        XCTAssertTrue(summary.contains("```text"))
        XCTAssertTrue(summary.contains("# Not a summary heading"))
        XCTAssertTrue(summary.contains("---"))
        XCTAssertTrue(summary.contains("second line"))
        // Single-line purpose stays unfenced for readability.
        let purposeRange = try! XCTUnwrap(
            summary.range(of: "## Purpose\n\n")
        )
        let afterPurpose = summary[purposeRange.upperBound...]
        XCTAssertTrue(afterPurpose.hasPrefix("Explain\n"))
    }

    func testJSONExportWrapsSessionWithSchemaAndExportTimestamp() throws {
        let exportedAt = Date(timeIntervalSince1970: 803_000_100)
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let turnID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let session = StudioChatSession(
            id: sessionID,
            title: "JSON session",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(
                    id: turnID,
                    role: .assistant,
                    content: "Structured answer",
                    streamState: .complete
                ),
            ],
            isPinned: false
        )

        let data = try StudioChatSessionExporter.data(
            for: session,
            format: .json,
            exportedAt: exportedAt
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let exported = try XCTUnwrap(object["exportedAt"] as? String)
        let exportedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: exported))
        let encodedSession = try XCTUnwrap(object["session"] as? [String: Any])
        let turns = try XCTUnwrap(encodedSession["turns"] as? [[String: Any]])

        // Studio JSON remains schemaVersion 1 (not ChatExporter v4).
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(exportedDate, exportedAt)
        XCTAssertEqual(encodedSession["id"] as? String, sessionID.uuidString)
        XCTAssertEqual(encodedSession["title"] as? String, "JSON session")
        XCTAssertEqual(encodedSession["modelName"] as? String, "Smoke Model")
        XCTAssertEqual(turns.first?["id"] as? String, turnID.uuidString)
        XCTAssertEqual(turns.first?["role"] as? String, "assistant")
        XCTAssertEqual(turns.first?["content"] as? String, "Structured answer")
    }

    func testJSONExportOmitsLocalSummaryMetadata() throws {
        let session = StudioChatSession(
            title: "Portable export",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "Export without local paths"),
                ChatTurn(role: .assistant, content: "Portable answer"),
            ],
            summaryExportPath: "/Users/hermes/Library/Application Support/vMLX/chat-summaries/Portable export-summary-11111111.md",
            summaryExportedAt: Date(timeIntervalSince1970: 803_000_150)
        )

        let data = try StudioChatSessionExporter.data(
            for: session,
            format: .json,
            exportedAt: Date(timeIntervalSince1970: 803_000_151)
        )
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("summaryExportPath"))
        XCTAssertFalse(json.contains("summaryExportedAt"))
        XCTAssertFalse(json.contains("/Users/hermes/Library/Application Support/vMLX"))
        XCTAssertTrue(json.contains("Portable answer"))
    }

    func testStudioJSONExportImportsThroughCanonicalChatImporter() throws {
        let created = Date(timeIntervalSince1970: 803_000_151)
        let session = StudioChatSession(
            title: "Portable round trip",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "<|user|>Keep this prompt", createdAt: created),
                ChatTurn(
                    role: .assistant,
                    content: "<|assistant|>Keep this partial answer",
                    createdAt: created.addingTimeInterval(1),
                    streamState: .streaming
                ),
            ],
            systemPrompt: "Always cite the local source.",
            maxResponseTokens: 777,
            contextLimitTokens: 65_536,
            createdAt: created,
            updatedAt: created.addingTimeInterval(1),
            isPinned: true
        )

        let exported = try StudioChatSessionExporter.data(for: session, format: .json)
        let imported = try ChatImporter.decode(
            exported,
            now: created.addingTimeInterval(2)
        )

        XCTAssertNotEqual(imported.session.id, session.id)
        XCTAssertEqual(imported.session.title, "Portable round trip")
        XCTAssertEqual(imported.session.modelName, "Smoke Model")
        XCTAssertTrue(imported.session.isPinned)
        XCTAssertEqual(
            imported.messages.map(\.content),
            ["Always cite the local source.", "Keep this prompt", "Keep this partial answer"]
        )
        XCTAssertEqual(
            imported.messages.map(\.sessionId),
            [imported.session.id, imported.session.id, imported.session.id]
        )
        XCTAssertEqual(imported.messages.first?.role, .system)
        XCTAssertEqual(imported.messages.last?.generationState, .interrupted)
        XCTAssertEqual(imported.chatSettings?.maxTokens, 777)
        XCTAssertEqual(imported.chatSettings?.maxPromptTokens, 65_536)
    }

    func testSummaryExportWritesSessionBriefToDirectory() throws {
        let exportedAt = Date(timeIntervalSince1970: 803_000_200)
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let session = StudioChatSession(
            id: sessionID,
            title: "Recovery session",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "<|user|>Explain the failure", streamState: .complete),
                ChatTurn(role: .assistant, content: "<|assistant|>It failed while loading.", streamState: .failed),
            ],
            isPinned: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try StudioChatSessionExporter.writeSummary(
            for: session,
            directory: directory,
            exportedAt: exportedAt
        )
        let markdown = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(url.lastPathComponent, "Recovery session-summary-11111111.md")
        XCTAssertTrue(markdown.contains("# Recovery session Summary"))
        XCTAssertTrue(markdown.contains("- Model: Smoke Model"))
        XCTAssertTrue(markdown.contains("- Failed turns: 1"))
        XCTAssertTrue(markdown.contains("- Pinned: yes"))
        XCTAssertTrue(markdown.contains("Explain the failure"))
        XCTAssertTrue(markdown.contains("It failed while loading."))
        XCTAssertTrue(markdown.contains("Recover or explain 1 failed turn"))
        XCTAssertFalse(markdown.contains("<|assistant|>"))
    }

    func testExportWritesMarkdownAndJSONToDirectory() throws {
        let exportedAt = Date(timeIntervalSince1970: 803_000_300)
        let sessionID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let session = StudioChatSession(
            id: sessionID,
            title: "Library export session",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "Export this prompt"),
                ChatTurn(role: .assistant, content: "Export this answer"),
            ],
            isPinned: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-chat-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markdownURL = try StudioChatSessionExporter.write(
            for: session,
            format: .markdown,
            directory: directory,
            exportedAt: exportedAt
        )
        let jsonURL = try StudioChatSessionExporter.write(
            for: session,
            format: .json,
            directory: directory,
            exportedAt: exportedAt
        )
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let json = try String(contentsOf: jsonURL, encoding: .utf8)

        XCTAssertEqual(markdownURL.lastPathComponent, "Library export session.md")
        XCTAssertEqual(jsonURL.lastPathComponent, "Library export session.json")
        XCTAssertTrue(markdown.contains("# Library export session"))
        XCTAssertTrue(markdown.contains("Export this answer"))
        XCTAssertTrue(markdown.contains("MLX Studio Markdown transcript"))
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(json.contains("\"title\" : \"Library export session\""))
        XCTAssertTrue(json.contains("\"exportedAt\""))
    }

    func testBridgeMapsStudioSessionToChatTypes() {
        let sessionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let turnID = UUID(uuidString: "ffffffff-0000-1111-2222-333333333333")!
        let created = Date(timeIntervalSince1970: 1_000)
        let session = StudioChatSession(
            id: sessionID,
            title: "Bridge",
            modelName: "Local-Model",
            turns: [
                ChatTurn(id: turnID, role: .user, content: "<|user|>Hi", createdAt: created),
                ChatTurn(role: .assistant, content: "Done", streamState: .complete),
                ChatTurn(role: .assistant, content: "Hello", streamState: .failed),
                ChatTurn(role: .assistant, content: "Stopped mid-way", streamState: .cancelled),
                ChatTurn(role: .assistant, content: "Still open", streamState: .streaming),
            ],
            createdAt: created,
            isPinned: true
        )

        let chat = StudioChatExportBridge.chatSession(from: session)
        let messages = StudioChatExportBridge.messages(from: session)

        XCTAssertEqual(chat.id, sessionID)
        XCTAssertEqual(chat.title, "Bridge")
        XCTAssertEqual(chat.modelName, "Local-Model")
        XCTAssertTrue(chat.isPinned)
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0].id, turnID)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Hi")
        XCTAssertEqual(messages[0].requestContext, "")
        // User turns never carry generationState (assistant-terminal field).
        XCTAssertNil(messages[0].generationState)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].generationState, .complete) // production parity
        XCTAssertEqual(messages[2].generationState, .failed)
        XCTAssertEqual(messages[3].generationState, .stopped)
        XCTAssertEqual(messages[4].generationState, .interrupted)
    }
}
