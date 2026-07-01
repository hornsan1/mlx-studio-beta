// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class ModelLibraryImageLayoutTests: XCTestCase {
    func testFlux2ComponentLayoutIsLoadableImageRuntimeLayout() throws {
        let root = try makeImageLayoutDirectory(named: "flux2-klein")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(ModelLibrary.hasImageRuntimeLayout(at: root))
        XCTAssertEqual(
            ModelLibrary.imageRuntimeNameHint(in: "mlx-community/flux2-klein-4b-4bit \(root.path)"),
            "flux2-klein"
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
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
}
