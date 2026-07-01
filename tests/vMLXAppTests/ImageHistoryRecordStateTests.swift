import XCTest
import vMLXEngine
@testable import vMLXApp

final class ImageHistoryRecordStateTests: XCTestCase {
    func testCompletedRecordWithExistingOutputIsReady() {
        let record = ImageGenerationRecord(
            modelAlias: "Image Model",
            prompt: "Ready prompt",
            settingsJSON: "{}",
            outputPath: "/tmp/output.png",
            status: .completed
        )

        let summary = ImageHistoryRecordState.summary(for: record, outputExists: true)

        XCTAssertEqual(summary.label, "Ready output")
        XCTAssertEqual(summary.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(summary.tone, .success)
    }

    func testCompletedRecordWithoutOutputIsMissing() {
        let record = ImageGenerationRecord(
            modelAlias: "Image Model",
            prompt: "Missing prompt",
            settingsJSON: "{}",
            outputPath: "/tmp/missing.png",
            status: .completed
        )

        let summary = ImageHistoryRecordState.summary(for: record, outputExists: false)

        XCTAssertEqual(summary.label, "Missing file")
        XCTAssertEqual(summary.systemImage, "doc.badge.exclamationmark")
        XCTAssertEqual(summary.tone, .warning)
    }

    func testPendingFailedAndCancelledStatesRemainDistinct() {
        let pending = ImageGenerationRecord(
            modelAlias: "Image Model",
            prompt: "Pending prompt",
            settingsJSON: "{}",
            status: .pending
        )
        let failed = ImageGenerationRecord(
            modelAlias: "Image Model",
            prompt: "Failed prompt",
            settingsJSON: "{}",
            status: .failed
        )
        let cancelled = ImageGenerationRecord(
            modelAlias: "Image Model",
            prompt: "Cancelled prompt",
            settingsJSON: "{}",
            status: .cancelled
        )

        XCTAssertEqual(
            ImageHistoryRecordState.summary(for: pending, outputExists: false),
            .init(label: "Rendering", systemImage: "circle.dotted", tone: .active)
        )
        XCTAssertEqual(
            ImageHistoryRecordState.summary(for: failed, outputExists: false),
            .init(label: "Failed output", systemImage: "exclamationmark.triangle.fill", tone: .danger)
        )
        XCTAssertEqual(
            ImageHistoryRecordState.summary(for: cancelled, outputExists: false),
            .init(label: "Cancelled", systemImage: "xmark.circle", tone: .muted)
        )
    }
}
