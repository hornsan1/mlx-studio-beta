import Foundation
import XCTest
@testable import vMLXApp

final class UnifiedChatMigrationTests: XCTestCase {
    @MainActor
    func testUnifiedSelectionPersistsIndependentlyOfOneTimeMigrationPreference() {
        let suite = "ai.dealign.mlxstudio.unified-selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionID = UUID()

        StudioChatHistoryMigration.saveSelectedSessionID(sessionID, defaults: defaults)

        XCTAssertEqual(
            StudioChatHistoryMigration.loadSelectedSessionID(defaults: defaults),
            sessionID
        )
        XCTAssertNil(StudioChatHistoryMigration.consumePreferredSessionID(defaults: defaults))
        XCTAssertEqual(
            StudioChatHistoryMigration.loadSelectedSessionID(defaults: defaults),
            sessionID
        )
    }

    @MainActor
    func testDurableSelectionWinsStaleLegacyPreferenceOnRelaunch() {
        let suite = "ai.dealign.mlxstudio.unified-selection-priority.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacySelection = UUID()
        let lastSelected = UUID()

        // A completed migration can leave this old one-time preference
        // behind. It must not reopen First local chat over the chat selected
        // immediately before quit.
        defaults.set(
            legacySelection.uuidString,
            forKey: StudioChatHistoryMigration.preferredSessionKey
        )
        StudioChatHistoryMigration.saveSelectedSessionID(lastSelected, defaults: defaults)

        let requested = StudioChatHistoryMigration.resolvedSelectionID(
            appSelection: nil,
            durableSelection: StudioChatHistoryMigration.loadSelectedSessionID(defaults: defaults),
            migrationSelection: StudioChatHistoryMigration.consumePreferredSessionID(defaults: defaults)
        )

        XCTAssertEqual(requested, lastSelected)
        XCTAssertNil(defaults.string(forKey: StudioChatHistoryMigration.preferredSessionKey))

        let explicitDeepLink = UUID()
        XCTAssertEqual(
            StudioChatHistoryMigration.resolvedSelectionID(
                appSelection: explicitDeepLink,
                durableSelection: lastSelected,
                migrationSelection: legacySelection
            ),
            explicitDeepLink
        )
    }

    func testPlaceholderTitlesRecognizeLegacyCaseVariants() {
        XCTAssertTrue(ChatSession().hasPlaceholderTitle)
        XCTAssertTrue(ChatSession(title: "New Chat").hasPlaceholderTitle)
        XCTAssertTrue(ChatSession(title: "  untitled chat ").hasPlaceholderTitle)
        XCTAssertFalse(ChatSession(title: "QA conversation").hasPlaceholderTitle)
    }

    func testPlanPreservesSessionIdentityPinModelAndPartialOutput() throws {
        let sessionID = UUID()
        let user = ChatTurn(role: .user, content: "Keep this prompt")
        let assistant = ChatTurn(
            role: .assistant,
            content: "Partial answer",
            streamState: .streaming
        )
        let source = StudioChatSession(
            id: sessionID,
            title: "Migrated conversation",
            modelName: "Qwen local",
            turns: [user, assistant],
            isPinned: true
        )

        let plan = StudioChatHistoryMigration.makePlan(
            sessions: [source],
            preferredSessionID: sessionID
        )

        let session = try XCTUnwrap(plan.sessions.first)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.modelName, "Qwen local")
        XCTAssertTrue(session.isPinned)
        XCTAssertEqual(plan.preferredSessionID, sessionID)
        XCTAssertEqual(plan.messages[sessionID]?.map(\.id), [user.id, assistant.id])
        XCTAssertEqual(plan.messages[sessionID]?.last?.content, "Partial answer [interrupted]")
        XCTAssertEqual(plan.messages[sessionID]?.last?.isStreaming, false)
    }

    func testPlanDropsInvalidPreferredSessionAndKeepsFailureVisible() {
        let source = StudioChatSession(
            title: "Failed conversation",
            turns: [ChatTurn(role: .assistant, content: "", streamState: .failed)]
        )

        let plan = StudioChatHistoryMigration.makePlan(
            sessions: [source],
            preferredSessionID: UUID()
        )

        XCTAssertNil(plan.preferredSessionID)
        XCTAssertEqual(plan.messages[source.id]?.first?.content, "[generation failed]")
    }
}

