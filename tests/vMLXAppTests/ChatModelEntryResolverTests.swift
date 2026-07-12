import Foundation
import XCTest
import vMLXEngine
@testable import vMLXApp

final class ChatModelEntryResolverTests: XCTestCase {
    func testResolvesDisplayNameAndFreshChatBasenameForHuggingFaceModel() {
        let lfm = entry(
            id: "lfm",
            displayName: "LiquidAI/LFM2.5-350M",
            path: "/tmp/mlx-studio-tests/models--LiquidAI--LFM2.5-350M/snapshots/main"
        )

        XCTAssertEqual(
            ChatModelEntryResolver.resolve(
                alias: "LiquidAI/LFM2.5-350M",
                in: [lfm]
            )?.id,
            lfm.id
        )
        // A fresh chat inherits `selectedModelPath.lastPathComponent`; in an
        // HF cache that is `main`, but older app state can also carry the
        // readable basename. Both must map back to the same discovered row.
        XCTAssertEqual(
            ChatModelEntryResolver.resolve(alias: "LFM2.5-350M", in: [lfm])?.id,
            lfm.id
        )
        XCTAssertEqual(
            ChatModelEntryResolver.resolve(
                alias: "main",
                modelPath: lfm.canonicalPath.path,
                in: [lfm]
            )?.id,
            lfm.id
        )
    }

    func testPersistedIdentityUsesDisplayNameInsteadOfHuggingFaceSnapshotLeaf() {
        let lfm = entry(
            id: "lfm",
            displayName: "LiquidAI/LFM2.5-350M",
            path: "/tmp/mlx-studio-tests/models--LiquidAI--LFM2.5-350M/snapshots/main"
        )

        let identity = ChatModelEntryResolver.persistedIdentity(
            alias: lfm.canonicalPath.path,
            fallbackModelPath: lfm.canonicalPath.path,
            in: [lfm]
        )

        XCTAssertEqual(identity?.name, "LiquidAI/LFM2.5-350M")
        XCTAssertEqual(
            identity?.path,
            lfm.canonicalPath.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertNotEqual(identity?.name, "main")
    }

    func testResolvesDisambiguatedPickerLabel() {
        let first = entry(
            id: "first",
            displayName: "org/Shared-Model",
            path: "/tmp/mlx-studio-tests/a/Shared-Model"
        )
        let second = entry(
            id: "second",
            displayName: "org/Shared-Model",
            path: "/tmp/mlx-studio-tests/b/Shared-Model"
        )
        let entries = [first, second]
        let secondLabel = ChatModelEntryResolver.pickerLabel(for: second, in: entries)

        XCTAssertEqual(secondLabel, "org/Shared-Model (b)")
        XCTAssertEqual(
            ChatModelEntryResolver.resolve(alias: secondLabel, in: entries)?.id,
            second.id
        )
    }

    func testStoredPathBreaksAmbiguousBasenameTie() {
        let first = entry(
            id: "first",
            displayName: "OrgA/LFM2.5-350M",
            path: "/tmp/mlx-studio-tests/orga/LFM2.5-350M"
        )
        let second = entry(
            id: "second",
            displayName: "OrgB/LFM2.5-350M",
            path: "/tmp/mlx-studio-tests/orgb/LFM2.5-350M"
        )
        let entries = [first, second]

        XCTAssertNil(ChatModelEntryResolver.resolve(alias: "LFM2.5-350M", in: entries))
        XCTAssertEqual(
            ChatModelEntryResolver.resolve(
                alias: "LFM2.5-350M",
                modelPath: second.canonicalPath.absoluteString,
                in: entries
            )?.id,
            second.id
        )
    }

    private func entry(
        id: String,
        displayName: String,
        path: String
    ) -> ModelLibrary.ModelEntry {
        ModelLibrary.ModelEntry(
            id: id,
            canonicalPath: URL(fileURLWithPath: path, isDirectory: true),
            displayName: displayName,
            family: "lfm",
            modality: .text,
            totalSizeBytes: 1,
            isJANG: false,
            isMXTQ: false,
            quantBits: nil,
            detectedAt: Date(timeIntervalSince1970: 0),
            source: .downloaded
        )
    }
}
