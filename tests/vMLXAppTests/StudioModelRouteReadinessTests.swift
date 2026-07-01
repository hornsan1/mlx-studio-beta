import Foundation
import XCTest
import vMLXEngine
@testable import vMLXApp

final class StudioModelRouteReadinessTests: XCTestCase {
    func testImageModelNeedsProofUntilPathMatchedRuntimeProofExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioModelRouteReadinessTests-\(UUID().uuidString)", isDirectory: true)
        let modelURL = root.appendingPathComponent("AITRADER/FLUX1-schnell-mlx-4bit", isDirectory: true)
        let proofDirectory = root.appendingPathComponent("proofs", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ModelSummary(
            id: "local-flux1",
            ref: ModelRef(
                id: "local-flux1",
                displayName: "AITRADER/FLUX1-schnell-mlx-4bit",
                repo: nil,
                localURL: modelURL
            ),
            family: "flux1-schnell",
            modality: "image",
            sizeBytes: 9_606_737_902,
            labels: ["Image"],
            isLoaded: false
        )

        let unverified = StudioModelRouteReadiness.summary(
            for: model,
            proofDirectory: proofDirectory
        )
        XCTAssertEqual(unverified.level, .imageNeedsProof)
        XCTAssertEqual(unverified.badge, "Needs proof")
        XCTAssertEqual(unverified.routeValue, "Proof needed")
        XCTAssertEqual(unverified.actionTitle, "Verify in Create")
        XCTAssertEqual(unverified.readyCaption, "Open Create to verify")
        XCTAssertEqual(unverified.loadTitle, "Canvas only")
        XCTAssertEqual(
            unverified.loadDisabledReason,
            "Image models must be verified in Create; Chat Load only applies to chat-capable models."
        )

        let outputURL = root.appendingPathComponent("proof.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: outputURL)
        try ImageRuntimeProofStore.record(
            ImageRuntimeProofStore.Proof(
                runtimeName: "flux1-schnell",
                modelPath: modelURL.path,
                outputPath: outputURL.path,
                width: 256,
                height: 256,
                steps: 1,
                seed: 17,
                pixelVariance: 2
            ),
            directory: proofDirectory
        )

        let proven = StudioModelRouteReadiness.summary(
            for: model,
            proofDirectory: proofDirectory
        )
        XCTAssertEqual(proven.level, .imageProvenReady)
        XCTAssertEqual(proven.badge, "Proven ready")
        XCTAssertEqual(proven.routeValue, "Proven")
        XCTAssertEqual(proven.actionTitle, "Create")
        XCTAssertEqual(proven.readyCaption, "Select or create")
        XCTAssertEqual(proven.loadTitle, "Canvas only")
        XCTAssertEqual(
            proven.loadDisabledReason,
            "Image models open in Create; Chat Load only applies to chat-capable models."
        )
    }

    func testTextModelKeepsChatReadyRoute() {
        let model = ModelSummary(
            id: "qwen",
            ref: ModelRef(
                id: "qwen",
                displayName: "Qwen3-0.6B-8bit",
                repo: nil,
                localURL: URL(fileURLWithPath: "/tmp/qwen")
            ),
            family: "qwen3",
            modality: "text",
            sizeBytes: 633_400_000,
            labels: ["Chat"],
            isLoaded: false
        )

        let summary = StudioModelRouteReadiness.summary(for: model)
        XCTAssertEqual(summary.level, .chatReady)
        XCTAssertEqual(summary.badge, "Chat-ready")
        XCTAssertEqual(summary.routeName, "Chat")
        XCTAssertEqual(summary.routeValue, "Ready")
        XCTAssertEqual(summary.actionTitle, "Chat")
        XCTAssertEqual(summary.readyCaption, "Select, load, or chat")
        XCTAssertEqual(summary.loadTitle, "Load")
        XCTAssertNil(summary.loadDisabledReason)
    }
}
