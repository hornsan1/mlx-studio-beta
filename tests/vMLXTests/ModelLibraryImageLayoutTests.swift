// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class ModelLibraryImageLayoutTests: XCTestCase {
    func testIncompleteSafetensorShardSetIsNotReady() throws {
        let root = try makeDirectory(named: "incomplete-shards")
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("first".utf8).write(
            to: root.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        XCTAssertFalse(ModelLibrary.hasCompleteSafetensorShardSets(at: root))
    }

    func testCompleteSafetensorShardSetIsReady() throws {
        let root = try makeDirectory(named: "complete-shards")
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 1...2 {
            try Data("shard \(index)".utf8).write(
                to: root.appendingPathComponent(
                    String(format: "model-%05d-of-%05d.safetensors", index, 2)
                )
            )
        }

        XCTAssertTrue(ModelLibrary.hasCompleteSafetensorShardSets(at: root))
    }

    func testUnshardedSafetensorModelRemainsReady() throws {
        let root = try makeDirectory(named: "unsharded-model")
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))

        XCTAssertTrue(ModelLibrary.hasCompleteSafetensorShardSets(at: root))
    }

    func testIncompleteShardedModelIsNotDiscoveredUntilAllShardsArrive() async throws {
        let root = try makeDirectory(named: "model-library-shard-discovery")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("chat-model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen3\"}".utf8).write(
            to: model.appendingPathComponent("config.json")
        )
        try writeDiscoveryWeight(
            to: model.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        let database = ModelLibraryDB(customPath: root.appendingPathComponent("models.sqlite3"))
        let library = ModelLibrary(database: database)
        await library.addUserDir(root)

        let incompleteEntries = await library.scan(force: true)
        XCTAssertFalse(incompleteEntries.contains {
            $0.canonicalPath == model.standardizedFileURL
        })

        try writeDiscoveryWeight(
            to: model.appendingPathComponent("model-00002-of-00002.safetensors")
        )

        let entries = await library.scan(force: true)
        XCTAssertEqual(
            entries.filter { $0.canonicalPath == model.standardizedFileURL }.count,
            1
        )
    }

    func testFlux2ComponentLayoutIsLoadableImageRuntimeLayout() throws {
        let root = try makeImageLayoutDirectory(named: "flux2-klein")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(ModelLibrary.hasImageRuntimeLayout(at: root))
        XCTAssertEqual(
            ModelLibrary.imageRuntimeNameHint(in: "mlx-community/flux2-klein-4b-4bit \(root.path)"),
            "flux2-klein"
        )
    }

    func testKrea2ImageRuntimeHintIsRecognized() throws {
        let root = try makeImageLayoutDirectory(named: "krea-2-turbo")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            ModelLibrary.imageRuntimeNameHint(in: "krea/Krea-2-Turbo \(root.path)"),
            "krea-2-turbo"
        )
    }

    func testImageLayoutRequiresTokenizerAndVAE() throws {
        let missingTokenizer = try makeImageLayoutDirectory(named: "flux-without-tokenizer")
        defer { try? FileManager.default.removeItem(at: missingTokenizer) }
        try FileManager.default.removeItem(
            at: missingTokenizer.appendingPathComponent("tokenizer/tokenizer.json")
        )

        XCTAssertFalse(ModelLibrary.hasImageRuntimeLayout(at: missingTokenizer))

        let missingVAE = try makeImageLayoutDirectory(named: "flux-without-vae")
        defer { try? FileManager.default.removeItem(at: missingVAE) }
        try FileManager.default.removeItem(
            at: missingVAE.appendingPathComponent("vae/0.safetensors")
        )

        XCTAssertFalse(ModelLibrary.hasImageRuntimeLayout(at: missingVAE))
    }

    private func makeImageLayoutDirectory(named name: String) throws -> URL {
        let root = try makeDirectory(named: name)
        for component in ["transformer", "text_encoder", "vae", "tokenizer"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("stub".utf8).write(to: root.appendingPathComponent("transformer/0.safetensors"))
        try Data("stub".utf8).write(to: root.appendingPathComponent("text_encoder/0.safetensors"))
        try Data("stub".utf8).write(to: root.appendingPathComponent("vae/0.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer/tokenizer.json"))
        return root
    }

    private func makeDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func writeDiscoveryWeight(to url: URL) throws {
        let size = 8 * 1024 * 1024
        try Data(repeating: 0, count: size).write(to: url)
    }
}
