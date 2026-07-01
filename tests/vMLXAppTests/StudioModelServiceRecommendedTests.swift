import XCTest
@testable import vMLXApp

@MainActor
final class StudioModelServiceRecommendedTests: XCTestCase {
    func testStarterRecommendedModelDefaultsToLiquidAILFM25() async throws {
        let service = StudioModelService(app: AppState())
        let recommended = try await service.listRecommendedModels()
        let starter = try XCTUnwrap(recommended.first)

        XCTAssertEqual(starter.ref.id, "hf:LiquidAI/LFM2.5-350M")
        XCTAssertEqual(starter.ref.displayName, "LiquidAI/LFM2.5-350M")
        XCTAssertEqual(starter.ref.repo, "LiquidAI/LFM2.5-350M")
        XCTAssertEqual(starter.sizeHint, "~0.7 GB")
        XCTAssertTrue(starter.labels.contains("LFM2.5"))
        XCTAssertTrue(starter.summary.contains("LiquidAI"))
    }
}
