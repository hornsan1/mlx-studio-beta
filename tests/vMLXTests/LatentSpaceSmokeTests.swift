// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import vMLXFluxKit

final class LatentSpaceSmokeTests: XCTestCase {
    func testDeterministicSmokeLatentsMatchSpatialShapeAndSeed() {
        let shape = LatentSpace.noiseShape(
            width: 256,
            height: 256,
            layout: .spatial(channels: 16),
            batchSize: 1
        )

        XCTAssertEqual(shape, [1, 16, 32, 32])
        XCTAssertEqual(
            LatentSpace.deterministicNoiseValues(count: 128, seed: 42),
            LatentSpace.deterministicNoiseValues(count: 128, seed: 42)
        )
        XCTAssertNotEqual(
            LatentSpace.deterministicNoiseValues(count: 128, seed: 42),
            LatentSpace.deterministicNoiseValues(count: 128, seed: 43)
        )
    }

    func testDeterministicSmokeLatentsMatchPatchifiedShape() {
        let shape = LatentSpace.noiseShape(
            width: 512,
            height: 256,
            layout: .fluxPatchified(channels: 16),
            batchSize: 2
        )

        XCTAssertEqual(shape, [2, 2048, 16])
        let values = LatentSpace.deterministicNoiseValues(count: 4096, seed: 7)
        XCTAssertTrue(values.contains { $0 < -0.5 })
        XCTAssertTrue(values.contains { $0 > 0.5 })
    }
}
