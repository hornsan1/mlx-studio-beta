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
}
