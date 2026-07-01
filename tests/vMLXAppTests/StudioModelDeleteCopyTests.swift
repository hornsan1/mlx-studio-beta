import Foundation
import XCTest
@testable import vMLXApp

final class StudioModelDeleteCopyTests: XCTestCase {
    func testDeleteCopyDistinguishesFileRemovalFromLibraryRecordRemoval() {
        let model = makeModel()

        XCTAssertEqual(StudioModelDeleteCopy.actionTitle, "Delete Files")
        XCTAssertEqual(
            StudioModelDeleteCopy.accessibilityTitle(for: model),
            "Delete model files Smoke-Delete-Model"
        )
        XCTAssertEqual(
            StudioModelDeleteCopy.confirmationButtonTitle(for: model),
            "Delete files for Smoke-Delete-Model"
        )
        XCTAssertEqual(
            StudioModelDeleteCopy.successStatus(for: model),
            "Deleted model files for Smoke-Delete-Model"
        )

        let message = StudioModelDeleteCopy.confirmationMessage(for: model)
        XCTAssertTrue(message.contains("removes the model folder from disk"))
        XCTAssertTrue(message.contains("/tmp/mlx-studio-tests/Smoke-Delete-Model"))
        XCTAssertTrue(message.contains("not just a Library record"))
        XCTAssertEqual(StudioModelDeleteCopy.recordWarning, "This is not just a Library record.")
    }

    func testLoadedModelDeleteCopyIsDisabledUntilStopped() {
        var model = makeModel()
        XCTAssertNil(StudioModelDeleteCopy.disabledReason(for: model))

        model.isLoaded = true
        XCTAssertEqual(
            StudioModelDeleteCopy.disabledReason(for: model),
            "Stop this loaded model before deleting its files."
        )
    }

    private func makeModel() -> ModelSummary {
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
}
