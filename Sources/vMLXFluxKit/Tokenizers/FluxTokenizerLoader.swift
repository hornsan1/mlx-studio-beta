// SPDX-License-Identifier: Apache-2.0
//
// swift-transformers' AutoTokenizer expects a full HF-style model folder
// (`config.json`, `tokenizer_config.json`, `tokenizer.json`). FLUX image
// snapshots often put only tokenizer assets in component subdirectories.
// This helper builds a tiny temporary shadow directory so the tokenizer
// can hydrate without copying model weights or mutating the HF cache.

import Foundation
@preconcurrency import Tokenizers

public enum FluxTokenizerLoader {
    public static func loadAutoTokenizer(
        from directory: URL,
        modelType: String,
        tokenizerClassOverride: String? = nil
    ) async throws -> any Tokenizers.Tokenizer {
        let prepared = try prepareDirectoryForAutoTokenizer(
            sourceDirectory: directory,
            modelType: modelType,
            tokenizerClassOverride: tokenizerClassOverride
        )
        defer { try? FileManager.default.removeItem(at: prepared) }
        return try await AutoTokenizer.from(modelFolder: prepared)
    }

    public static func prepareDirectoryForAutoTokenizer(
        sourceDirectory: URL,
        modelType: String,
        tokenizerClassOverride: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let shadow = fm.temporaryDirectory
            .appendingPathComponent("vmlx-flux-tokenizer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: shadow, withIntermediateDirectories: true)

        let children = try fm.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        )
        for source in children {
            let name = source.lastPathComponent
            guard name != "config.json", name != "tokenizer_config.json" else {
                continue
            }
            try fm.createSymbolicLink(
                at: shadow.appendingPathComponent(name),
                withDestinationURL: source
            )
        }

        try writeModelConfig(
            sourceDirectory: sourceDirectory,
            shadow: shadow,
            modelType: modelType
        )
        try writeTokenizerConfig(
            sourceDirectory: sourceDirectory,
            shadow: shadow,
            modelType: modelType,
            tokenizerClassOverride: tokenizerClassOverride
        )
        return shadow
    }

    private static func writeModelConfig(
        sourceDirectory: URL,
        shadow: URL,
        modelType: String
    ) throws {
        let source = sourceDirectory.appendingPathComponent("config.json")
        let destination = shadow.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            return
        }
        try writeJSONObject(["model_type": modelType], to: destination)
    }

    private static func writeTokenizerConfig(
        sourceDirectory: URL,
        shadow: URL,
        modelType: String,
        tokenizerClassOverride: String?
    ) throws {
        let source = sourceDirectory.appendingPathComponent("tokenizer_config.json")
        let destination = shadow.appendingPathComponent("tokenizer_config.json")
        var object: [String: Any]
        if let data = try? Data(contentsOf: source),
           let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        } else {
            object = [:]
        }
        if object["tokenizer_class"] == nil {
            object["tokenizer_class"] = defaultTokenizerClass(for: modelType)
        }
        if let tokenizerClassOverride {
            object["tokenizer_class"] = tokenizerClassOverride
        }
        try writeJSONObject(object, to: destination)
    }

    private static func defaultTokenizerClass(for modelType: String) -> String {
        switch modelType.lowercased() {
        case "t5":
            return "T5Tokenizer"
        case "qwen2", "qwen2_vl", "qwen2-vl", "qwen":
            return "Qwen2Tokenizer"
        default:
            return "PreTrainedTokenizer"
        }
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }
}
