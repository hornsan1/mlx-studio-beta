import Foundation
import MLXStudioDomain
import MLXStudioEvaluation
import XCTest
@testable import vMLXApp

@MainActor
final class StudioEvaluateScreenTests: XCTestCase {
    func testEvaluateIsFirstClassAndQuickCompareRequiresTwoDistinctArtifacts() throws {
        XCTAssertTrue(AppState.Mode.visible(for: .beginner).contains(.evaluate))
        XCTAssertTrue(AppState.Mode.visible(for: .advanced).contains(.evaluate))
        XCTAssertFalse(AppState.Mode.evaluate.isAdvancedOnly)

        let model = StudioQuickCompareViewModel()
        let first = ModelArtifactID()
        model.firstArtifactID = first
        model.secondArtifactID = first
        XCTAssertFalse(model.canRun)
        model.secondArtifactID = ModelArtifactID()
        XCTAssertTrue(model.canRun)
        model.seedText = "not-a-seed"
        XCTAssertFalse(model.canRun)
    }

    func testQuickCompareSuiteHashCapturesPromptSettingsAndTemplate() throws {
        let configuration = GenerationConfiguration(
            maximumTokenCount: 64,
            temperature: 0,
            topP: 1,
            seed: 42
        )
        let first = try QuickCompareSuiteFactory.singlePrompt(
            systemPrompt: "Be concise.",
            prompt: "Hello",
            generationConfiguration: configuration
        )
        let repeated = try QuickCompareSuiteFactory.singlePrompt(
            systemPrompt: "Be concise.",
            prompt: "Hello",
            generationConfiguration: configuration
        )
        let changed = try QuickCompareSuiteFactory.singlePrompt(
            systemPrompt: "Be concise.",
            prompt: "Different",
            generationConfiguration: configuration
        )

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.id, repeated.id)
        XCTAssertEqual(first.revision, first.suiteHash)
        XCTAssertNotEqual(first.suiteHash, changed.suiteHash)
        XCTAssertNotEqual(first.id, changed.id)
        XCTAssertNotEqual(first.revision, changed.revision)
        XCTAssertEqual(first.tags, ["quick-compare"])
    }

    func testArtifactSelectionAllowsPresentDiscoveredModelsButRejectsUnsafeStates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evaluate-selectable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let discovered = ModelArtifact(
            projectID: ModelProjectID(),
            name: "Discovered",
            localURL: root,
            format: .mlx,
            state: .discovered
        )
        let unavailable = ModelArtifact(
            projectID: ModelProjectID(),
            name: "Unavailable",
            localURL: root,
            format: .mlx,
            state: .unavailable
        )

        XCTAssertTrue(StudioQuickCompareViewModel.isSelectableArtifact(discovered))
        XCTAssertFalse(StudioQuickCompareViewModel.isSelectableArtifact(unavailable))
    }
}
