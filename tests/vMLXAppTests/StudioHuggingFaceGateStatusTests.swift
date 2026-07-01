import XCTest
import vMLXEngine
@testable import vMLXApp

final class StudioHuggingFaceGateStatusTests: XCTestCase {
    func testNoTokenKeepsGatedDownloadsBlockedButPublicModelsAvailable() {
        let status = HuggingFaceGateStatus.evaluate(
            hasToken: false,
            validation: .unknown
        )

        XCTAssertEqual(status.level, .open)
        XCTAssertEqual(status.value, "Public only")
        XCTAssertFalse(status.canAttemptGatedDownload)
        XCTAssertTrue(status.detail.contains("Public Hub models"))
        XCTAssertTrue(status.detail.contains("Gated repos need"))
        XCTAssertEqual(status.gatedRepoHint, "Gated - add HF token before download")
    }

    func testStoredTokenCanAttemptGatedDownloadWithAccessCaveat() {
        let status = HuggingFaceGateStatus.evaluate(
            hasToken: true,
            validation: .unknown
        )

        XCTAssertEqual(status.level, .stored)
        XCTAssertEqual(status.value, "Token stored")
        XCTAssertTrue(status.canAttemptGatedDownload)
        XCTAssertTrue(status.detail.contains("Keychain token"))
        XCTAssertTrue(status.detail.contains("Gated repos still need Hub access approval"))
        XCTAssertEqual(status.gatedRepoHint, "Gated - token stored; access approval required")
    }

    func testVerifiedTokenNamesUserButStillRequiresGatedAccessApproval() {
        let status = HuggingFaceGateStatus.evaluate(
            hasToken: true,
            validation: .valid(username: "hermes")
        )

        XCTAssertEqual(status.level, .verified)
        XCTAssertEqual(status.value, "Signed in @hermes")
        XCTAssertTrue(status.canAttemptGatedDownload)
        XCTAssertTrue(status.detail.contains("Gated repos still need Hub access approval"))
        XCTAssertEqual(status.gatedRepoHint, "Gated - token ready; access approval required")
    }

    func testRejectedTokenBlocksGatedDownloadAndKeepsPublicPathHonest() {
        let status = HuggingFaceGateStatus.evaluate(
            hasToken: true,
            validation: .invalid(reason: "Token rejected by HuggingFace")
        )

        XCTAssertEqual(status.level, .invalid)
        XCTAssertEqual(status.value, "Token rejected")
        XCTAssertFalse(status.canAttemptGatedDownload)
        XCTAssertTrue(status.detail.contains("Public Hub models still work"))
        XCTAssertTrue(status.detail.contains("Gated repos need a valid token"))
        XCTAssertEqual(status.gatedRepoHint, "Gated - fix HF token before download")
    }
}
