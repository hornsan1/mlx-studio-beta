// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import vMLXEngine

final class ImageGenerationSafetyTests: XCTestCase {
    func testDefaultFluxSettingsFitReasonableUnifiedMemoryBudget() {
        let settings = ImageGenSettings(
            steps: 4,
            guidance: 0,
            width: 1024,
            height: 1024,
            seed: 42,
            numImages: 1
        )

        XCTAssertNil(
            ImageGenerationSafety.validationMessage(
                settings: settings,
                modelStorageBytes: 9_700_000_000,
                physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024
            )
        )
    }

    func testOversizedDimensionsAreRefusedForBetaMetalPath() {
        var settings = ImageGenSettings()
        settings.width = 2048
        settings.height = 2048

        let message = ImageGenerationSafety.validationMessage(
            settings: settings,
            modelStorageBytes: 9_700_000_000,
            physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024
        )

        XCTAssertTrue(message?.contains("disabled for the beta Metal path") == true)
    }

    func testDimensionsMustAlignToFluxGrid() {
        var settings = ImageGenSettings()
        settings.width = 1000
        settings.height = 1024

        let message = ImageGenerationSafety.validationMessage(
            settings: settings,
            modelStorageBytes: 9_700_000_000,
            physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024
        )

        XCTAssertTrue(message?.contains("multiples of 64") == true)
    }

    func testBatchGenerationIsRefused() {
        var settings = ImageGenSettings()
        settings.numImages = 2

        let message = ImageGenerationSafety.validationMessage(
            settings: settings,
            modelStorageBytes: 9_700_000_000,
            physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024
        )

        XCTAssertTrue(message?.contains("one image at a time") == true)
    }

    func testNormalizedForEditingClampsHistoricTinyImageSettings() {
        let settings = ImageGenSettings(
            steps: 0,
            guidance: 4.25,
            width: 128,
            height: 128,
            seed: 7,
            numImages: 3,
            scheduler: "euler",
            strength: 0.4
        )

        let normalized = ImageGenerationSafety.normalizedForEditing(settings)

        XCTAssertEqual(normalized.width, 256)
        XCTAssertEqual(normalized.height, 256)
        XCTAssertEqual(normalized.steps, 1)
        XCTAssertEqual(normalized.numImages, 1)
        XCTAssertEqual(normalized.guidance, 4.25)
        XCTAssertEqual(normalized.seed, 7)
        XCTAssertEqual(normalized.scheduler, "euler")
        XCTAssertEqual(normalized.strength, 0.4)
        XCTAssertNil(
            ImageGenerationSafety.validationMessage(
                settings: normalized,
                modelStorageBytes: 9_700_000_000,
                physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024
            )
        )
    }

    func testNormalizedForEditingRoundsDimensionsUpToFluxGrid() {
        let settings = ImageGenSettings(width: 300, height: 200)

        let normalized = ImageGenerationSafety.normalizedForEditing(settings)

        XCTAssertEqual(normalized.width, 320)
        XCTAssertEqual(normalized.height, 256)
    }

    func testNormalizedForEditingClampsOversizedDimensions() {
        let settings = ImageGenSettings(width: 2048, height: 2048)

        let normalized = ImageGenerationSafety.normalizedForEditing(settings)

        XCTAssertEqual(normalized.width, 1024)
        XCTAssertEqual(normalized.height, 1024)
    }

    func testUnifiedMemoryEstimateCanRefuseTooLargeModel() {
        let settings = ImageGenSettings(width: 1024, height: 1024)

        let message = ImageGenerationSafety.validationMessage(
            settings: settings,
            modelStorageBytes: 28 * 1_024 * 1_024 * 1_024,
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024
        )

        XCTAssertTrue(message?.contains("unified memory") == true)
    }

    func testMetalRuntimePreflightCanBeSkippedForHarnesses() {
        let report = MetalRuntimePreflight.check(
            environment: [MetalRuntimePreflight.skipEnvironmentKey: "1"]
        )

        XCTAssertTrue(report.isAvailable)
        XCTAssertTrue(report.message.contains("skipped"))
    }

    func testMetalRuntimePreflightReturnsReportWithoutCrashing() {
        let report = MetalRuntimePreflight.check(environment: [:])

        XCTAssertFalse(report.message.isEmpty)
        XCTAssertTrue(report.isAvailable || report.message.contains("failed")
            || report.message.contains("No default Metal device")
            || report.message.contains("not available"))
    }

    func testMetalRuntimePreflightHasConciseUserFacingCompilerServiceMessage() {
        let report = MetalRuntimePreflight.Report.unavailable(
            deviceName: "Test GPU",
            message: "Unable to reach MTLCompilerService. Connection init failed"
        )

        XCTAssertTrue(report.userFacingMessage.contains("MTLCompilerService"))
        XCTAssertFalse(report.userFacingMessage.contains("Connection init failed"))
    }
}
