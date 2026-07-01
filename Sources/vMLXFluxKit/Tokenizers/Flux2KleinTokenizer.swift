// SPDX-License-Identifier: Apache-2.0
//
// FLUX.2 Klein uses a single Qwen-family tokenizer for its text encoder.
// Keep this adapter small and boring: route the model layout, hydrate the
// Hugging Face tokenizer, and cap prompt length to the encoder budget.

import Foundation
@preconcurrency import Tokenizers

public struct Flux2KleinTokenizer: Sendable {
    public let inner: any Tokenizers.Tokenizer
    public let maxLen: Int

    public static let defaultMaxLen = 256

    public init(inner: any Tokenizers.Tokenizer, maxLen: Int = Self.defaultMaxLen) {
        self.inner = inner
        self.maxLen = max(1, maxLen)
    }

    public static func resolveTokenizerDirectory(modelPath: URL) throws -> URL {
        let candidates = [
            modelPath.appendingPathComponent("tokenizer"),
            modelPath.appendingPathComponent("text_encoder"),
            modelPath,
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("tokenizer.json").path)
            {
                return candidate
            }
        }
        throw FluxError.weightsNotFound(modelPath.appendingPathComponent("tokenizer"))
    }

    public static func load(
        modelPath: URL,
        maxLen: Int = Self.defaultMaxLen
    ) async throws -> Flux2KleinTokenizer {
        let tokenizerDirectory = try resolveTokenizerDirectory(modelPath: modelPath)
        let upstream = try await FluxTokenizerLoader.loadAutoTokenizer(
            from: tokenizerDirectory,
            modelType: "qwen2",
            tokenizerClassOverride: "Qwen2Tokenizer"
        )
        return Flux2KleinTokenizer(inner: upstream, maxLen: maxLen)
    }

    public func encode(_ prompt: String) -> [Int] {
        var ids = inner.encode(text: prompt, addSpecialTokens: true)
        if ids.count > maxLen {
            ids = Array(ids.prefix(maxLen))
        }
        return ids
    }
}
