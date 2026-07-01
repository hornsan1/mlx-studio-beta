import XCTest
@testable import vMLXApp

final class StudioModelMemoryFitTests: XCTestCase {
    private let gib = UInt64(1_073_741_824)

    func testMemoryFitUsesSystemMemoryAndModelModalityAssumptions() {
        let memory = 128 * gib

        let smallText = StudioModelMemoryFit.classify(
            sizeBytes: Int64(633_400_000),
            modality: "text",
            systemMemoryBytes: memory
        )
        XCTAssertEqual(smallText.title, "Spacious")
        XCTAssertEqual(smallText.level, .spacious)

        let imageModel = StudioModelMemoryFit.classify(
            sizeBytes: Int64(10 * gib),
            modality: "image",
            systemMemoryBytes: memory
        )
        XCTAssertEqual(imageModel.title, "Comfort")
        XCTAssertEqual(imageModel.level, .comfort)
        XCTAssertGreaterThan(
            imageModel.estimatedRuntimeBytes,
            StudioModelMemoryFit.estimatedRuntimeBytes(sizeBytes: Int64(10 * gib), modality: "text")
        )

        let largeText = StudioModelMemoryFit.classify(
            sizeBytes: Int64(40 * gib),
            modality: "text",
            systemMemoryBytes: memory
        )
        XCTAssertEqual(largeText.title, "Tight")
        XCTAssertEqual(largeText.level, .tight)

        let oversized = StudioModelMemoryFit.classify(
            sizeBytes: Int64(96 * gib),
            modality: "text",
            systemMemoryBytes: memory
        )
        XCTAssertEqual(oversized.title, "Over")
        XCTAssertEqual(oversized.level, .over)
    }

    func testSmallerMacMemoryMakesSameModelRiskier() {
        let modelSize = Int64(10 * gib)

        let onLargeMac = StudioModelMemoryFit.classify(
            sizeBytes: modelSize,
            modality: "image",
            systemMemoryBytes: 128 * gib
        )
        let onSmallMac = StudioModelMemoryFit.classify(
            sizeBytes: modelSize,
            modality: "image",
            systemMemoryBytes: 32 * gib
        )

        XCTAssertEqual(onLargeMac.level, .comfort)
        XCTAssertEqual(onSmallMac.level, .risky)
    }
}
