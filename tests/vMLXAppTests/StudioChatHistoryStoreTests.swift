import Foundation
import MLXStudioDomain
import XCTest
@testable import vMLXApp
import vMLXEngine

final class StudioChatHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ai.dealign.mlxstudio.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSaveLoadSortsPinnedFirstCleansStreamingAndDropsEmptySessions() {
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let pinned = StudioChatSession(
            title: "New Chat",
            modelName: "Smoke Model",
            turns: [
                ChatTurn(role: .user, content: "Pinned prompt", createdAt: old),
                ChatTurn(role: .assistant, content: "", createdAt: old, streamState: .streaming),
            ],
            createdAt: old,
            updatedAt: old,
            isPinned: true
        )
        let unpinned = StudioChatSession(
            title: "Newest unpinned",
            modelName: "Smoke Model B",
            turns: [ChatTurn(role: .user, content: "Second prompt", createdAt: newer)],
            createdAt: newer,
            updatedAt: newer,
            isPinned: false
        )
        let empty = StudioChatSession(
            title: "Empty",
            turns: [],
            createdAt: newer,
            updatedAt: newer
        )

        StudioChatHistoryStore.saveSessions([empty, unpinned, pinned], defaults: defaults)
        let loaded = StudioChatHistoryStore.loadSessions(defaults: defaults)

