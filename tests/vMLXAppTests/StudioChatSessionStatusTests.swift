import Foundation
import XCTest
@testable import vMLXApp

final class StudioChatSessionStatusTests: XCTestCase {
    func testFailedSessionSummarizesAttentionStateAndSearchTokens() {
        let session = StudioChatSession(
            title: "Failed chat",
            turns: [
                ChatTurn(role: .user, content: "Prompt"),
                ChatTurn(role: .assistant, content: "Error", streamState: .failed),
            ]
        )

        let summary = StudioChatSessionStatus.summary(for: session)

        XCTAssertEqual(summary.label, "1 failed")
        XCTAssertEqual(summary.failedTurnCount, 1)
        XCTAssertTrue(summary.needsAttention)
        XCTAssertTrue(summary.searchTokens.contains("failed"))
        XCTAssertTrue(summary.searchTokens.contains("needs attention"))
    }

    func testCleanSessionSummarizesReadyState() {
        let session = StudioChatSession(
            title: "Clean chat",
            turns: [
                ChatTurn(role: .user, content: "Prompt"),
                ChatTurn(role: .assistant, content: "Answer"),
            ]
        )

        let summary = StudioChatSessionStatus.summary(for: session)

        XCTAssertEqual(summary.label, "Clean")
        XCTAssertFalse(summary.needsAttention)
        XCTAssertEqual(summary.failedTurnCount, 0)
        XCTAssertTrue(summary.searchTokens.contains("clean"))
    }

    func testSummaryExportAddsSavedHandoffSearchTokens() {
        let exported = Date(timeIntervalSince1970: 803_000_400)
        let summaryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Summary chat-summary-\(UUID().uuidString).md")
        try? "# Summary\n".write(to: summaryURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: summaryURL) }
        let session = StudioChatSession(
            title: "Summary chat",
            turns: [
                ChatTurn(role: .user, content: "Prompt"),
                ChatTurn(role: .assistant, content: "Answer"),
            ],
            summaryExportPath: summaryURL.path,
            summaryExportedAt: exported
        )

        let summary = StudioChatSessionStatus.summary(for: session)

        XCTAssertEqual(summary.label, "Clean")
        XCTAssertTrue(summary.searchTokens.contains("summary saved"))
        XCTAssertTrue(summary.searchTokens.contains("handoff saved"))
        XCTAssertTrue(summary.searchTokens.contains(summaryURL.lastPathComponent))
        XCTAssertTrue(session.hasSummaryExport)
        XCTAssertTrue(session.summaryExportFileExists)
    }

    func testMissingSummaryExportAddsMissingHandoffSearchTokens() {
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Missing summary-\(UUID().uuidString).md")
        try? FileManager.default.removeItem(at: missingURL)
        let session = StudioChatSession(
            title: "Missing summary chat",
            turns: [
                ChatTurn(role: .user, content: "Prompt"),
                ChatTurn(role: .assistant, content: "Answer"),
            ],
            summaryExportPath: missingURL.path,
            summaryExportedAt: Date(timeIntervalSince1970: 803_000_450)
        )

        let summary = StudioChatSessionStatus.summary(for: session)

        XCTAssertEqual(summary.label, "Clean")
        XCTAssertTrue(summary.searchTokens.contains("summary missing"))
        XCTAssertTrue(summary.searchTokens.contains("handoff missing"))
        XCTAssertTrue(summary.searchTokens.contains(missingURL.lastPathComponent))
        XCTAssertFalse(summary.searchTokens.contains("summary saved"))
        XCTAssertTrue(session.hasSummaryExport)
        XCTAssertFalse(session.summaryExportFileExists)
    }
}
