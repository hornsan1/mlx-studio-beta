import JANGExpertLab
import MLXStudioDomain
import XCTest
@testable import vMLXApp

@MainActor
final class StudioOptimizeScreenTests: XCTestCase {
    func testOptimizeIsAFirstClassModeInBothExperienceLevels() {
        XCTAssertTrue(AppState.Mode.visible(for: .beginner).contains(.optimize))
        XCTAssertTrue(AppState.Mode.visible(for: .advanced).contains(.optimize))
        XCTAssertFalse(AppState.Mode.optimize.isAdvancedOnly)
    }

    func testObjectivePresetsProduceExplicitDomainConstraints() {
        let notes = "fixture"
        let balanced = StudioOptimizationObjectivePreset.balanced.objective(notes: notes)
        let smaller = StudioOptimizationObjectivePreset.smaller.objective(notes: notes)
        let quality = StudioOptimizationObjectivePreset.preserveQuality.objective(notes: notes)
        let faster = StudioOptimizationObjectivePreset.faster.objective(notes: notes)

        XCTAssertEqual(balanced.minimumQualityScore, 0.95)
        XCTAssertEqual(smaller.maximumArtifactSizeBytes, 8_000_000_000)
        XCTAssertEqual(quality.minimumQualityScore, 0.99)
        XCTAssertEqual(faster.targetTokensPerSecond, 20)
        XCTAssertEqual(faster.notes, notes)
    }

    func testSelectableArtifactsIncludeExistingDiscoveredModelsButRejectUnsafeStates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("optimize-selectable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = ModelProjectID()
        let discovered = ModelArtifact(
            projectID: projectID,
            name: "Discovered",
            localURL: root,
            format: .mlx,
            state: .discovered
        )
        let unavailable = ModelArtifact(
            projectID: projectID,
            name: "Unavailable",
            localURL: root,
            format: .mlx,
            state: .unavailable
        )
        let missing = ModelArtifact(
            projectID: projectID,
            name: "Missing",
            localURL: root.appendingPathComponent("missing"),
            format: .mlx,
            state: .ready
        )

        XCTAssertTrue(StudioOptimizeViewModel.isSelectableArtifact(discovered))
        XCTAssertFalse(StudioOptimizeViewModel.isSelectableArtifact(unavailable))
        XCTAssertFalse(StudioOptimizeViewModel.isSelectableArtifact(missing))
    }

    func testTopologyAndAtlasEvidenceProduceAutomaticExpertControls() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("optimize-topology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model_type":"qwen3_5_moe","text_config":{"model_type":"qwen3_5_moe_text","num_hidden_layers":2,"num_experts":4,"num_experts_per_tok":2}}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        let topology = try StudioOptimizeViewModel.readTopology(at: root)
        XCTAssertEqual(topology.architecture, "qwen3_moe")
        XCTAssertEqual(topology.layers.count, 2)
        XCTAssertEqual(topology.layers.first?.trainedTopK, 2)

        let artifact = ModelArtifact(
            projectID: ModelProjectID(),
            name: "hf/Qwen fixture",
            localURL: root,
            format: .mlx,
            state: .ready
        )
        XCTAssertEqual(
            StudioOptimizeViewModel.defaultOutputPath(
                for: artifact,
                applicationSupportURL: root.appendingPathComponent("Application Support")
            ),
            root.appendingPathComponent(
                "Application Support/MLX Studio/Artifacts/Qwen fixture-optimized"
            ).path
        )

        let atlas = ExpertAtlas(promptCount: 50, experts: [
            .init(
                layer: 0,
                expert: 3,
                hits: 0,
                probabilityMass: 0,
                tokenCount: 100,
                domains: [:],
                label: "dead",
                isDead: true,
                isHot: false
            ),
            .init(
                layer: 1,
                expert: 2,
                hits: 40,
                probabilityMass: 20,
                tokenCount: 100,
                domains: ["code": 40],
                label: "code specialist",
                isDead: false,
                isHot: true
            ),
        ])
        XCTAssertEqual(
            StudioOptimizeViewModel.automaticRemovals(from: atlas),
            [MLXStudioDomain.ExpertCoordinate(layerIndex: 0, expertIndex: 3)]
        )
    }

    func testInvalidMaskOrMismatchedReviewedMapBlocksPruneRun() {
        let valid = OptimizationPlanValidation(
            result: .init(status: .valid),
            structuralMask: .init(removedExpertsByLayer: [0: [3]])
        )
        let invalid = OptimizationPlanValidation(
            result: .init(status: .invalid, errors: ["Layer 0 has too few survivors."]),
            structuralMask: nil
        )

        XCTAssertTrue(StudioOptimizeViewModel.isPruneRunnable(
            preview: valid,
            keepMapPath: "/tmp/reviewed.json",
            keepMapValidationError: nil
        ))
        XCTAssertFalse(StudioOptimizeViewModel.isPruneRunnable(
            preview: invalid,
            keepMapPath: "/tmp/reviewed.json",
            keepMapValidationError: nil
        ))
        XCTAssertFalse(StudioOptimizeViewModel.isPruneRunnable(
            preview: valid,
            keepMapPath: "/tmp/reviewed.json",
            keepMapValidationError: "mask mismatch"
        ))
        XCTAssertFalse(StudioOptimizeViewModel.isPruneRunnable(
            preview: valid,
            keepMapPath: "",
            keepMapValidationError: nil
        ))
    }
}
