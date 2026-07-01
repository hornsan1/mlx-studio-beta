import Foundation
import XCTest
@testable import vMLXApp

final class StudioModelActionCopyTests: XCTestCase {
    func testTextModelActionsNameTheModelTarget() {
        let model = makeTextModel()
        let readiness = StudioModelRouteReadiness.summary(for: model)

        XCTAssertEqual(
            StudioModelActionCopy.selectAccessibilityTitle(for: model, selected: false),
            "Select model Smoke-Delete-Model"
        )
        XCTAssertEqual(
            StudioModelActionCopy.selectAccessibilityTitle(for: model, selected: true),
            "Selected model Smoke-Delete-Model"
        )
        XCTAssertEqual(
            StudioModelActionCopy.loadAccessibilityTitle(for: model, readiness: readiness),
            "Load - Load model Smoke-Delete-Model"
        )
        XCTAssertEqual(
            StudioModelActionCopy.routeAccessibilityTitle(for: model, readiness: readiness, isImage: false),
            "Chat with Smoke-Delete-Model"
        )
    }

    func testImageModelActionsNameProofRouteAndHonestLoadBlocker() {
        let model = makeImageModel()
        let proofDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioModelActionCopyTests-\(UUID().uuidString)", isDirectory: true)
        let readiness = StudioModelRouteReadiness.summary(for: model, proofDirectory: proofDirectory)

        XCTAssertEqual(
            StudioModelActionCopy.loadAccessibilityTitle(for: model, readiness: readiness),
            "Canvas only - Load model unavailable AITRADER/FLUX1-schnell-mlx-4bit: Image models must be verified in Create; Chat Load only applies to chat-capable models."
        )
        XCTAssertEqual(
            StudioModelActionCopy.routeAccessibilityTitle(for: model, readiness: readiness, isImage: true),
            "Verify in Create AITRADER/FLUX1-schnell-mlx-4bit"
        )
    }

    private func makeTextModel() -> ModelSummary {
        ModelSummary(
            id: "smoke-delete-model",
            ref: ModelRef(
                id: "smoke-delete-model",
                displayName: "Smoke-Delete-Model",
                repo: nil,
                localURL: URL(fileURLWithPath: "/tmp/mlx-studio-tests/Smoke-Delete-Model", isDirectory: true)
            ),
            family: "qwen2",
            modality: "text",
            sizeBytes: 9_437_184,
            labels: ["Chat", "Fast"],
            isLoaded: false
        )
    }

    private func makeImageModel() -> ModelSummary {
        ModelSummary(
            id: "flux1-schnell",
            ref: ModelRef(
                id: "flux1-schnell",
                displayName: "AITRADER/FLUX1-schnell-mlx-4bit",
                repo: nil,
                localURL: URL(fileURLWithPath: "/tmp/mlx-studio-tests/AITRADER/FLUX1-schnell-mlx-4bit", isDirectory: true)
            ),
            family: "flux1-schnell",
            modality: "image",
            sizeBytes: 9_606_737_902,
            labels: ["Image", "Powerful"],
            isLoaded: false
        )
    }
}
