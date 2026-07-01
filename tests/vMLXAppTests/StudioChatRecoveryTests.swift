import Foundation
import XCTest
@testable import vMLXApp

final class StudioChatRecoveryTests: XCTestCase {
    func testRetryDraftReplacesFailedAssistantWithStreamingTurn() {
        let userID = UUID()
        let failedID = UUID()
        let retryID = UUID()
        let retryDate = Date(timeIntervalSince1970: 1234)
        let turns = [
            ChatTurn(id: userID, role: .user, content: "Retry this prompt"),
            ChatTurn(id: failedID, role: .assistant, content: "Network failed", streamState: .failed),
        ]

        let draft = StudioChatRecovery.retryDraft(
            from: failedID,
            in: turns,
            assistantID: retryID,
            createdAt: retryDate
        )

        XCTAssertEqual(draft?.retainedTurns.map(\.id), [userID])
        XCTAssertFalse((draft?.retainedTurns ?? []).contains { $0.streamState == .failed })
        XCTAssertEqual(draft?.assistant.id, retryID)
        XCTAssertEqual(draft?.assistant.role, .assistant)
        XCTAssertEqual(draft?.assistant.content, "")
        XCTAssertEqual(draft?.assistant.createdAt, retryDate)
        XCTAssertEqual(draft?.assistant.streamState, .streaming)
    }

    func testRetryDraftRegeneratesFromUserPromptAndDropsLaterTurns() {
        let firstUser = ChatTurn(role: .user, content: "Original")
        let firstAssistant = ChatTurn(role: .assistant, content: "Old answer")
        let laterUser = ChatTurn(role: .user, content: "Follow up")
        let laterAssistant = ChatTurn(role: .assistant, content: "Later answer")
        let turns = [firstUser, firstAssistant, laterUser, laterAssistant]

        let draft = StudioChatRecovery.retryDraft(from: firstUser.id, in: turns)

        XCTAssertEqual(draft?.retainedTurns, [firstUser])
        XCTAssertEqual(draft?.assistant.streamState, .streaming)
    }

    func testRetryDraftRejectsAssistantWithoutPriorUserPrompt() {
        let orphan = ChatTurn(role: .assistant, content: "No prior prompt", streamState: .failed)

        XCTAssertNil(StudioChatRecovery.retryDraft(from: orphan.id, in: [orphan]))
    }

    func testRegenerateAvailabilityRequiresSelectedModelBeforeMutatingTurns() {
        let user = ChatTurn(role: .user, content: "Retry this prompt")
        let assistant = ChatTurn(role: .assistant, content: "Old answer")
        let turns = [user, assistant]

        XCTAssertEqual(
            StudioChatRegenerateAvailability.disabledReason(
                hasSelectedModel: false,
                isStreaming: false,
                turnID: assistant.id,
                turns: turns
            ),
            "Select a chat model before regenerating."
        )
    }

    func testRegenerateAvailabilityRejectsOrphanAssistant() {
        let orphan = ChatTurn(role: .assistant, content: "No prior prompt", streamState: .failed)

        XCTAssertEqual(
            StudioChatRegenerateAvailability.disabledReason(
                hasSelectedModel: true,
                isStreaming: false,
                turnID: orphan.id,
                turns: [orphan]
            ),
            "No user prompt is available to regenerate from."
        )
    }

    func testRegenerateAvailabilityAllowsValidAssistantWithModel() {
        let user = ChatTurn(role: .user, content: "Retry this prompt")
        let assistant = ChatTurn(role: .assistant, content: "Old answer")

        XCTAssertNil(StudioChatRegenerateAvailability.disabledReason(
            hasSelectedModel: true,
            isStreaming: false,
            turnID: assistant.id,
            turns: [user, assistant]
        ))
    }

    func testSuccessfulRetryDraftClearsLibraryAttentionState() throws {
        let userID = UUID()
        let failedID = UUID()
        let retryID = UUID()
        let turns = [
            ChatTurn(id: userID, role: .user, content: "Retry this prompt"),
            ChatTurn(id: failedID, role: .assistant, content: "Socket failed", streamState: .failed),
        ]

        let draft = try XCTUnwrap(StudioChatRecovery.retryDraft(
            from: failedID,
            in: turns,
            assistantID: retryID
        ))
        var completedAssistant = draft.assistant
        completedAssistant.content = "Recovered answer"
        completedAssistant.streamState = .complete
        let recoveredSession = StudioChatSession(
            title: "Recovered chat",
            turns: draft.retainedTurns + [completedAssistant]
        )

        let summary = StudioChatSessionStatus.summary(for: recoveredSession)

        XCTAssertEqual(recoveredSession.turns.map(\.id), [userID, retryID])
        XCTAssertFalse(recoveredSession.turns.contains { $0.streamState == .failed })
        XCTAssertEqual(summary.label, "Clean")
        XCTAssertFalse(summary.needsAttention)
        XCTAssertEqual(summary.failedTurnCount, 0)
        XCTAssertTrue(summary.searchTokens.contains("clean"))
    }
}
