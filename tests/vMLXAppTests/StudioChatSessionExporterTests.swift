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
                ChatTurn(role: .assistant, content: "<|assistant|>pong<|im_end|>", createdAt: updated),
            ],
            createdAt: created,
            updatedAt: updated,
            isPinned: true
        )

        let data = try StudioChatSessionExporter.data(for: session, format: .markdown)
        let markdown = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(markdown.contains("# Smoke chat session"))
        XCTAssertTrue(markdown.contains("- Model: Qwen3-0.6B-8bit"))
        XCTAssertTrue(markdown.contains("- Turns: 2"))
        XCTAssertTrue(markdown.contains("- Pinned: yes"))
        XCTAssertTrue(markdown.contains("## User"))
        XCTAssertTrue(markdown.contains("Say pong"))
        XCTAssertTrue(markdown.contains("## Assistant"))
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
        XCTAssertTrue(markdown.contains("## Assistant (Failed)"))
        XCTAssertTrue(markdown.contains("Load failed"))
        XCTAssertTrue(markdown.contains("## Assistant (Stopped)"))
        XCTAssertTrue(markdown.contains("Stopped before completion."))
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
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(json.contains("\"title\" : \"Library export session\""))
        XCTAssertTrue(json.contains("\"exportedAt\""))
    }
}
