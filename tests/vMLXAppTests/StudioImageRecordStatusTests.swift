import XCTest
import vMLXEngine
@testable import vMLXApp

final class StudioImageRecordStatusTests: XCTestCase {
    func testReadyRecordSearchTokensMirrorVisibleState() throws {
        let record = ImageGenerationRecord(
            modelAlias: "Smoke Image Model",
            prompt: "Smoke prompt",
            settingsJSON: try settingsJSON(
                ImageGenSettings(steps: 4, guidance: 3.5, width: 128, height: 128, seed: 7)
            ),
            outputPath: "/tmp/smoke.png",
            status: .completed
        )

        let summary = StudioImageRecordStatus.summary(
            for: record,
            fileExists: true,
            sidecarStatus: .saved
        )

        XCTAssertEqual(summary.fileLabel, "On disk")
        XCTAssertEqual(summary.provenanceLabel, "Sidecar saved")
        XCTAssertTrue(containsToken("file on disk", in: summary.searchTokens))
        XCTAssertTrue(containsToken("ready artifact", in: summary.searchTokens))
        XCTAssertTrue(containsToken("sidecar saved", in: summary.searchTokens))
        XCTAssertTrue(containsToken("128x128 - 4 steps - seed 7", in: summary.searchTokens))
    }

    func testMissingRecordSearchTokensMirrorVisibleState() throws {
        let record = ImageGenerationRecord(
            modelAlias: "Image Model",
            prompt: "Lost output",
            settingsJSON: try settingsJSON(ImageGenSettings()),
            outputPath: "/tmp/missing.png",
            status: .completed
        )

        let summary = StudioImageRecordStatus.summary(
            for: record,
            fileExists: false,
            sidecarStatus: .missing
        )

        XCTAssertEqual(summary.fileLabel, "Missing")
        XCTAssertEqual(summary.provenanceLabel, "Exportable")
        XCTAssertTrue(containsToken("file missing", in: summary.searchTokens))
        XCTAssertTrue(containsToken("missing file", in: summary.searchTokens))
        XCTAssertTrue(containsToken("exportable", in: summary.searchTokens))
    }

    func testFailedRecordSearchTokensMirrorVisibleState() throws {
        let record = ImageGenerationRecord(
            modelAlias: "Image Model",
            prompt: "Failed output",
            settingsJSON: try settingsJSON(ImageGenSettings()),
            status: .failed
        )

        let summary = StudioImageRecordStatus.summary(
            for: record,
            fileExists: false,
            sidecarStatus: .missing
        )

        XCTAssertEqual(summary.fileLabel, "Failed")
        XCTAssertEqual(summary.provenanceLabel, "Exportable")
        XCTAssertTrue(containsToken("file failed", in: summary.searchTokens))
        XCTAssertTrue(containsToken("failed output", in: summary.searchTokens))
    }

    private func settingsJSON(_ settings: ImageGenSettings) throws -> String {
        String(data: try JSONEncoder().encode(settings), encoding: .utf8) ?? "{}"
    }

    private func containsToken(_ needle: String, in tokens: [String]) -> Bool {
        tokens.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
