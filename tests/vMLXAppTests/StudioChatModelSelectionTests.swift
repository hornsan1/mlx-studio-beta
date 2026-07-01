import Foundation
import XCTest
import vMLXEngine
@testable import vMLXApp

final class StudioChatModelSelectionTests: XCTestCase {
    func testChatSelectionFallsBackFromImageSelectedPathToChatModel() {
        let image = model(
            id: "flux",
            name: "AITRADER/FLUX1-schnell-mlx-4bit",
            modality: "image",
            family: "flux1-schnell",
            path: "/tmp/mlx-studio-tests/flux"
        )
        let chat = model(
            id: "qwen",
            name: "mlx-community/Qwen3-0.6B-8bit",
            modality: "text",
            family: "qwen3",
            path: "/tmp/mlx-studio-tests/qwen"
        )

        let selectedID = StudioChatModelSelection.selectedModelID(
            currentID: image.id,
            selectedPath: image.ref.localURL,
            models: [image, chat]
        )

        XCTAssertEqual(selectedID, chat.id)
        XCTAssertEqual(StudioChatModelSelection.chatCapableModels(in: [image, chat]).map(\.id), [chat.id])
    }

    func testChatSelectionHonorsChatCapableSelectedPathBeforeCurrentID() {
        let current = model(
            id: "qwen-small",
            name: "mlx-community/Qwen3-0.6B-8bit",
            modality: "text",
            family: "qwen3",
            path: "/tmp/mlx-studio-tests/qwen-small"
        )
        let selected = model(
            id: "qwen-large",
            name: "mlx-community/Qwen3-4B-8bit",
            modality: "text",
            family: "qwen3",
            path: "/tmp/mlx-studio-tests/qwen-large"
        )

        let selectedID = StudioChatModelSelection.selectedModelID(
            currentID: current.id,
            selectedPath: selected.ref.localURL,
            models: [current, selected]
        )

        XCTAssertEqual(selectedID, selected.id)
    }

    func testChatSelectionHonorsSavedSessionModelBeforeGlobalSelectedPath() {
        let global = model(
            id: "qwen",
            name: "mlx-community/Qwen3-0.6B-8bit",
            modality: "text",
            family: "qwen3",
            path: "/tmp/mlx-studio-tests/qwen"
        )
        let saved = model(
            id: "smoke-switch",
            name: "Smoke-Switch-Model",
            modality: "text",
            family: "fixture",
            path: "/tmp/mlx-studio-tests/smoke-switch"
        )

        let selectedID = StudioChatModelSelection.selectedModelID(
            currentID: global.id,
            selectedPath: global.ref.localURL,
            sessionModelName: "Smoke-Switch-Model",
            models: [global, saved]
        )

        XCTAssertEqual(selectedID, saved.id)
        XCTAssertEqual(
            StudioChatModelSelection.chatModel(matching: "Smoke-Switch-Model", in: [global, saved])?.id,
            saved.id
        )
    }

    private func model(
        id: String,
        name: String,
        modality: String,
        family: String,
        path: String
    ) -> ModelSummary {
        ModelSummary(
            id: id,
            ref: ModelRef(
                id: id,
                displayName: name,
                repo: nil,
                localURL: URL(fileURLWithPath: path, isDirectory: true)
            ),
            family: family,
            modality: modality,
            sizeBytes: 1_024,
            labels: [],
            isLoaded: false
        )
    }
}
