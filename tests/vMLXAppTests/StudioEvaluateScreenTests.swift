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

    func testBlindPresentationHidesIdentityAndOrderUntilPersistedReveal() throws {
        let model = StudioQuickCompareViewModel()
        let first = ModelArtifact(
            projectID: ModelProjectID(),
            name: "First Secret Model",
            localURL: URL(fileURLWithPath: "/models/first"),
            format: .mlx,
            state: .ready
        )
        let second = ModelArtifact(
            projectID: ModelProjectID(),
            name: "Second Secret Model",
            localURL: URL(fileURLWithPath: "/models/second"),
            format: .mlx,
            state: .ready
        )
        let suite = try QuickCompareSuiteFactory.singlePrompt(
            prompt: "Hello",
            generationConfiguration: .init(maximumTokenCount: 16, seed: 42)
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [
                .init(artifactID: first.id, blindLabel: "Response A"),
                .init(artifactID: second.id, blindLabel: "Response B"),
            ],
            executionOrder: [first.id, second.id]
        )
        let manifest = try EvaluationManifestBuilder.build(for: request)
        let evaluationCase = try XCTUnwrap(suite.cases.first)
        let pending = HumanJudgment(
            runID: request.id,
            caseID: evaluationCase.id,
            assignment: .init(
                responseAArtifactID: second.id,
                responseBArtifactID: first.id,
                assignmentSeed: 7,
                ordinal: 0
            )
        )
        model.artifacts = [first, second]
        model.presentationMode = .blindAB
        model.judgment = pending

        XCTAssertEqual(model.runButtonTitle, "Run Blind A/B")
        XCTAssertEqual(model.blindTitle(response: "Response A", artifactID: second.id), "Response A")
        XCTAssertFalse(model.manifestSummary(manifest).contains(first.id.rawValue))
        XCTAssertFalse(model.manifestSummary(manifest).contains(second.id.rawValue))

        let chosen = BlindJudgmentWorkflow.choosing(.responseA, in: pending)
        model.judgment = try BlindJudgmentWorkflow.revealing(
            chosen,
            at: Date(timeIntervalSince1970: 10)
        )
        XCTAssertTrue(model.blindTitle(response: "Response A", artifactID: second.id)
            .contains("Second Secret Model"))
        XCTAssertTrue(model.manifestSummary(manifest).contains(first.id.rawValue))
        XCTAssertTrue(try XCTUnwrap(model.revealSummary).contains("Preferred: Response A"))
    }
}
