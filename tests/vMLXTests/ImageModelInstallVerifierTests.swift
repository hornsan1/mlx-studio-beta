// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class ImageModelInstallVerifierTests: XCTestCase {
    func testFlux1SchnellLayoutPassesWhenRequiredComponentsExist() throws {
        let root = try makeFlux1Directory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNoThrow(
            try ImageModelInstallVerifier.validate(
                runtimeName: "flux1-schnell",
                repo: "mlx-community/FLUX.1-schnell-4bit",
                localPath: root
            )
        )
    }

    func testFlux1SchnellManifestVerificationIsPartOfReadiness() throws {
        let root = try makeFlux1Directory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cleanManifest = [
            HuggingFaceDownloadSafety.RemoteFile(path: "transformer/0.safetensors", size: 4),
            HuggingFaceDownloadSafety.RemoteFile(path: "tokenizer/tokenizer.json", size: 2),
        ]

        XCTAssertTrue(
            ImageModelInstallVerifier.issues(
                runtimeName: "flux1-schnell",
                repo: "mlx-community/FLUX.1-schnell-4bit",
                localPath: root,
                manifestFiles: cleanManifest
            ).isEmpty
        )

        let brokenManifest = [
            HuggingFaceDownloadSafety.RemoteFile(path: "transformer/0.safetensors", size: 99),
            HuggingFaceDownloadSafety.RemoteFile(path: "missing.safetensors", size: 4),
        ]

        let issues = ImageModelInstallVerifier.issues(
            runtimeName: "flux1-schnell",
            repo: "mlx-community/FLUX.1-schnell-4bit",
            localPath: root,
            manifestFiles: brokenManifest
        )

        XCTAssertTrue(issues.contains("transformer/0.safetensors has the wrong size"))
        XCTAssertTrue(issues.contains("missing.safetensors is missing"))
    }

    func testFlux1SchnellLayoutReportsMissingComponentAndTokenizer() throws {
        let root = try makeFlux1Directory()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("text_encoder_2/0.safetensors")
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("tokenizer_2/tokenizer.json")
        )

        let issues = ImageModelInstallVerifier.issues(
            runtimeName: "flux1-schnell",
            repo: "mlx-community/FLUX.1-schnell-4bit",
            localPath: root
        )

        XCTAssertTrue(issues.contains("text_encoder_2/0.safetensors is missing"))
        XCTAssertTrue(issues.contains("tokenizer_2/tokenizer.json is missing"))
    }

    func testZImageTurboLayoutRequiresTokenizer() throws {
        let root = try makeZImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            ImageModelInstallVerifier.issues(
                runtimeName: "z-image-turbo",
                repo: "mlx-community/z-image-turbo-8bit",
                localPath: root
            ).isEmpty
        )

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("tokenizer/tokenizer.json")
        )

        let issues = ImageModelInstallVerifier.issues(
            runtimeName: "z-image-turbo",
            repo: "mlx-community/z-image-turbo-8bit",
            localPath: root
        )

        XCTAssertTrue(issues.contains("tokenizer/tokenizer.json is missing"))
    }

    func testFlux2KleinLayoutPassesWhenRequiredComponentsExist() throws {
        let root = try makeFlux2Directory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            ImageModelInstallVerifier.issues(
                runtimeName: "flux2-klein",
                repo: "mlx-community/flux2-klein-4b-4bit",
                localPath: root
            ).isEmpty
        )

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("tokenizer/tokenizer.json")
        )

        let issues = ImageModelInstallVerifier.issues(
            runtimeName: "flux2-klein",
            repo: "mlx-community/flux2-klein-4b-4bit",
            localPath: root
        )

        XCTAssertTrue(issues.contains("tokenizer/tokenizer.json is missing"))
    }

    func testUnknownImageRuntimeIsBlocked() throws {
        let root = try makeFlux1Directory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            ImageModelInstallVerifier.issues(
                runtimeName: "some-image-model",
                repo: "example/some-image-model",
                localPath: root
            ),
            ["Unsupported image runtime 'some-image-model'."]
        )
    }

    func testQwenImageInstallIsBlockedUntilPromptProvenRuntimeExists() throws {
        let root = try makeZImageDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let issues = ImageModelInstallVerifier.issues(
            runtimeName: "qwen-image",
            repo: "mlx-community/Qwen-Image-4bit",
            localPath: root
        )

        XCTAssertEqual(
            issues,
            ["Qwen-Image is scaffolded in this beta, but not prompt-proven by the vMLX image runtime yet."]
        )
    }

    private func makeFlux1Directory() throws -> URL {
        let root = try makeDirectory(named: "vmlx-image-flux1")
        for component in ["transformer", "text_encoder", "text_encoder_2", "vae"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tokenizer", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tokenizer_2", isDirectory: true),
            withIntermediateDirectories: true
        )

        try writeIndex(
            root.appendingPathComponent("transformer"),
            weightMap: ["x_embedder.weight": "0.safetensors"]
        )
        try writeIndex(
            root.appendingPathComponent("text_encoder"),
            weightMap: ["text_model.embeddings.token_embedding.weight": "0.safetensors"]
        )
        try writeIndex(
            root.appendingPathComponent("text_encoder_2"),
            weightMap: ["shared.weight": "0.safetensors"]
        )
        try writeIndex(
            root.appendingPathComponent("vae"),
            weightMap: ["decoder.conv_in.conv2d.weight": "0.safetensors"]
        )
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer/tokenizer.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer_2/tokenizer.json"))
        return root
    }

    private func makeZImageDirectory() throws -> URL {
        let root = try makeDirectory(named: "vmlx-image-zimage")
        for component in ["transformer", "text_encoder", "vae"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tokenizer", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeIndex(
            root.appendingPathComponent("transformer"),
            weightMap: ["img_in.weight": "0.safetensors"]
        )
        try writeIndex(
            root.appendingPathComponent("text_encoder"),
            weightMap: ["model.embed_tokens.weight": "0.safetensors"]
        )
        try writeIndex(
            root.appendingPathComponent("vae"),
            weightMap: ["decoder.conv_in.conv2d.weight": "0.safetensors"]
        )
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer/tokenizer.json"))
        return root
    }

    private func makeFlux2Directory() throws -> URL {
        let root = try makeDirectory(named: "vmlx-image-flux2")
        for component in ["transformer", "text_encoder", "vae"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tokenizer", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeIndex(
            root.appendingPathComponent("transformer"),
            weightMap: ["context_embedder.weight": "0.safetensors"]
        )
        try writeIndex(
            root.appendingPathComponent("text_encoder"),
            weightMap: ["model.embed_tokens.weight": "0.safetensors"]
        )
        try writeIndex(
            root.appendingPathComponent("vae"),
            weightMap: ["decoder.conv_in.conv2d.weight": "0.safetensors"]
        )
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer/tokenizer.json"))
        return root
    }

    private func makeDirectory(named prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeIndex(_ directory: URL, weightMap: [String: String]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["weight_map": weightMap],
            options: [.sortedKeys]
        )
        try data.write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        for shard in Set(weightMap.values) {
            try Data("stub".utf8).write(to: directory.appendingPathComponent(shard))
        }
    }
}
