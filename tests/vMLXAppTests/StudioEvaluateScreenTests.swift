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

        let model = StudioEvaluateViewModel()
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

    func testPromptSuiteModeRequiresOneArtifactAndExportsCanonicalJSONL() throws {
        let model = StudioEvaluateViewModel()
        model.presentationMode = .promptSuite
        model.firstArtifactID = ModelArtifactID()
        model.secondArtifactID = nil
        model.promptSuite = try PromptSuiteFactory.customPrompts(
            prompts: ["First", "Second"],
            generationConfiguration: .init(maximumTokenCount: 16, seed: 42)
        )
        model.resumableRequest = nil

        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.runButtonTitle, "Run Prompt Suite")
        XCTAssertEqual(model.templateIdentifier, PromptSuiteRunner.templateIdentifier)
        XCTAssertTrue(model.modeSubtitle.contains("resumability"))
        XCTAssertEqual(
            try EvaluationJSONL.decode(XCTUnwrap(model.exportData)),
            model.promptSuite
        )

        model.resumableRequest = EvaluationRunRequest(
            suite: try XCTUnwrap(model.promptSuite),
            candidates: [.init(
                artifactID: try XCTUnwrap(model.firstArtifactID),
                blindLabel: "Candidate"
            )],
            executionOrder: [try XCTUnwrap(model.firstArtifactID)]
        )
        XCTAssertEqual(model.runButtonTitle, "Resume Prompt Suite")
    }

    func testLossAttributionRequiresDistinctVariantsAndDescribesPartialMatrix() throws {
        let projectID = ModelProjectID()
        let a = ModelArtifact(
            projectID: projectID,
            name: "Variant A",
            localURL: URL(fileURLWithPath: "/models/variant-a"),
            format: .mlx,
            precision: .init(rawValue: "bf16"),
            state: .ready
        )
        let b = ModelArtifact(
            projectID: projectID,
            parentArtifactID: a.id,
            name: "Variant B",
            localURL: URL(fileURLWithPath: "/models/variant-b"),
            format: .jang,
            precision: .init(rawValue: "4-bit"),
            state: .ready
        )
        let c = ModelArtifact(
            projectID: projectID,
            parentArtifactID: a.id,
            name: "Variant C",
            localURL: URL(fileURLWithPath: "/models/variant-c"),
            format: .mlx,
            precision: .init(rawValue: "bf16"),
            state: .ready
        )
        let d = ModelArtifact(
            projectID: projectID,
            parentArtifactID: c.id,
            name: "Variant D",
            localURL: URL(fileURLWithPath: "/models/variant-d"),
            format: .jang,
            precision: .init(rawValue: "4-bit"),
            state: .ready
        )
        let artifacts = [a, b, c, d]
        let model = StudioEvaluateViewModel()
        model.artifacts = artifacts
        model.promptSuite = try PromptSuiteFactory.customPrompts(
            prompts: ["Return four"],
            generationConfiguration: .init(maximumTokenCount: 16, seed: 42)
        )
        model.presentationMode = .lossAttribution

        XCTAssertEqual(model.selectedLossArtifactIDs, artifacts.map(\.id))
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.runButtonTitle, "Run Loss Attribution")
        XCTAssertTrue(model.lossPlanSummary.contains("Full A/B/C/D"))
        XCTAssertEqual(model.templateIdentifier, PromptSuiteRunner.templateIdentifier)

        model.secondArtifactID = nil
        model.thirdArtifactID = nil
        XCTAssertTrue(model.canRun)
        XCTAssertTrue(model.lossPlanSummary.contains("missing B, C"))
        XCTAssertEqual(model.currentLossPlan?.comparisons.last?.state, .notEvaluated)

        model.fourthArtifactID = model.firstArtifactID
        XCTAssertFalse(model.canRun)
        XCTAssertNotNil(model.lossSelectionIssue)
    }

    func testLossAttributionRejectsUnrelatedModelProjects() throws {
        let model = StudioEvaluateViewModel()
        model.artifacts = (0..<2).map { index in
            ModelArtifact(
                projectID: ModelProjectID(),
                name: "Unrelated \(index)",
                localURL: URL(fileURLWithPath: "/models/unrelated-\(index)"),
                format: index == 0 ? .mlx : .jang,
                precision: .init(rawValue: index == 0 ? "bf16" : "4-bit"),
                state: .ready
            )
        }
        model.firstArtifactID = model.artifacts[0].id
        model.secondArtifactID = model.artifacts[1].id
        model.promptSuite = try PromptSuiteFactory.customPrompts(
            prompts: ["Return two"],
            generationConfiguration: .init(maximumTokenCount: 8, seed: 42)
        )
        model.presentationMode = .lossAttribution

        XCTAssertFalse(model.canRun)
        XCTAssertTrue(model.lossSelectionIssue?.contains("one canonical model project") == true)
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

        XCTAssertTrue(StudioEvaluateViewModel.isSelectableArtifact(discovered))
        XCTAssertFalse(StudioEvaluateViewModel.isSelectableArtifact(unavailable))
    }

    func testBlindPresentationHidesIdentityAndOrderUntilPersistedReveal() throws {
        let model = StudioEvaluateViewModel()
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
