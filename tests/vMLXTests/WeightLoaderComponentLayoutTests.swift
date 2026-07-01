// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXFluxKit

final class WeightLoaderComponentLayoutTests: XCTestCase {
    func testDiffusionShardManifestPreservesComponentNames() throws {
        let root = try makeFluxLikeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifests = try WeightLoader.shardManifest(in: root)
        let byComponent = Dictionary(uniqueKeysWithValues: manifests.compactMap { manifest in
            manifest.component.map { ($0, manifest.urls.map(\.lastPathComponent)) }
        })

        XCTAssertEqual(byComponent["transformer"], ["0.safetensors", "1.safetensors"])
        XCTAssertEqual(byComponent["text_encoder"], ["0.safetensors"])
        XCTAssertEqual(byComponent["text_encoder_2"], ["0.safetensors"])
        XCTAssertEqual(byComponent["vae"], ["0.safetensors"])
    }

    func testFluxStyleLayoutVerificationChecksComponentsAndTokenizers() throws {
        let root = try makeFluxLikeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            WeightLoader.componentLayoutIssues(
                in: root,
                requiredComponents: ["transformer", "text_encoder", "text_encoder_2", "vae"],
                requiredFiles: ["tokenizer/tokenizer.json", "tokenizer_2/tokenizer.json"]
            ).isEmpty
        )

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("text_encoder_2/0.safetensors")
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("tokenizer_2/tokenizer.json")
        )

        let issues = WeightLoader.componentLayoutIssues(
            in: root,
            requiredComponents: ["transformer", "text_encoder", "text_encoder_2", "vae"],
            requiredFiles: ["tokenizer/tokenizer.json", "tokenizer_2/tokenizer.json"]
        )

        XCTAssertTrue(issues.contains("text_encoder_2/0.safetensors is missing"))
        XCTAssertTrue(issues.contains("tokenizer_2/tokenizer.json is missing"))
    }

    private func makeFluxLikeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-flux-layout-\(UUID().uuidString)", isDirectory: true)
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
            weightMap: [
                "x_embedder.weight": "0.safetensors",
                "single_blocks.0.linear.weight": "1.safetensors",
            ]
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