final class ChatImporterTests: XCTestCase {
    func testJSONExportRoundTripsConversationAndMedia() throws {
        let source = ChatSession(
            title: "Portable chat",
            modelPath: "/models/local-vision",
            modelName: "Local Vision Model",
            isPinned: true,
            collectionName: "QA evidence",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let messages = [
            ChatMessage(
                sessionId: source.id,
                role: .user,
                content: "Describe this",
                imageData: [Data([0, 1, 2])],
                videoPaths: ["file:///tmp/clip.mov"],
                createdAt: Date(timeIntervalSince1970: 101)
            ),
            ChatMessage(
                sessionId: source.id,
                role: .assistant,
                content: "Done",
                reasoning: "Checked pixels",
                toolStatuses: ["call-1": .done],
                createdAt: Date(timeIntervalSince1970: 102)
            ),
        ]
        let exported = ChatExporter.exportToJSON(source, messages: messages)

        let imported = try ChatImporter.decode(try XCTUnwrap(exported.data(using: .utf8)))

        XCTAssertNotEqual(imported.session.id, source.id)
        XCTAssertEqual(imported.session.title, source.title)
        XCTAssertEqual(imported.session.modelName, "Local Vision Model")
        XCTAssertEqual(imported.session.modelPath, "/models/local-vision")
        XCTAssertTrue(imported.session.isPinned)
        XCTAssertEqual(imported.session.collectionName, "QA evidence")
        XCTAssertEqual(imported.messages.map(\.sessionId), [imported.session.id, imported.session.id])
        XCTAssertEqual(imported.messages.first?.imageData, [Data([0, 1, 2])])
        XCTAssertEqual(imported.messages.first?.videoPaths, ["file:///tmp/clip.mov"])
        XCTAssertEqual(imported.messages.last?.reasoning, "Checked pixels")
        XCTAssertEqual(imported.messages.last?.toolStatuses, ["call-1": .done])
    }

    func testLegacyExportStillImportsWithoutNewMetadata() throws {
        let legacy = #"""
        {"version":1,"session":{"title":"Legacy","model":"Old model"},"messages":[{"role":"assistant","content":"still here"}]}
        """#

        let imported = try ChatImporter.decode(try XCTUnwrap(legacy.data(using: .utf8)))

        XCTAssertEqual(imported.session.title, "Legacy")
        XCTAssertEqual(imported.session.modelName, "Old model")
        XCTAssertNil(imported.session.modelPath)
        XCTAssertFalse(imported.session.isPinned)
        XCTAssertNil(imported.session.collectionName)
        XCTAssertEqual(imported.messages.first?.toolStatuses, [:])
    }

    func testRejectsUnsupportedExportVersion() throws {
        let data = try XCTUnwrap(#"{"version":99,"session":{"title":"x"},"messages":[{"role":"user","content":"hi"}]}"#.data(using: .utf8))
        XCTAssertThrowsError(try ChatImporter.decode(data)) { error in
            XCTAssertEqual(error as? ChatImportError, .unsupportedVersion(99))
        }
    }
}

final class ChatDocumentContextTests: XCTestCase {
    @MainActor
    func testDraftPayloadRoundTripsTextMediaAndDocumentContext() throws {
        let document = ChatDocumentAttachment(
            name: "draft-notes.txt",
            text: "Keep this local context.",
            sourceByteCount: 24
        )
        let payload = Database.ChatDraftPayload(
            inputText: "Unsent prompt",
            pendingImages: [Data([7, 8, 9])],
            pendingVideoPaths: ["file:///tmp/draft.mov"],
            pendingDocuments: [document]
        )

        let restored = try JSONDecoder().decode(
            Database.ChatDraftPayload.self,
            from: JSONEncoder().encode(payload)
        )

        XCTAssertEqual(restored, payload)
        XCTAssertFalse(restored.isEmpty)
    }

    func testSmallDocumentIsInsertedVerbatim() {
        let document = ChatDocumentAttachment(
            name: "notes.txt",
            text: "A short local document.",
            sourceByteCount: 23
        )

        let rendered = ChatDocumentContext.render(documents: [document], query: "summarize")

        XCTAssertTrue(rendered.contains("Document: notes.txt — full document"))
        XCTAssertTrue(rendered.contains("A short local document."))
    }

    func testLargeDocumentRetrievalPrefersQueryRelevantChunk() {
        let filler = String(repeating: "ordinary background material ", count: 2_000)
        let relevant = String(repeating: "important zebra deployment detail ", count: 200)
        let document = ChatDocumentAttachment(
            name: "large.txt",
            text: filler + relevant,
            sourceByteCount: 100_000
        )

        let rendered = ChatDocumentContext.render(documents: [document], query: "zebra deployment")

        XCTAssertTrue(rendered.contains("locally retrieved excerpts"))
        XCTAssertTrue(rendered.contains("zebra deployment"))
        XCTAssertLessThanOrEqual(rendered.count, ChatDocumentContext.totalCharacterBudget + 200)
    }
}
