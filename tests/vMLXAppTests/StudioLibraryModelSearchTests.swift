import Foundation
import XCTest
@testable import vMLXApp

final class StudioLibraryModelSearchTests: XCTestCase {
    func testSearchTokensIncludeVisiblePathReportFieldsAndLoadedState() {
        let model = ModelSummary(
            id: "loaded",
            ref: ModelRef(
                id: "loaded",
                displayName: "Smoke-Library-Model",
                repo: "local/smoke-library-model",
                localURL: URL(fileURLWithPath: "/Users/hermes/.mlxstudio/models/Smoke-Library-Model", isDirectory: true)
            ),
            family: "qwen2",
            modality: "text",
            sizeBytes: 9_437_184,
            labels: ["Chat", "Fast"],
            isLoaded: true
        )

        let summary = StudioLibraryModelSearch.summary(for: model)

        XCTAssertEqual(summary.loadStateLabel, "Loaded")
        XCTAssertTrue(containsToken("Smoke-Library-Model", in: summary.searchTokens))
        XCTAssertTrue(containsToken("local path /Users/hermes/.mlxstudio/models/Smoke-Library-Model", in: summary.searchTokens))
        XCTAssertTrue(containsToken("repo local/smoke-library-model", in: summary.searchTokens))
        XCTAssertTrue(containsToken("loaded model", in: summary.searchTokens))
        XCTAssertTrue(containsToken("ready in memory", in: summary.searchTokens))
        XCTAssertTrue(containsToken("9437184", in: summary.searchTokens))
        XCTAssertTrue(containsToken("Chat", in: summary.searchTokens))
    }

    func testNotLoadedStateIsExplicitAndSearchable() {
        let model = ModelSummary(
            id: "cold",
            ref: ModelRef(
                id: "cold",
                displayName: "Cold Model",
                repo: nil,
                localURL: URL(fileURLWithPath: "/tmp/mlx-studio/Cold Model", isDirectory: true)
            ),
            family: "flux",
            modality: "image",
            sizeBytes: 1_024,
            labels: ["Image"],
            isLoaded: false
        )

        let summary = StudioLibraryModelSearch.summary(for: model)

        XCTAssertEqual(summary.loadStateLabel, "Not loaded")
        XCTAssertTrue(containsToken("not loaded model", in: summary.searchTokens))
        XCTAssertTrue(containsToken("downloaded model", in: summary.searchTokens))
        XCTAssertTrue(containsToken("available on disk", in: summary.searchTokens))
        XCTAssertTrue(containsToken("/tmp/mlx-studio/Cold Model", in: summary.searchTokens))
    }

    func testArchiveSpotlightPrefersSelectedModelOverAlphabeticalImage() {
        let selectedPath = URL(
            fileURLWithPath: "/Users/hermes/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-8bit/snapshots/main",
            isDirectory: true
        )
        let imageModel = makeModel(
            id: "a-image",
            displayName: "AITRADER/FLUX1-schnell-mlx-4bit",
            path: "/Users/hermes/.cache/huggingface/hub/models--AITRADER--FLUX1-schnell-mlx-4bit/snapshots/main",
            family: "flux1-schnell",
            modality: "image"
        )
        let selectedChatModel = makeModel(
            id: "qwen",
            displayName: "mlx-community/Qwen3-0.6B-8bit",
            path: selectedPath.path,
            family: "qwen3",
            modality: "text"
        )

        let spotlight = StudioLibraryModelArchive.spotlightModel(
            in: [imageModel, selectedChatModel],
            selectedModelPath: selectedPath
        )

        XCTAssertEqual(spotlight?.id, "qwen")
    }

    func testArchiveSpotlightPrefersLoadedModelWithoutSelection() {
        let coldImageModel = makeModel(
            id: "a-image",
            displayName: "AITRADER/FLUX1-schnell-mlx-4bit",
            path: "/tmp/mlx-studio/AITRADER-FLUX",
            family: "flux",
            modality: "image"
        )
        let loadedChatModel = makeModel(
            id: "loaded-chat",
            displayName: "Loaded Chat Model",
            path: "/tmp/mlx-studio/Loaded-Chat-Model",
            family: "qwen3",
            modality: "text",
            isLoaded: true
        )

        let spotlight = StudioLibraryModelArchive.spotlightModel(
            in: [coldImageModel, loadedChatModel],
            selectedModelPath: nil
        )

        XCTAssertEqual(spotlight?.id, "loaded-chat")
    }

    func testArchiveSpotlightPrefersChatModelBeforeColdImageFallback() {
        let coldImageModel = makeModel(
            id: "a-image",
            displayName: "AITRADER/FLUX1-schnell-mlx-4bit",
            path: "/tmp/mlx-studio/AITRADER-FLUX",
            family: "flux",
            modality: "image"
        )
        let coldChatModel = makeModel(
            id: "cold-chat",
            displayName: "Cold Chat Model",
            path: "/tmp/mlx-studio/Cold-Chat-Model",
            family: "qwen3",
            modality: "text"
        )

        let spotlight = StudioLibraryModelArchive.spotlightModel(
            in: [coldImageModel, coldChatModel],
            selectedModelPath: nil
        )

        XCTAssertEqual(spotlight?.id, "cold-chat")
    }

    private func containsToken(_ needle: String, in tokens: [String]) -> Bool {
        tokens.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func makeModel(
        id: String,
        displayName: String,
        path: String,
        family: String,
        modality: String,
        isLoaded: Bool = false
    ) -> ModelSummary {
        ModelSummary(
            id: id,
            ref: ModelRef(
                id: id,
                displayName: displayName,
                repo: nil,
                localURL: URL(fileURLWithPath: path, isDirectory: true)
            ),
            family: family,
            modality: modality,
            sizeBytes: 1_024,
            labels: [],
            isLoaded: isLoaded
        )
    }
}