        XCTAssertEqual(loaded.map(\.title), ["Pinned prompt", "Newest unpinned"])
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded[0].isPinned)
        XCTAssertEqual(loaded[0].turns.last?.streamState, .cancelled)
        XCTAssertEqual(loaded[0].turns.last?.content, "Stopped before completion.")
    }

    func testDeleteSessionRemovesOnlyRequestedSession() {
        let keepID = UUID()
        let deleteID = UUID()
        let keep = StudioChatSession(
            id: keepID,
            title: "Keep",
            turns: [ChatTurn(role: .user, content: "Keep prompt")]
        )
        let remove = StudioChatSession(
            id: deleteID,
            title: "Delete",
            turns: [ChatTurn(role: .user, content: "Delete prompt")]
        )

        StudioChatHistoryStore.saveSessions([keep, remove], defaults: defaults)
        StudioChatHistoryStore.deleteSession(deleteID, defaults: defaults)

        let loaded = StudioChatHistoryStore.loadSessions(defaults: defaults)
        XCTAssertEqual(loaded.map(\.id), [keepID])
        XCTAssertEqual(loaded.first?.title, "Keep")
    }

    func testSummaryExportMetadataPersistsWithSession() {
        let exported = Date(timeIntervalSince1970: 803_000_500)
        let session = StudioChatSession(
            title: "Saved summary chat",
            turns: [ChatTurn(role: .user, content: "Keep this handoff")],
            summaryExportPath: "/tmp/Saved summary chat-summary-11111111.md",
            summaryExportedAt: exported
        )

        StudioChatHistoryStore.saveSessions([session], defaults: defaults)

        let loaded = StudioChatHistoryStore.loadSessions(defaults: defaults)
        XCTAssertEqual(loaded.first?.summaryExportPath, "/tmp/Saved summary chat-summary-11111111.md")
        XCTAssertEqual(loaded.first?.summaryExportedAt, exported)
        XCTAssertEqual(loaded.first?.hasSummaryExport, true)
    }

    func testRuntimeControlsPersistWithSession() {
        let session = StudioChatSession(
            title: "Runtime chat",
            turns: [ChatTurn(role: .user, content: "Use the saved controls")],
            systemPrompt: "  Be precise.  ",
            maxResponseTokens: 2_048,
            contextLimitTokens: 32_768
        )

        StudioChatHistoryStore.saveSessions([session], defaults: defaults)

        let loaded = StudioChatHistoryStore.loadSessions(defaults: defaults)
        XCTAssertEqual(loaded.first?.systemPrompt, "Be precise.")
        XCTAssertEqual(loaded.first?.maxResponseTokens, 2_048)
        XCTAssertEqual(loaded.first?.contextLimitTokens, 32_768)
    }

    func testRuntimeRequestMessagesInsertSystemPromptAndClampBudgets() {
        let messages = StudioChatRuntime.requestMessages(
            systemPrompt: "  You are concise.  ",
            turns: [ChatTurn(role: .user, content: "Hi")]
        )

        XCTAssertEqual(messages.map(\.role), ["system", "user"])
        XCTAssertEqual(stringContent(messages[0]), "You are concise.")
        XCTAssertEqual(stringContent(messages[1]), "Hi")
        let generationMessages = StudioChatRuntime.generationMessages(
            systemPrompt: "  You are concise.  ",
            turns: [ChatTurn(role: .user, content: "Hi")]
        )
        XCTAssertEqual(generationMessages.map(\.role), [.system, .user])
        XCTAssertEqual(generationMessages.map(\.content), ["You are concise.", "Hi"])
        XCTAssertEqual(StudioChatRuntime.sanitizedMaxResponseTokens(-50), 1)
        XCTAssertEqual(StudioChatRuntime.sanitizedContextLimitTokens(2_000_000), 1_000_000)
        XCTAssertGreaterThan(
            StudioChatRuntime.estimatedContextTokens(
                systemPrompt: "You are concise.",
                turns: [ChatTurn(role: .user, content: "Hi")],
                draftPrompt: ""
            ),
            0
        )
    }

    func testSelectedSessionIDPersistsAndClearsWhenInvalid() {
        let keepID = UUID()
        let missingID = UUID()
        let keep = StudioChatSession(
            id: keepID,
            title: "Keep",
            turns: [ChatTurn(role: .user, content: "Keep prompt")]
        )

        StudioChatHistoryStore.saveSessions([keep], defaults: defaults)
        StudioChatHistoryStore.saveSelectedSessionID(keepID, defaults: defaults)
        XCTAssertEqual(StudioChatHistoryStore.loadSelectedSessionID(defaults: defaults), keepID)

        StudioChatHistoryStore.saveSelectedSessionID(missingID, defaults: defaults)
        StudioChatHistoryStore.saveSessions([keep], defaults: defaults)
        XCTAssertNil(StudioChatHistoryStore.loadSelectedSessionID(defaults: defaults))
    }

    func testDeleteSelectedSessionFallsBackToNextSortedSession() {
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let pinnedID = UUID()
        let deleteID = UUID()
        let pinned = StudioChatSession(
            id: pinnedID,
            title: "Pinned",
            turns: [ChatTurn(role: .user, content: "Pinned prompt")],
            updatedAt: old,
            isPinned: true
        )
        let remove = StudioChatSession(
            id: deleteID,
            title: "Delete",
            turns: [ChatTurn(role: .user, content: "Delete prompt")],
            updatedAt: newer
        )

        StudioChatHistoryStore.saveSessions([remove, pinned], defaults: defaults)
        StudioChatHistoryStore.saveSelectedSessionID(deleteID, defaults: defaults)
        StudioChatHistoryStore.deleteSession(deleteID, defaults: defaults)

        XCTAssertEqual(StudioChatHistoryStore.loadSelectedSessionID(defaults: defaults), pinnedID)
    }

    func testUpdateSessionModelNamePersistsActiveSessionModelWithoutChangingSelection() {
        let sessionID = UUID()
        let old = Date(timeIntervalSince1970: 100)
        let updated = Date(timeIntervalSince1970: 200)
        let summaryExported = Date(timeIntervalSince1970: 150)
        let session = StudioChatSession(
            id: sessionID,
            title: "Switch model",
            modelName: "Old Model",
            turns: [ChatTurn(role: .user, content: "Keep this session")],
            createdAt: old,
            updatedAt: old,
            isPinned: true,
            summaryExportPath: "/tmp/Switch model-summary-11111111.md",
            summaryExportedAt: summaryExported
        )

        StudioChatHistoryStore.saveSessions([session], defaults: defaults)
        StudioChatHistoryStore.saveSelectedSessionID(sessionID, defaults: defaults)
        StudioChatHistoryStore.updateSessionModelName(
            sessionID,
            modelName: "New Model",
            updatedAt: updated,
            defaults: defaults
        )

        let loaded = StudioChatHistoryStore.loadSessions(defaults: defaults)
        XCTAssertEqual(loaded.first?.id, sessionID)
        XCTAssertEqual(loaded.first?.modelName, "New Model")
        XCTAssertEqual(loaded.first?.updatedAt, updated)
        XCTAssertEqual(loaded.first?.turns.map(\.content), ["Keep this session"])
        XCTAssertNil(loaded.first?.summaryExportPath)
        XCTAssertNil(loaded.first?.summaryExportedAt)
        XCTAssertEqual(StudioChatHistoryStore.loadSelectedSessionID(defaults: defaults), sessionID)
    }

    func testUpdateSessionTitleClearsSummaryExportMetadataWithoutChangingSelectionOrActivity() {
        let sessionID = UUID()
        let old = Date(timeIntervalSince1970: 100)
        let summaryExported = Date(timeIntervalSince1970: 150)
        let session = StudioChatSession(
            id: sessionID,
            title: "Saved title",
            modelName: "Smoke Model",
            turns: [ChatTurn(role: .user, content: "Keep this session")],
            createdAt: old,
            updatedAt: old,
            isPinned: true,
            summaryExportPath: "/tmp/Saved title-summary-11111111.md",
            summaryExportedAt: summaryExported
        )

        StudioChatHistoryStore.saveSessions([session], defaults: defaults)
        StudioChatHistoryStore.saveSelectedSessionID(sessionID, defaults: defaults)
        StudioChatHistoryStore.updateSessionTitle(
            sessionID,
            title: "Renamed title",
            defaults: defaults
        )

        let loaded = StudioChatHistoryStore.loadSessions(defaults: defaults)
        XCTAssertEqual(loaded.first?.id, sessionID)
        XCTAssertEqual(loaded.first?.title, "Renamed title")
        XCTAssertEqual(loaded.first?.updatedAt, old)
        XCTAssertEqual(loaded.first?.turns.map(\.content), ["Keep this session"])
        XCTAssertNil(loaded.first?.summaryExportPath)
        XCTAssertNil(loaded.first?.summaryExportedAt)
        XCTAssertEqual(StudioChatHistoryStore.loadSelectedSessionID(defaults: defaults), sessionID)
    }

    func testLegacyTurnHistoryMigratesIntoSessionAndPersists() throws {
        let first = Date(timeIntervalSince1970: 300)
        let second = Date(timeIntervalSince1970: 301)
        let turns = [
            ChatTurn(role: .user, content: "Legacy prompt", createdAt: first),
            ChatTurn(role: .assistant, content: "Legacy answer", createdAt: second),
        ]
        let data = try JSONEncoder().encode(turns)
        defaults.set(data, forKey: StudioChatHistoryStore.legacyKey)

        let loaded = StudioChatHistoryStore.loadSessions(defaults: defaults)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Legacy prompt")
        XCTAssertEqual(loaded[0].turns, turns)
        XCTAssertNotNil(defaults.data(forKey: StudioChatHistoryStore.sessionsKey))
    }

    private func stringContent(_ message: ChatRequest.Message) -> String? {
        guard let content = message.content else { return nil }
        switch content {
        case .string(let value):
            return value
        case .parts:
            return nil
        }
    }
}
